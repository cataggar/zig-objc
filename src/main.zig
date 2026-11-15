const std = @import("std");

const autorelease = @import("autorelease.zig");
const block = @import("block.zig");
const cpkg = @import("c.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const iterator = @import("iterator.zig");
const ivar = @import("ivar.zig");
const method = @import("method.zig");
const msg_send = @import("msg_send.zig");
const object = @import("object.zig");
const property = @import("property.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

/// Sub-namespaces for focused runtime domains.
pub const exception = @import("exception.zig");
pub const image = @import("image.zig");
pub const sync = @import("sync.zig");
pub const weak = @import("weak.zig");

// Raw C bindings & <objc/NSObjCRuntime.h> primitives
pub const c = cpkg.c;
pub const NSInteger = cpkg.NSInteger;
pub const NSUInteger = cpkg.NSUInteger;
pub const NSIntegerMax = cpkg.NSIntegerMax;
pub const NSIntegerMin = cpkg.NSIntegerMin;
pub const NSUIntegerMax = cpkg.NSUIntegerMax;
pub const boolResult = cpkg.boolResult;
pub const boolParam = cpkg.boolParam;

// Autorelease pools & fast enumeration
pub const AutoreleasePool = autorelease.AutoreleasePool;
pub const Iterator = iterator.Iterator;

// Selectors
pub const Sel = selpkg.Sel;
pub const sel = selpkg.sel;

// Messaging & forwarding (<objc/message.h>)
pub const MsgSend = msg_send.MsgSend;
pub const msgForward = msg_send.msgForward;
pub const msgForwardStret = msg_send.msgForwardStret;
pub const setForwardHandler = msg_send.setForwardHandler;

// Type encodings & signature parser
pub const Encoding = encoding.Encoding;
pub const comptimeEncode = encoding.comptimeEncode;
pub const Qualifiers = encoding.Qualifiers;
pub const ParsedType = encoding.ParsedType;
pub const ParseError = encoding.ParseError;
pub const parseType = encoding.parseType;
pub const parseTypePrefix = encoding.parseTypePrefix;
pub const MethodTypeIterator = encoding.MethodTypeIterator;

// Instance variables, methods, and properties (<objc/runtime.h>)
pub const Ivar = ivar.Ivar;
pub const Method = method.Method;
pub const MethodDescription = method.MethodDescription;
pub const Property = property.Property;

// Protocols (<objc/runtime.h>)
pub const Protocol = protocol.Protocol;
pub const getProtocol = protocol.getProtocol;
pub const copyProtocolList = protocol.copyProtocolList;
pub const allocateProtocol = protocol.allocateProtocol;
pub const registerProtocol = protocol.registerProtocol;

// Classes (<objc/runtime.h>)
pub const Class = class.Class;
pub const getClass = class.getClass;
pub const lookUpClass = class.lookUpClass;
pub const getRequiredClass = class.getRequiredClass;
pub const getMetaClass = class.getMetaClass;
pub const getClassList = class.getClassList;
pub const copyClassList = class.copyClassList;
pub const enumerateClasses = class.enumerateClasses;
pub const enumerateClassesWithBlock = class.enumerateClassesWithBlock;
pub const EnumerateClassesFilter = class.EnumerateClassesFilter;
pub const dynamic_classes_image = class.dynamic_classes_image;
pub const allocateClassPair = class.allocateClassPair;
pub const allocateClassPairExtra = class.allocateClassPairExtra;
pub const registerClassPair = class.registerClassPair;
pub const disposeClassPair = class.disposeClassPair;
pub const constructInstance = class.constructInstance;
pub const destructInstance = class.destructInstance;

// Objects, associative references, and ARC lifecycle helpers
pub const Object = object.Object;
pub const AssociationPolicy = object.AssociationPolicy;
pub const alloc = object.alloc;
pub const allocInit = object.allocInit;
pub const storeStrong = object.storeStrong;

// Zeroing weak references (<objc/runtime.h> + Clang ARC ABI)
pub const Weak = weak.Weak;
pub const WeakType = weak.WeakType;
pub const initWeak = weak.initWeak;
pub const destroyWeak = weak.destroyWeak;
pub const loadWeakRetained = weak.loadWeakRetained;
pub const loadWeak = weak.loadWeak;
pub const storeWeak = weak.storeWeak;
pub const copyWeak = weak.copyWeak;
pub const moveWeak = weak.moveWeak;

// Blocks & IMP-blocks (<Block.h> + <objc/runtime.h>)
pub const Block = block.Block;
pub const BlockRef = block.BlockRef;
pub const BlockLayout = block.BlockLayout;
pub const BlockFieldFlags = block.BlockFieldFlags;
pub const blockCopy = block.blockCopy;
pub const blockRelease = block.blockRelease;
pub const blockObjectAssign = block.objectAssign;
pub const blockObjectDispose = block.objectDispose;
pub const impImplementationWithBlock = block.impImplementationWithBlock;
pub const impGetBlock = block.impGetBlock;
pub const impRemoveBlock = block.impRemoveBlock;

// Exceptions (<objc/objc-exception.h> + @try/@catch shim)
pub const TryResult = exception.TryResult;
pub const tryInvoke = exception.tryInvoke;
pub const tryCall = exception.tryCall;
pub const msgSendTry = exception.msgSendTry;
pub const msgSendSuperTry = exception.msgSendSuperTry;
pub const throw = exception.throw;
pub const rethrow = exception.rethrow;
pub const beginCatch = exception.beginCatch;
pub const endCatch = exception.endCatch;
pub const terminate = exception.terminate;
pub const ExceptionPreprocessor = exception.ExceptionPreprocessor;
pub const setExceptionPreprocessor = exception.setExceptionPreprocessor;
pub const ExceptionMatcher = exception.ExceptionMatcher;
pub const setExceptionMatcher = exception.setExceptionMatcher;
pub const UncaughtExceptionHandler = exception.UncaughtExceptionHandler;
pub const setUncaughtExceptionHandler = exception.setUncaughtExceptionHandler;
pub const ExceptionHandler = exception.ExceptionHandler;
pub const addExceptionHandler = if (@hasDecl(exception, "addExceptionHandler")) exception.addExceptionHandler else {};
pub const removeExceptionHandler = if (@hasDecl(exception, "removeExceptionHandler")) exception.removeExceptionHandler else {};

// Object synchronization (<objc/objc-sync.h>)
pub const SyncError = sync.SyncError;
pub const SyncGuard = sync.SyncGuard;
pub const syncEnter = sync.syncEnter;
pub const syncExit = sync.syncExit;
pub const synchronize = sync.synchronize;

// Dynamic library images, enumeration mutation, and runtime hooks (<objc/runtime.h>)
pub const MachHeader = image.MachHeader;
pub const copyImageNames = image.copyImageNames;
pub const copyImageHeaders = if (@hasDecl(image, "copyImageHeaders")) image.copyImageHeaders else {};
pub const getImageName = image.getImageName;
pub const copyClassNamesForImage = image.copyClassNamesForImage;
pub const EnumerationMutationHandler = image.EnumerationMutationHandler;
pub const enumerationMutation = image.enumerationMutation;
pub const setEnumerationMutationHandler = image.setEnumerationMutationHandler;
pub const HookGetImageName = image.HookGetImageName;
pub const setHookGetImageName = image.setHookGetImageName;
pub const HookGetClass = image.HookGetClass;
pub const setHookGetClass = image.setHookGetClass;
pub const HookLazyClassNamer = image.HookLazyClassNamer;
pub const setHookLazyClassNamer = image.setHookLazyClassNamer;
pub const LoadImageFunc = image.LoadImageFunc;
pub const addLoadImageFunc = image.addLoadImageFunc;

/// Frees heap memory returned by Objective-C runtime `copy*` functions using
/// `std.c.free`. Safely ignores `null` optionals and empty non-sentinel slices
/// (`&.{}`), while freeing sentinel-terminated C strings even when `len == 0`.
pub fn free(ptr: anytype) void {
    const T = @TypeOf(ptr);
    switch (@typeInfo(T)) {
        .null => return,
        .optional => {
            if (ptr) |unwrapped| free(unwrapped);
            return;
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => {
                if (ptr_info.sentinel_ptr == null and ptr.len == 0) return;
                std.c.free(@ptrCast(@constCast(ptr.ptr)));
            },
            .one => {
                switch (@typeInfo(ptr_info.child)) {
                    .@"opaque" => {},
                    .array => |arr_info| {
                        if (arr_info.sentinel_ptr == null and arr_info.len == 0) return;
                    },
                    else => {
                        if (@sizeOf(ptr_info.child) == 0) return;
                    },
                }
                std.c.free(@ptrCast(@constCast(ptr)));
            },
            .many => {
                std.c.free(@ptrCast(@constCast(ptr)));
            },
            .c => {
                if (ptr == null) return;
                std.c.free(@ptrCast(@constCast(ptr)));
            },
        },
        else => @compileError("objc.free expected pointer, slice, or optional thereof, got " ++ @typeName(T)),
    }
}

test "free handles malloc buffers, sentinel strings, null optionals, and empty slices" {
    const testing = std.testing;

    // Non-empty non-sentinel slice allocated via malloc
    const raw_buf = std.c.malloc(32) orelse return error.OutOfMemory;
    const byte_slice: []u8 = @as([*]u8, @ptrCast(raw_buf))[0..32];
    @memset(byte_slice, 0xAB);
    free(byte_slice);

    const raw_const = std.c.malloc(16) orelse return error.OutOfMemory;
    const const_slice: []const u8 = @as([*]const u8, @ptrCast(raw_const))[0..16];
    free(const_slice);

    // Single, many, and C pointers allocated via malloc
    const single_ptr: *u64 = @ptrCast(@alignCast(std.c.malloc(@sizeOf(u64)) orelse return error.OutOfMemory));
    single_ptr.* = 42;
    free(single_ptr);

    const many_ptr: [*]u8 = @ptrCast(std.c.malloc(8) orelse return error.OutOfMemory);
    free(many_ptr);

    const c_ptr: [*c]u8 = @ptrCast(std.c.malloc(8) orelse return error.OutOfMemory);
    free(c_ptr);
    const null_c_ptr: [*c]const u8 = null;
    free(null_c_ptr);

    // Sentinel-terminated C string slices, including zero-length malloc'd ""
    const empty_cstr_buf: [*]u8 = @ptrCast(std.c.malloc(1) orelse return error.OutOfMemory);
    empty_cstr_buf[0] = 0;
    const empty_cstr: [:0]u8 = empty_cstr_buf[0..0 :0];
    try testing.expectEqual(@as(usize, 0), empty_cstr.len);
    free(empty_cstr);

    const hello_buf: [*]u8 = @ptrCast(std.c.malloc(6) orelse return error.OutOfMemory);
    @memcpy(hello_buf[0..5], "hello");
    hello_buf[5] = 0;
    const hello_cstr: [:0]const u8 = hello_buf[0..5 :0];
    free(hello_cstr);

    const many_z_buf: [*]u8 = @ptrCast(std.c.malloc(4) orelse return error.OutOfMemory);
    @memcpy(many_z_buf[0..3], "abc");
    many_z_buf[3] = 0;
    const many_z: [*:0]u8 = many_z_buf[0..3 :0].ptr;
    free(many_z);

    // Null optionals of all pointer/slice kinds
    free(@as(?[]u8, null));
    free(@as(?[:0]u8, null));
    free(@as(?[*:0]const u8, null));
    free(@as(?*u32, null));
    free(null);

    // Non-null optional and opaque pointers wrapping malloc buffers
    const opt_ptr: ?*u8 = @ptrCast(std.c.malloc(1) orelse return error.OutOfMemory);
    free(opt_ptr);
    const opaque_ptr: *anyopaque = std.c.malloc(4) orelse return error.OutOfMemory;
    free(opaque_ptr);

    // Empty non-sentinel slices (`&.{}`) must be safe no-ops
    const empty_mut: []u8 = &.{};
    free(empty_mut);
    const empty_const: []const Property = &.{};
    free(empty_const);
    free(&.{});
}

test "end-to-end integration: dynamic protocol, subclass, typed ivar, IMP-block, Weak, sync, associated object, and msgSendTry" {
    const testing = std.testing;

    const pool = AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = getClass("NSObject").?;
    const NSNumber = getClass("NSNumber").?;
    const NSString = getClass("NSString").?;
    const NSException = getClass("NSException").?;

    const ZigState = struct {
        base: i64,
        calls: usize = 0,
        dealloc_called: bool = false,
    };

    // 1. Dynamic protocol with required method descriptions
    const worker_proto = allocateProtocol("ZigObjcE2EWorkerProtocol") orelse return error.ProtocolAllocFailed;
    worker_proto.addMethod(sel("computeWithDelta:"), fn (c.id, c.SEL, i64) callconv(.c) i64, true, true);
    worker_proto.addMethod(sel("failIfZero:"), fn (c.id, c.SEL, i64) callconv(.c) i64, true, true);
    registerProtocol(worker_proto);

    // 2. Dynamic subclass adopting protocol, holding a typed *ZigState ivar, IMP-block method, throwing method, and dealloc
    const WorkerClass = allocateClassPair(NSObject, "ZigObjcE2EWorker") orelse return error.ClassAllocFailed;
    defer disposeClassPair(WorkerClass);

    try testing.expect(WorkerClass.addProtocol(worker_proto));
    try testing.expect(WorkerClass.addIvar(*ZigState, "zig_state"));

    // IMP-block capturing a retained Objective-C NSNumber multiplier
    const multiplier_num = NSNumber.msgSend(Object, "numberWithLongLong:", .{@as(c_longlong, 3)});
    const ComputeBlock = Block(struct { factor: Object }, .{ Object, i64 }, i64);
    var stack_compute = ComputeBlock.init(.{ .factor = multiplier_num }, &(struct {
        fn invoke(blk_ctx: *const ComputeBlock.Context, raw_receiver: c.id, delta: i64) callconv(.c) i64 {
            const receiver = Object.fromId(raw_receiver);
            var guard = receiver.synchronize() catch unreachable;
            defer guard.unlock();

            const st = receiver.getTypedIvar(*ZigState, "zig_state").?;
            st.calls += 1;
            const factor_obj = ComputeBlock.getCaptures(blk_ctx).factor;
            const factor = factor_obj.msgSend(i64, "longLongValue", .{});
            return (st.base + delta) * factor;
        }
    }).invoke);
    const compute_imp = impImplementationWithBlock(&stack_compute);
    defer _ = impRemoveBlock(compute_imp);

    const compute_enc = comptime comptimeEncode(fn (c.id, c.SEL, i64) callconv(.c) i64);
    try testing.expect(WorkerClass.addMethodRaw(sel("computeWithDelta:"), compute_imp, &compute_enc));

    try testing.expect(WorkerClass.addMethod("failIfZero:", struct {
        fn imp(_: c.id, _: c.SEL, value: i64) callconv(.c) i64 {
            if (value == 0) {
                const name = getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{"ZigObjcZeroDivision"});
                const reason = getClass("NSString").?.msgSend(Object, "stringWithUTF8String:", .{"zero is not allowed"});
                const exc = getClass("NSException").?.msgSend(
                    Object,
                    "exceptionWithName:reason:userInfo:",
                    .{ name, reason, @as(?Object, null) },
                );
                throw(exc);
            }
            return @divTrunc(100, value);
        }
    }.imp));

    _ = WorkerClass.replaceMethod("dealloc", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) void {
            const self_obj = Object.fromId(target);
            if (self_obj.getTypedIvar(*ZigState, "zig_state")) |st| {
                st.dealloc_called = true;
            }
            self_obj.msgSendSuper(getClass("NSObject").?, void, "dealloc", .{});
        }
    }.imp);

    registerClassPair(WorkerClass);
    try testing.expect(WorkerClass.conformsToProtocol(worker_proto));

    // 3. Verify enumerateClasses discovers our dynamic class conforming to our dynamic protocol
    if (@hasDecl(c, "objc_enumerateClasses")) {
        var found_worker = false;
        enumerateClasses(
            .{
                .image = dynamic_classes_image,
                .name_prefix = "ZigObjcE2E",
                .conforming_to = worker_proto,
            },
            &found_worker,
            struct {
                fn visit(found: *bool, cls: Class, stop: *bool) void {
                    if (std.mem.eql(u8, cls.getName(), "ZigObjcE2EWorker")) {
                        found.* = true;
                        stop.* = true;
                    }
                }
            }.visit,
        );
        try testing.expect(found_worker);
    }

    // 4. Exercise instance lifecycle, typed ivar, associated object, synchronize, IMP-block, msgSendTry, and Weak zeroing
    var state: ZigState = .{ .base = 10 };
    const AssocKey = struct {
        var tag: u8 = 0;
    };

    var weak_worker: Weak = .{};
    defer weak_worker.deinit();
    {
        const worker = allocInit(WorkerClass) orelse return error.AllocInitFailed;
        try testing.expect(worker.setTypedIvar(*ZigState, "zig_state", &state));

        weak_worker.init(worker);

        const label = NSString.msgSend(Object, "stringWithUTF8String:", .{"e2e-worker"});
        worker.setAssociatedObject(&AssocKey.tag, label, .retain_nonatomic);
        const got_label = worker.getAssociatedObject(&AssocKey.tag).?;
        try testing.expectEqualStrings("e2e-worker", std.mem.span(got_label.msgSend([*:0]const u8, "UTF8String", .{})));

        // Invoke IMP-block method (synchronizes on `worker` and mutates `state`)
        const computed = worker.msgSend(i64, "computeWithDelta:", .{@as(i64, 7)});
        try testing.expectEqual(@as(i64, 51), computed);
        try testing.expectEqual(@as(usize, 1), state.calls);

        // Method introspection on dynamic class
        const m = WorkerClass.getInstanceMethod(sel("computeWithDelta:")).?;
        try testing.expectEqual(@as(c_uint, 3), m.getNumberOfArguments());

        // Safe @try/@catch via Object.msgSendTry
        switch (worker.msgSendTry(i64, "failIfZero:", .{@as(i64, 5)})) {
            .ok => |q| try testing.expectEqual(@as(i64, 20), q),
            .exception => return error.UnexpectedException,
        }
        switch (worker.msgSendTry(i64, "failIfZero:", .{@as(i64, 0)})) {
            .ok => return error.ExpectedException,
            .exception => |exc_opt| {
                const exc = exc_opt orelse return error.NullException;
                defer exc.release();
                try testing.expect(exc.msgSend(bool, "isKindOfClass:", .{NSException}));
                const exc_name = exc.msgSend(Object, "name", .{});
                try testing.expectEqualStrings(
                    "ZigObjcZeroDivision",
                    std.mem.span(exc_name.msgSend([*:0]const u8, "UTF8String", .{})),
                );
            },
        }

        // Weak reference resolves while worker is alive
        const loaded = weak_worker.loadRetained().?;
        try testing.expectEqual(worker.value, loaded.value);
        loaded.release();

        // Final release triggers custom dealloc and zeroes weak_worker
        worker.release();
    }

    try testing.expect(state.dealloc_called);
    try testing.expect(weak_worker.loadRetained() == null);
}

test {
    _ = @import("autorelease.zig");
    _ = @import("block.zig");
    _ = @import("c.zig");
    _ = @import("class.zig");
    _ = @import("encoding.zig");
    _ = @import("exception.zig");
    _ = @import("image.zig");
    _ = @import("iterator.zig");
    _ = @import("ivar.zig");
    _ = @import("method.zig");
    _ = @import("msg_send.zig");
    _ = @import("object.zig");
    _ = @import("property.zig");
    _ = @import("protocol.zig");
    _ = @import("sel.zig");
    _ = @import("sync.zig");
    _ = @import("weak.zig");
    std.testing.refAllDecls(@This());
}
