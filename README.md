# zig-objc - Objective-C Runtime Bindings for Zig

`zig-objc` lets Zig call and extend Objective-C on Apple platforms (macOS, iOS, tvOS, watchOS) using the modern [Objective-C runtime](https://developer.apple.com/documentation/objectivec/objective-c_runtime?language=objc).

**Project Status:** `zig-objc` provides **100% coverage of the modern Objective-C runtime** (all active non-GC / non-ObjC-1.0 public APIs) and targets **Zig 0.17.1**.

## Runtime Coverage

| Header / ABI | Highlights |
| --- | --- |
| `<objc/runtime.h>` | `Class` (`getClassCached` / `Class.cached`), `Object`, `Method`, `Ivar`, `IvarSlot(T)`, `Property`, `Protocol`, dynamic class/protocol registration, typed `(Object, Sel, ...)` `IMP` callbacks, method swizzling, associative references, zeroing weak references, `objc_enumerateClasses`, dynamic library image queries, and Swift/runtime hooks |
| `<objc/message.h>` | Architecture-aware `msgSend` / `msgSendSuper` (`aarch64` & `x86_64` `stret`/`fpret`), `msgSendVarargs` / `msgSendSuperVarargs` (C99-promoted variadics), `Method.invoke`, `_objc_msgForward` / `_objc_msgForward_stret`, `setForwardHandler` |
| `<objc/objc.h>` & `<objc/NSObjCRuntime.h>` | `Sel` (`S` / `selCached` / `Sel.cached`, `sel_registerName`, `sel_getUid`, `sel_isMapped`, `sel_isEqual`), `NSInteger` / `NSUInteger`, `BOOL` conversion, C-ABI `extern struct` `Object` & `Sel` handles with tagged-pointer safety |
| `<objc/objc-sync.h>` | Recursive `@synchronized` monitors via `obj.synchronize()`, `SyncGuard`, `syncEnter` / `syncExit` |
| `<objc/objc-exception.h>` | Real Objective-C `@try / @catch` (including foreign/C++ exceptions) via `obj.msgSendTry`, `msgSendSuperTry`, `msgSendVarargsTry`, `msgSendSuperVarargsTry`, `tryInvoke`, `tryCall`, `throw`, `rethrow`, and exception hooks/handlers |
| `<Block.h>` | Stack (`_NSConcreteStackBlock`) and global (`_NSConcreteGlobalBlock`) `Block` creation, automatic `copy`/`dispose` helpers for captured `Object`s and nested blocks, incoming `BlockRef` / `?BlockRef` invocation, and `imp_implementationWithBlock` |
| Clang ARC & `@autoreleasepool` ABI | `AutoreleasePool`, `alloc` / `allocInit`, `retain` / `release` / `autorelease`, `storeStrong`, return-value handoff helpers, and `objc_initWeak` / `objc_loadWeakRetained` / `objc_destroyWeak` (`objc.Weak`) |
| Type Encodings | Compile-time `@encode` generation (`Encoding`, `comptimeEncode`) and full runtime type/method signature parsing (`parseType`, `MethodTypeIterator`, `Qualifiers`) |

## Examples

### Messaging, Cached Selectors/Classes, and Variadic Calls (`msgSend`, `S`, `msgSendVarargs`)

```zig
const std = @import("std");
const objc = @import("objc");

pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    // `getClassCached` and `S` (`selCached`) resolve once into lock-free atomic static slots.
    const NSProcessInfo = objc.getClassCached("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, objc.S("processInfo"), .{});

    return info.msgSend(bool, objc.S("isOperatingSystemAtLeastVersion:"), .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

/// Nullable Objective-C returns map directly to `?objc.Object` (`nil` -> `null`).
pub fn lookupString(dict: objc.Object, key: objc.Object) ?[:0]const u8 {
    const value = dict.msgSend(?objc.Object, objc.S("objectForKey:"), .{key}) orelse return null;
    return std.mem.span(value.msgSend([*:0]const u8, objc.S("UTF8String"), .{}));
}

/// C-variadic Objective-C methods split fixed parameters from `...` variadic arguments
/// (automatically applying C99 promotions and Apple Silicon stack vararg layout).
pub fn formatAndCollect() objc.Object {
    const NSString = objc.getClassCached("NSString").?;
    const NSArray = objc.getClassCached("NSArray").?;

    const fmt = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"%s=%d (%.1f)"});
    const item = NSString.msgSendVarargs(
        objc.Object,
        objc.S("stringWithFormat:"),
        .{fmt},
        .{ "count", @as(c_int, 42), @as(f32, 3.5) },
    );
    return NSArray.msgSendVarargs(objc.Object, objc.S("arrayWithObjects:"), .{item}, .{null});
}

const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};
```

### Dynamic Subclassing, `IvarSlot(T)`, and Typed `(Object, Sel)` `IMP`s

```zig
const objc = @import("objc");

const CounterState = struct {
    count: usize = 0,
};

var state_slot: objc.IvarSlot(*CounterState) = .{};

pub fn makeCounterSubclass() !objc.Class {
    const NSObject = objc.getClassCached("NSObject").?;
    const cls = objc.allocateClassPair(NSObject, "ZigCounterObject") orelse return error.ClassExists;

    // Conform to an Objective-C protocol and store a native Zig pointer ivar.
    _ = cls.addProtocol(objc.getProtocol("NSObject").?);
    _ = cls.addIvar(*CounterState, "zig_state");

    // `Object` and `Sel` are ABI-identical `extern struct`s and work directly in `callconv(.c)` IMPs.
    _ = cls.addMethod("incrementBy:", struct {
        fn imp(self: objc.Object, _: objc.Sel, delta: usize) callconv(.c) usize {
            const state = state_slot.load(self);
            state.count += delta;
            return state.count;
        }
    }.imp);

    _ = cls.replaceMethod("dealloc", struct {
        fn imp(self: objc.Object, _: objc.Sel) callconv(.c) void {
            self.msgSendSuper(objc.getClassCached("NSObject").?, void, objc.S("dealloc"), .{});
        }
    }.imp);

    objc.registerClassPair(cls);
    // Resolve the ivar byte offset once for sub-nanosecond `load` / `store` (or use lazy `.get` / `.set`).
    state_slot = objc.IvarSlot(*CounterState).fromClass(cls, "zig_state").?;
    return cls;
}

pub fn useCounter(cls: objc.Class) void {
    var state: CounterState = .{};
    const obj = objc.allocInit(cls).?;
    defer obj.release();

    state_slot.store(obj, &state);
    _ = obj.msgSend(usize, objc.S("incrementBy:"), .{@as(usize, 5)});
}
```

### Associated Objects, `AutoreleasePool`, and Zeroing `Weak` References

```zig
const objc = @import("objc");

const AssocKeys = struct {
    var badge: u8 = 0;
};

pub fn lifecycleDemo() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const NSString = objc.getClass("NSString").?;

    // Address-pinned zeroing weak reference (`objc_initWeak` / `objc_destroyWeak`).
    var weak_ref: objc.Weak = .{};
    defer weak_ref.deinit();

    {
        const host = objc.allocInit(NSObject).?;
        defer host.release();

        weak_ref.init(host);

        const label = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"attached"});
        host.setAssociatedObject(&AssocKeys.badge, label, .retain_nonatomic);
        _ = host.getAssociatedObject(&AssocKeys.badge).?;

        if (weak_ref.loadRetained()) |strong| {
            defer strong.release();
        }
    }

    // Automatically zeroed to `null` once `host` is deallocated.
    std.debug.assert(weak_ref.loadRetained() == null);
}

const std = @import("std");
```

### Blocks, Object Captures, `BlockRef`, and `impImplementationWithBlock`

```zig
const objc = @import("objc");

pub fn blocksDemo(multiplier: objc.Object) void {
    // Capturing `objc.Object` automatically emits BLOCK_HAS_COPY_DISPOSE helpers.
    const ScaleBlock = objc.Block(struct { factor: objc.Object }, .{ objc.c.id, i64 }, i64);
    var stack_blk = ScaleBlock.init(.{ .factor = multiplier }, &(struct {
        fn invoke(ctx: *const ScaleBlock.Context, _: objc.c.id, x: i64) callconv(.c) i64 {
            const factor = ScaleBlock.getCaptures(ctx).factor.msgSend(i64, "longLongValue", .{});
            return x * factor;
        }
    }).invoke);

    // Turn any block into a method IMP (`receiver` is passed as the first block argument).
    const imp = objc.impImplementationWithBlock(&stack_blk);
    defer _ = objc.impRemoveBlock(imp);
}

pub fn callIncomingBlock(blk: objc.BlockRef(.{ i32, i32 }, i32)) i32 {
    // `BlockRef` is ABI-identical to a raw Objective-C block pointer (`int32_t (^)(int32_t, int32_t)`).
    return blk.invoke(.{ 20, 22 });
}
```

### Objective-C `@try / @catch` Exception Handling (`msgSendTry`, `tryInvoke`)

```zig
const objc = @import("objc");

pub fn safeObjectAtIndex(array: objc.Object, index: objc.NSUInteger) !objc.Object {
    return switch (array.msgSendTry(objc.Object, "objectAtIndex:", .{index})) {
        .ok => |elem| elem,
        .exception => |exc_opt| blk: {
            if (exc_opt) |exc| {
                // Caught exceptions carry +1 retain ownership.
                defer exc.release();
            }
            break :blk error.IndexOutOfBounds;
        },
    };
}

pub fn runInTryFrame(work: *const fn (u32) u32, input: u32) !u32 {
    return switch (objc.tryInvoke(work, .{input})) {
        .ok => |result| result,
        .exception => |exc_opt| blk: {
            if (exc_opt) |exc| exc.release();
            break :blk error.ObjCExceptionThrown;
        },
    };
}
```

### `Method` Introspection & Swizzling, `@synchronized`, and Class/Image Enumeration

```zig
const std = @import("std");
const objc = @import("objc");

pub fn runtimeUtilitiesDemo(lock_target: objc.Object, cls: objc.Class) !void {
    // Recursive @synchronized(lock_target) monitor
    {
        var guard = try lock_target.synchronize();
        defer guard.unlock();
    }

    // Method introspection and atomic IMP swizzling
    if (cls.getInstanceMethod(objc.sel("description"))) |m| {
        const ret_type = m.copyReturnType();
        defer objc.free(ret_type);
        _ = m.getNumberOfArguments();
        // m.exchangeImplementations(replacement_method);
    }

    // Fast filtered class enumeration (`objc_enumerateClasses`)
    var count: usize = 0;
    objc.enumerateClasses(.{ .name_prefix = "NS" }, &count, struct {
        fn visit(total: *usize, _: objc.Class, stop: *bool) void {
            total.* += 1;
            if (total.* >= 10) stop.* = true;
        }
    }.visit);

    // Loaded Mach-O Objective-C image names
    const images = objc.copyImageNames();
    defer objc.free(images);
    std.debug.assert(images.len > 0);
}
```

## Usage

Add `zig-objc` to your `build.zig.zon`, then wire the `objc` module in `build.zig`:

```zig
pub fn build(b: *std.Build) !void {
    // ...
    exe.root_module.addImport("objc", b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    }).module("objc"));
}
```

`zig-objc` locates headers, frameworks, and libraries from your active Xcode SDK (`macOS`, `iOS`, `tvOS`, `watchOS`) automatically. To supply your own SDK paths manually, pass `-Dadd-paths=false` (or `-Dapple-sdk=/path/to/MacOSX.sdk` when cross-compiling).

**Requirements:**
- **Zig 0.17.1** (macOS 15+ with Xcode for native `zig build test`).
- C header translation uses the pinned `translate-c` 2.0.0 package in `build.zig.zon`, translating the Apple SDK headers directly while patching the single block-declarator signature in `<objc/runtime.h>`.

## Testing & Benchmarks

```sh
zig build test           # Run the full Objective-C runtime test suite
zig build bench          # Run the ReleaseFast microbenchmark suite (src/bench.zig)
```

## Documentation

Read `src/main.zig` and the domain modules under `src/` (`object.zig`, `class.zig`, `msg_send.zig`, `abi.zig`, `block.zig`, `weak.zig`, `exception.zig`, `sync.zig`, `image.zig`, `encoding.zig`, `method.zig`, `ivar.zig`, `property.zig`, `protocol.zig`, `sel.zig`, `autorelease.zig`, `iterator.zig`); all public types and memory-ownership contracts (`objc.free`, `+1` retained returns, `AutoreleasePool`, `Weak`, `IvarSlot`) are documented inline.
