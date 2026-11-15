# zig-objc - Objective-C Runtime Bindings for Zig

`zig-objc` lets Zig call and extend Objective-C on Apple platforms (macOS, iOS, tvOS, watchOS) using the modern [Objective-C runtime](https://developer.apple.com/documentation/objectivec/objective-c_runtime?language=objc).

**Project Status:** `zig-objc` provides **100% coverage of the modern Objective-C runtime** (all active non-GC / non-ObjC-1.0 public APIs) and targets **Zig 0.17.1**.

## Runtime Coverage

| Header / ABI | Highlights |
| --- | --- |
| `<objc/runtime.h>` | `Class`, `Object`, `Method`, `Ivar`, `Property`, `Protocol`, dynamic class/protocol registration, typed Zig ivars, method swizzling, associative references, zeroing weak references, `objc_enumerateClasses`, dynamic library image queries, and Swift/runtime hooks |
| `<objc/message.h>` | Architecture-aware `msgSend` / `msgSendSuper` (`aarch64` & `x86_64` `stret`/`fpret`), `Method.invoke`, `_objc_msgForward` / `_objc_msgForward_stret`, `setForwardHandler` |
| `<objc/objc.h>` & `<objc/NSObjCRuntime.h>` | `Sel` (`sel_registerName`, `sel_getUid`, `sel_isMapped`, `sel_isEqual`), `NSInteger` / `NSUInteger`, `BOOL` conversion, tagged-pointer-safe `Object` handles |
| `<objc/objc-sync.h>` | Recursive `@synchronized` monitors via `obj.synchronize()`, `SyncGuard`, `syncEnter` / `syncExit` |
| `<objc/objc-exception.h>` | Real Objective-C `@try / @catch` via `obj.msgSendTry`, `msgSendSuperTry`, `tryInvoke`, `tryCall`, `throw`, `rethrow`, and exception hooks/handlers |
| `<Block.h>` | Stack (`_NSConcreteStackBlock`) and global (`_NSConcreteGlobalBlock`) `Block` creation, automatic `copy`/`dispose` helpers for captured `Object`s and nested blocks, incoming `BlockRef` invocation, and `imp_implementationWithBlock` |
| Clang ARC & `@autoreleasepool` ABI | `AutoreleasePool`, `alloc` / `allocInit`, `retain` / `release` / `autorelease`, `storeStrong`, return-value handoff helpers, and `objc_initWeak` / `objc_loadWeakRetained` / `objc_destroyWeak` (`objc.Weak`) |
| Type Encodings | Compile-time `@encode` generation (`Encoding`, `comptimeEncode`) and full runtime type/method signature parsing (`parseType`, `MethodTypeIterator`, `Qualifiers`) |

## Examples

### Messaging & Nullable Returns (`msgSend`, `msgSendSuper`)

```zig
const objc = @import("objc");

pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    return info.msgSend(bool, "isOperatingSystemAtLeastVersion:", .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

/// Nullable Objective-C returns map directly to `?objc.Object` (`nil` -> `null`).
pub fn lookupString(dict: objc.Object, key: objc.Object) ?[:0]const u8 {
    const value = dict.msgSend(?objc.Object, "objectForKey:", .{key}) orelse return null;
    return std.mem.span(value.msgSend([*:0]const u8, "UTF8String", .{}));
}

const std = @import("std");
const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};
```

### Dynamic Subclassing, Typed Zig Ivars, and Protocol Conformance

```zig
const objc = @import("objc");

const CounterState = struct {
    count: usize = 0,
};

pub fn makeCounterSubclass() !objc.Class {
    const NSObject = objc.getClass("NSObject").?;
    const cls = objc.allocateClassPair(NSObject, "ZigCounterObject") orelse return error.ClassExists;

    // Conform to an Objective-C protocol and store a native Zig pointer ivar.
    _ = cls.addProtocol(objc.getProtocol("NSObject").?);
    _ = cls.addIvar(*CounterState, "zig_state");

    _ = cls.addMethod("incrementBy:", struct {
        fn imp(target: objc.c.id, _: objc.c.SEL, delta: usize) callconv(.c) usize {
            const self_obj = objc.Object.fromId(target);
            const state = self_obj.getTypedIvar(*CounterState, "zig_state").?;
            state.count += delta;
            return state.count;
        }
    }.imp);

    _ = cls.replaceMethod("dealloc", struct {
        fn imp(target: objc.c.id, _: objc.c.SEL) callconv(.c) void {
            const self_obj = objc.Object.fromId(target);
            self_obj.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
    }.imp);

    objc.registerClassPair(cls);
    return cls;
}

pub fn useCounter(cls: objc.Class) void {
    var state: CounterState = .{};
    const obj = objc.allocInit(cls).?;
    defer obj.release();

    _ = obj.setTypedIvar(*CounterState, "zig_state", &state);
    _ = obj.msgSend(usize, "incrementBy:", .{@as(usize, 5)});
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

## Documentation

Read `src/main.zig` and the domain modules under `src/` (`object.zig`, `class.zig`, `msg_send.zig`, `block.zig`, `weak.zig`, `exception.zig`, `sync.zig`, `image.zig`, `encoding.zig`, `method.zig`, `ivar.zig`, `property.zig`, `protocol.zig`, `sel.zig`, `autorelease.zig`, `iterator.zig`); all public types and memory-ownership contracts (`objc.free`, `+1` retained returns, `AutoreleasePool`, `Weak`) are documented inline.
