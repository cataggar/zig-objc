const std = @import("std");
const builtin = @import("builtin");
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

extern "c" fn zig_objc_try_catch(
    try_fn: *const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
    caught_out: *u8,
) ?*anyopaque;

extern "c" fn objc_begin_catch(exc_buf: *anyopaque) ?*anyopaque;

/// Errors raised when unwinding an Objective-C `@try / @catch` frame.
pub const Error = error{
    /// An Objective-C object exception (`@throw obj` or `@throw nil`) was caught.
    ExceptionThrown,
    /// A non-`id` foreign or C++ exception was caught via `@catch (...)`.
    ForeignExceptionThrown,
};

/// Result of executing an operation inside an Objective-C `@try / @catch` frame.
///
/// When `.exception` is returned and non-null (`?objc.Object`), the caught
/// Objective-C exception object has `+1` retain ownership (retained inside
/// `@catch` before `objc_end_catch` runs). The caller should call `.release()`
/// on the returned `objc.Object` when done inspecting it.
///
/// `.exception` is `null` when `@throw nil` or a foreign/C++ exception was caught;
/// use `tryCallCatch` / `tryInvokeCatch` to distinguish `Error.ExceptionThrown`
/// from `Error.ForeignExceptionThrown`.
pub fn TryResult(comptime R: type) type {
    return union(enum) {
        ok: R,
        exception: ?objc.Object,

        /// Reports whether an Objective-C or foreign exception was caught.
        pub inline fn hasThrown(self: @This()) bool {
            return self == .exception;
        }
    };
}

fn InvokeReturnType(comptime func: anytype, comptime Args: type) type {
    const args_info = switch (@typeInfo(Args)) {
        .@"struct" => |s| s,
        else => @compileError("tryInvoke expected args tuple, got " ++ @typeName(Args)),
    };
    if (!args_info.is_tuple) {
        @compileError("tryInvoke expected args tuple, got " ++ @typeName(Args));
    }

    const Func = @TypeOf(func);
    switch (@typeInfo(Func)) {
        .@"fn" => |f| if (f.return_type) |R| return R,
        .pointer => |p| {
            if (p.size == .one and @typeInfo(p.child) == .@"fn") {
                if (@typeInfo(p.child).@"fn".return_type) |R| return R;
            }
            @compileError("tryInvoke expected function or function pointer, got " ++ @typeName(Func));
        },
        else => @compileError("tryInvoke expected function or function pointer, got " ++ @typeName(Func)),
    }

    const dummy_ptr: *const Args = undefined;
    return @TypeOf(@call(.auto, func, dummy_ptr.*));
}

/// Executes a C-ABI callback `try_fn(context)` inside an Objective-C
/// `@try / @catch` frame, returning `Error.ExceptionThrown` for Objective-C
/// `id` exceptions and `Error.ForeignExceptionThrown` for foreign/C++ exceptions.
///
/// If `caught_out` is non-null, stores the `+1`-retained Objective-C exception
/// (or `null` for `@throw nil` or foreign exceptions) into `caught_out.*`; if
/// `caught_out` is `null`, any caught Objective-C exception is released before
/// returning `error.ExceptionThrown`.
pub fn tryCallCatch(
    try_fn: *const fn (?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
    caught_out: ?*?objc.Object,
) Error!void {
    var status: u8 = 0;
    const raw_exc = zig_objc_try_catch(try_fn, context, &status);
    if (status == 0) {
        @branchHint(.likely);
        return;
    }

    return switch (status) {
        1 => {
            const exc_obj: ?objc.Object = if (raw_exc) |ptr| objc.Object.fromId(ptr) else null;
            if (caught_out) |out| {
                out.* = exc_obj;
            } else if (exc_obj) |obj| {
                obj.release();
            }
            return error.ExceptionThrown;
        },
        2 => {
            if (caught_out) |out| {
                out.* = null;
            }
            return error.ForeignExceptionThrown;
        },
        else => unreachable,
    };
}

/// Executes a C-ABI callback `try_fn(context)` inside an Objective-C
/// `@try / @catch` frame.
///
/// Returns `.{ .ok = {} }` if `try_fn` returns normally, or `.{ .exception = exc }`
/// if an Objective-C or foreign exception was thrown (`exc` has `+1` retain count
/// when non-null; call `.release()` when done).
pub fn tryCall(
    try_fn: *const fn (?*anyopaque) callconv(.c) void,
    context: ?*anyopaque,
) TryResult(void) {
    var caught_exc: ?objc.Object = null;
    tryCallCatch(try_fn, context, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = {} };
}

/// Invokes `@call(.auto, func, args)` inside an Objective-C `@try / @catch` frame,
/// returning `Error!R` and storing any caught `+1` Objective-C exception in `caught_out`.
pub fn tryInvokeCatch(
    comptime func: anytype,
    args: anytype,
    caught_out: ?*?objc.Object,
) Error!InvokeReturnType(func, @TypeOf(args)) {
    const Args = @TypeOf(args);
    const R = InvokeReturnType(func, Args);

    const ResultSlot = if (R == noreturn) void else R;

    const Context = struct {
        args: Args,
        result: ResultSlot = undefined,
        _non_empty: u8 = 0,

        fn run(raw_ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            if (R == noreturn) {
                @call(.auto, func, self.args);
            } else {
                self.result = @call(.auto, func, self.args);
            }
        }
    };

    var ctx: Context = .{ .args = args };
    try tryCallCatch(&Context.run, @ptrCast(&ctx), caught_out);
    return if (R == noreturn) unreachable else ctx.result;
}

/// Invokes `@call(.auto, func, args)` inside an Objective-C `@try / @catch` frame.
///
/// Returns `.{ .ok = result }` if `func` completes without throwing, or
/// `.{ .exception = exc }` if an Objective-C or foreign exception is caught.
/// When `exc` is non-null, it is returned at `+1` retain count and the caller
/// should call `.release()` when finished inspecting it.
pub fn tryInvoke(
    comptime func: anytype,
    args: anytype,
) TryResult(InvokeReturnType(func, @TypeOf(args))) {
    var caught_exc: ?objc.Object = null;
    const val = tryInvokeCatch(func, args, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = val };
}

/// Sends an Objective-C message inside `@try / @catch`, returning `Error!Return`.
pub fn msgSendCatch(
    target: anytype,
    comptime Return: type,
    sel_raw: anytype,
    args: anytype,
    caught_out: ?*?objc.Object,
) Error!Return {
    const Target = @TypeOf(target);
    const SelRaw = @TypeOf(sel_raw);
    const Args = @TypeOf(args);
    const Helper = struct {
        inline fn call(t: Target, s: SelRaw, a: Args) Return {
            return t.msgSend(Return, s, a);
        }
    };
    return tryInvokeCatch(Helper.call, .{ target, sel_raw, args }, caught_out);
}

/// Sends an Objective-C message (`target.msgSend(Return, sel_raw, args)`) inside
/// an Objective-C `@try / @catch` frame, catching any thrown `NSException`,
/// Objective-C object, or foreign exception instead of aborting the process.
///
/// When `.exception` is non-null, it has `+1` retain ownership and the caller
/// should call `.release()` when finished inspecting it.
pub fn msgSendTry(
    target: anytype,
    comptime Return: type,
    sel_raw: anytype,
    args: anytype,
) TryResult(Return) {
    var caught_exc: ?objc.Object = null;
    const val = msgSendCatch(target, Return, sel_raw, args, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = val };
}

/// Sends an Objective-C superclass message inside `@try / @catch`, returning `Error!Return`.
pub fn msgSendSuperCatch(
    target: anytype,
    superclass: objc.Class,
    comptime Return: type,
    sel_raw: anytype,
    args: anytype,
    caught_out: ?*?objc.Object,
) Error!Return {
    const Target = @TypeOf(target);
    const SelRaw = @TypeOf(sel_raw);
    const Args = @TypeOf(args);
    const Helper = struct {
        inline fn call(t: Target, sup: objc.Class, s: SelRaw, a: Args) Return {
            return t.msgSendSuper(sup, Return, s, a);
        }
    };
    return tryInvokeCatch(Helper.call, .{ target, superclass, sel_raw, args }, caught_out);
}

/// Sends an Objective-C superclass message
/// (`target.msgSendSuper(superclass, Return, sel_raw, args)`) inside an
/// Objective-C `@try / @catch` frame.
///
/// When `.exception` is non-null, it has `+1` retain ownership and the caller
/// should call `.release()` when finished inspecting it.
pub fn msgSendSuperTry(
    target: anytype,
    superclass: objc.Class,
    comptime Return: type,
    sel_raw: anytype,
    args: anytype,
) TryResult(Return) {
    var caught_exc: ?objc.Object = null;
    const val = msgSendSuperCatch(target, superclass, Return, sel_raw, args, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = val };
}

/// Sends a C-variadic Objective-C message inside `@try / @catch`, returning `Error!Return`.
pub fn msgSendVarargsCatch(
    target: anytype,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
    caught_out: ?*?objc.Object,
) Error!Return {
    const Target = @TypeOf(target);
    const SelRaw = @TypeOf(sel_raw);
    const FixedArgs = @TypeOf(fixed_args);
    const VarArgs = @TypeOf(var_args);
    const Helper = struct {
        inline fn call(t: Target, s: SelRaw, fa: FixedArgs, va: VarArgs) Return {
            return objc.msgSendVarargs(t, Return, s, fa, va);
        }
    };
    return tryInvokeCatch(Helper.call, .{ target, sel_raw, fixed_args, var_args }, caught_out);
}

/// Sends a C-variadic Objective-C message
/// (`objc.msgSendVarargs(target, Return, sel_raw, fixed_args, var_args)`) inside
/// an Objective-C `@try / @catch` frame.
///
/// When `.exception` is non-null, it has `+1` retain ownership and the caller
/// should call `.release()` when finished inspecting it.
pub fn msgSendVarargsTry(
    target: anytype,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
) TryResult(Return) {
    var caught_exc: ?objc.Object = null;
    const val = msgSendVarargsCatch(target, Return, sel_raw, fixed_args, var_args, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = val };
}

/// Sends a C-variadic Objective-C superclass message inside `@try / @catch`, returning `Error!Return`.
pub fn msgSendSuperVarargsCatch(
    target: anytype,
    superclass: objc.Class,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
    caught_out: ?*?objc.Object,
) Error!Return {
    const Target = @TypeOf(target);
    const SelRaw = @TypeOf(sel_raw);
    const FixedArgs = @TypeOf(fixed_args);
    const VarArgs = @TypeOf(var_args);
    const Helper = struct {
        inline fn call(t: Target, sup: objc.Class, s: SelRaw, fa: FixedArgs, va: VarArgs) Return {
            return objc.msgSendSuperVarargs(t, sup, Return, s, fa, va);
        }
    };
    return tryInvokeCatch(Helper.call, .{ target, superclass, sel_raw, fixed_args, var_args }, caught_out);
}

/// Sends a C-variadic Objective-C superclass message
/// (`objc.msgSendSuperVarargs(target, superclass, Return, sel_raw, fixed_args, var_args)`)
/// inside an Objective-C `@try / @catch` frame.
///
/// When `.exception` is non-null, it has `+1` retain ownership and the caller
/// should call `.release()` when finished inspecting it.
pub fn msgSendSuperVarargsTry(
    target: anytype,
    superclass: objc.Class,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
) TryResult(Return) {
    var caught_exc: ?objc.Object = null;
    const val = msgSendSuperVarargsCatch(target, superclass, Return, sel_raw, fixed_args, var_args, &caught_exc) catch {
        return .{ .exception = caught_exc };
    };
    return .{ .ok = val };
}

/// Throws an Objective-C runtime exception (`objc_exception_throw` / `@throw`).
pub fn throw(exception: ?objc.Object) noreturn {
    c.objc_exception_throw(if (exception) |exc| exc.value else null);
    unreachable;
}

/// Rethrows the currently active Objective-C exception (`objc_exception_rethrow` / `@throw;`).
/// Must only be called while an Objective-C catch handler is active on the current thread.
pub fn rethrow() noreturn {
    c.objc_exception_rethrow();
    unreachable;
}

/// Low-level ABI function called at the start of an Objective-C `@catch` block.
pub fn beginCatch(exc_buf: *anyopaque) ?objc.Object {
    const raw = objc_begin_catch(exc_buf);
    return if (raw) |ptr| objc.Object.fromId(ptr) else null;
}

/// Low-level ABI function called when exiting an Objective-C `@catch` block.
pub fn endCatch() void {
    c.objc_end_catch();
}

/// Terminates execution when an uncaught exception is encountered during unwinding.
pub fn terminate() noreturn {
    c.objc_terminate();
    unreachable;
}

/// Callback type invoked by `objc_exception_throw` before unwinding begins.
pub const ExceptionPreprocessor = c.objc_exception_preprocessor;

/// Installs an exception preprocessor and returns the previous preprocessor.
pub fn setExceptionPreprocessor(fn_ptr: ExceptionPreprocessor) ExceptionPreprocessor {
    return c.objc_setExceptionPreprocessor(fn_ptr);
}

/// Callback type used by the runtime personality routine to match thrown
/// exceptions against `@catch` clause classes.
pub const ExceptionMatcher = c.objc_exception_matcher;

/// Installs an exception matcher and returns the previous matcher.
pub fn setExceptionMatcher(fn_ptr: ExceptionMatcher) ExceptionMatcher {
    return c.objc_setExceptionMatcher(fn_ptr);
}

/// Callback type invoked before terminating due to an uncaught Objective-C exception.
pub const UncaughtExceptionHandler = c.objc_uncaught_exception_handler;

/// Installs an uncaught exception handler and returns the previous handler.
pub fn setUncaughtExceptionHandler(fn_ptr: UncaughtExceptionHandler) UncaughtExceptionHandler {
    return c.objc_setUncaughtExceptionHandler(fn_ptr);
}

/// Callback type for frame-scoped macOS exception handlers (`objc_exception_handler`).
pub const ExceptionHandler = if (@hasDecl(c, "objc_exception_handler"))
    c.objc_exception_handler
else
    ?*const fn (c.id, ?*anyopaque) callconv(.c) void;

const macos_exception_handlers = struct {
    pub fn addExceptionHandler(fn_ptr: ExceptionHandler, context: ?*anyopaque) usize {
        return c.objc_addExceptionHandler(fn_ptr, context);
    }

    pub fn removeExceptionHandler(token: usize) void {
        c.objc_removeExceptionHandler(token);
    }
};

/// Registers an exception handler on macOS (`objc_addExceptionHandler`),
/// returning a token for `removeExceptionHandler`. Unavailable on non-macOS targets.
pub const addExceptionHandler = if (builtin.target.os.tag == .macos and @hasDecl(c, "objc_addExceptionHandler"))
    macos_exception_handlers.addExceptionHandler
else {};

/// Removes a macOS exception handler previously registered with `addExceptionHandler`.
pub const removeExceptionHandler = if (builtin.target.os.tag == .macos and @hasDecl(c, "objc_removeExceptionHandler"))
    macos_exception_handlers.removeExceptionHandler
else {};

test "tryInvoke and msgSendTry non-throwing ok paths" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const Helpers = struct {
        var side_effect: usize = 0;

        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        fn touchVoid() void {
            side_effect += 1;
        }

        fn genericIdentity(x: anytype) @TypeOf(x) {
            return x;
        }
    };

    // Primitive return
    switch (tryInvoke(Helpers.add, .{ @as(i32, 19), @as(i32, 23) })) {
        .ok => |sum| try testing.expectEqual(@as(i32, 42), sum),
        .exception => return error.UnexpectedException,
    }

    // Function pointer variant
    const fn_ptr: *const fn (i32, i32) i32 = &Helpers.add;
    switch (tryInvoke(fn_ptr, .{ @as(i32, -5), @as(i32, 12) })) {
        .ok => |sum| try testing.expectEqual(@as(i32, 7), sum),
        .exception => return error.UnexpectedException,
    }

    // Generic function return
    switch (tryInvoke(Helpers.genericIdentity, .{@as(u64, 0xCAFEBABE)})) {
        .ok => |v| try testing.expectEqual(@as(u64, 0xCAFEBABE), v),
        .exception => return error.UnexpectedException,
    }

    // Zero-sized void + empty args tuple
    Helpers.side_effect = 0;
    switch (tryInvoke(Helpers.touchVoid, .{})) {
        .ok => try testing.expectEqual(@as(usize, 1), Helpers.side_effect),
        .exception => return error.UnexpectedException,
    }

    // msgSendTry returning objc.Object and primitive
    const NSString = objc.getClass("NSString").?;
    const str = switch (msgSendTry(NSString, objc.Object, "stringWithUTF8String:", .{"zig-objc"})) {
        .ok => |obj| obj,
        .exception => return error.UnexpectedException,
    };

    switch (msgSendTry(str, objc.NSUInteger, "length", .{})) {
        .ok => |len| try testing.expectEqual(@as(objc.NSUInteger, 8), len),
        .exception => return error.UnexpectedException,
    }

    // msgSendTry returning void
    const NSMutableArray = objc.getClass("NSMutableArray").?;
    const mut_arr = switch (msgSendTry(NSMutableArray, objc.Object, "array", .{})) {
        .ok => |obj| obj,
        .exception => return error.UnexpectedException,
    };
    switch (msgSendTry(mut_arr, void, "addObject:", .{str})) {
        .ok => {},
        .exception => return error.UnexpectedException,
    }
    switch (msgSendTry(mut_arr, objc.NSUInteger, "count", .{})) {
        .ok => |cnt| try testing.expectEqual(@as(objc.NSUInteger, 1), cnt),
        .exception => return error.UnexpectedException,
    }
}

test "msgSendTry catches Foundation NSRangeException with +1 ownership" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSArray = objc.getClass("NSArray").?;
    const empty = NSArray.msgSend(objc.Object, "array", .{});

    const caught_exc = blk: {
        // Drain an inner autorelease pool before inspecting the caught exception
        // to prove zig_objc_try_catch retained it at +1 before objc_end_catch.
        var inner_pool = objc.AutoreleasePool.init();
        defer inner_pool.deinit();

        switch (msgSendTry(empty, objc.Object, "objectAtIndex:", .{@as(usize, 99)})) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| break :blk maybe_exc orelse return error.ExpectedExceptionObject,
        }
    };
    defer caught_exc.release();

    const name_obj = caught_exc.msgSend(objc.Object, "name", .{});
    const name_cstr = name_obj.msgSend([*:0]const u8, "UTF8String", .{});
    try testing.expectEqualStrings("NSRangeException", std.mem.span(name_cstr));
}

test "tryCall and tracked +1 retain ownership across autorelease pool drain" {
    const testing = std.testing;
    var outer_pool = objc.AutoreleasePool.init();
    defer outer_pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const Tracked = objc.allocateClassPair(NSObject, "ZigObjcTrackedException").?;
    defer objc.disposeClassPair(Tracked);

    const Tracker = struct {
        var dealloc_count: usize = 0;

        fn dealloc(target: c.id, _: c.SEL) callconv(.c) void {
            dealloc_count += 1;
            const self = objc.Object.fromId(target);
            self.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }

        fn okCallback(ctx: ?*anyopaque) callconv(.c) void {
            const out: *usize = @ptrCast(@alignCast(ctx.?));
            out.* = 9001;
        }

        fn throwAutoreleased(_: ?*anyopaque) callconv(.c) void {
            const cls = objc.getClass("ZigObjcTrackedException").?;
            const obj = cls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
            const autoreleased = obj.msgSend(objc.Object, "autorelease", .{});
            throw(autoreleased);
        }
    };

    Tracker.dealloc_count = 0;
    _ = Tracked.replaceMethod("dealloc", Tracker.dealloc);
    objc.registerClassPair(Tracked);

    var out_val: usize = 0;
    switch (tryCall(&Tracker.okCallback, &out_val)) {
        .ok => try testing.expectEqual(@as(usize, 9001), out_val),
        .exception => return error.UnexpectedException,
    }

    const caught_exc = blk: {
        var inner_pool = objc.AutoreleasePool.init();
        defer inner_pool.deinit();

        const exc = switch (tryCall(&Tracker.throwAutoreleased, null)) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
        };
        try testing.expectEqual(@as(usize, 0), Tracker.dealloc_count);
        break :blk exc;
    };

    // inner_pool has popped and objc_end_catch has already run; +1 retain keeps it alive.
    try testing.expectEqual(@as(usize, 0), Tracker.dealloc_count);
    try testing.expectEqualStrings("ZigObjcTrackedException", caught_exc.getClassName());

    caught_exc.release();
    try testing.expectEqual(@as(usize, 1), Tracker.dealloc_count);
}

test "throw NSException inside tryInvoke and verify reason" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const Thrower = struct {
        fn raiseCustom(name_utf8: [*:0]const u8, reason_utf8: [*:0]const u8) u32 {
            const NSString = objc.getClass("NSString").?;
            const NSException = objc.getClass("NSException").?;
            const exc_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{name_utf8});
            const exc_reason = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{reason_utf8});
            const ns_exc = NSException.msgSend(
                objc.Object,
                "exceptionWithName:reason:userInfo:",
                .{ exc_name, exc_reason, @as(?objc.Object, null) },
            );
            throw(ns_exc);
        }
    };

    const res = tryInvoke(Thrower.raiseCustom, .{
        @as([*:0]const u8, "ZigObjcTestException"),
        @as([*:0]const u8, "boom from zig"),
    });
    const exc = switch (res) {
        .ok => return error.ExpectedException,
        .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
    };
    defer exc.release();

    const name_str = exc.msgSend(objc.Object, "name", .{}).msgSend([*:0]const u8, "UTF8String", .{});
    const reason_str = exc.msgSend(objc.Object, "reason", .{}).msgSend([*:0]const u8, "UTF8String", .{});
    try testing.expectEqualStrings("ZigObjcTestException", std.mem.span(name_str));
    try testing.expectEqualStrings("boom from zig", std.mem.span(reason_str));
}

test "msgSendSuperTry handles both ok and throwing superclass methods" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const Base = objc.allocateClassPair(NSObject, "ZigObjcExcSuperBase").?;
    defer objc.disposeClassPair(Base);

    const base_impls = struct {
        fn compute(_: c.id, _: c.SEL, should_throw: c.BOOL) callconv(.c) usize {
            if (cpkg.boolResult(should_throw)) {
                const NSString = objc.getClass("NSString").?;
                const NSException = objc.getClass("NSException").?;
                const n = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"SuperExc"});
                const r = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"super threw"});
                const exc = NSException.msgSend(
                    objc.Object,
                    "exceptionWithName:reason:userInfo:",
                    .{ n, r, @as(?objc.Object, null) },
                );
                throw(exc);
            }
            return 77;
        }
    };
    try testing.expect(Base.addMethod("compute:", base_impls.compute));
    objc.registerClassPair(Base);

    const Sub = objc.allocateClassPair(Base, "ZigObjcExcSuperSub").?;
    defer objc.disposeClassPair(Sub);
    objc.registerClassPair(Sub);

    const inst = Sub.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.release();

    switch (msgSendSuperTry(inst, Base, usize, "compute:", .{false})) {
        .ok => |val| try testing.expectEqual(@as(usize, 77), val),
        .exception => return error.UnexpectedException,
    }

    const exc = switch (msgSendSuperTry(inst, Base, usize, "compute:", .{true})) {
        .ok => return error.ExpectedException,
        .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
    };
    defer exc.release();

    const reason = exc.msgSend(objc.Object, "reason", .{}).msgSend([*:0]const u8, "UTF8String", .{});
    try testing.expectEqualStrings("super threw", std.mem.span(reason));
}

test "setExceptionPreprocessor, setExceptionMatcher, and setUncaughtExceptionHandler" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const Hooks = struct {
        var preproc_calls: usize = 0;

        fn preproc(exc: c.id) callconv(.c) c.id {
            preproc_calls += 1;
            return exc;
        }

        fn dummyMatcher(_: c.Class, _: c.id) callconv(.c) c_int {
            return 1;
        }

        fn dummyUncaught(_: c.id) callconv(.c) void {}
    };

    Hooks.preproc_calls = 0;
    const prev_preproc = setExceptionPreprocessor(&Hooks.preproc);
    defer _ = setExceptionPreprocessor(prev_preproc);
    try testing.expect(prev_preproc != null);

    // Verify matcher setter round-trips and restores previous matcher.
    const prev_matcher = setExceptionMatcher(&Hooks.dummyMatcher);
    try testing.expect(prev_matcher != null);
    const installed_matcher = setExceptionMatcher(prev_matcher);
    try testing.expectEqual(@as(ExceptionMatcher, &Hooks.dummyMatcher), installed_matcher);

    // Verify uncaught handler setter round-trips and restores previous handler.
    const prev_uncaught = setUncaughtExceptionHandler(&Hooks.dummyUncaught);
    const installed_uncaught = setUncaughtExceptionHandler(prev_uncaught);
    try testing.expectEqual(@as(UncaughtExceptionHandler, &Hooks.dummyUncaught), installed_uncaught);

    const NSArray = objc.getClass("NSArray").?;
    const empty = NSArray.msgSend(objc.Object, "array", .{});
    const exc = switch (msgSendTry(empty, objc.Object, "objectAtIndex:", .{@as(usize, 0)})) {
        .ok => return error.ExpectedException,
        .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
    };
    defer exc.release();

    try testing.expectEqual(@as(usize, 1), Hooks.preproc_calls);
}

test "addExceptionHandler and removeExceptionHandler on macOS" {
    const testing = std.testing;
    if (comptime (@hasDecl(@This(), "addExceptionHandler") and @TypeOf(addExceptionHandler) != void)) {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const AltState = struct {
            call_count: usize = 0,
            magic: usize = 0x1234_5678,

            fn handler(_: c.id, ctx: ?*anyopaque) callconv(.c) void {
                const state: *@This() = @ptrCast(@alignCast(ctx.?));
                if (state.magic == 0x1234_5678) {
                    state.call_count += 1;
                }
            }
        };

        const Runner = struct {
            fn throwSample() noreturn {
                const NSString = objc.getClass("NSString").?;
                const NSException = objc.getClass("NSException").?;
                const n = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"AltHandlerTest"});
                const r = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"testing alt handler"});
                const exc = NSException.msgSend(
                    objc.Object,
                    "exceptionWithName:reason:userInfo:",
                    .{ n, r, @as(?objc.Object, null) },
                );
                throw(exc);
            }

            fn registerAndRemove(state: *AltState) !void {
                const token = addExceptionHandler(&AltState.handler, state);
                try testing.expect(token != 0);
                removeExceptionHandler(token);
            }

            fn registerRemoveAndThrow(state: *AltState) void {
                const token = addExceptionHandler(&AltState.handler, state);
                std.debug.assert(token != 0);
                removeExceptionHandler(token);
                throwSample();
            }

            fn registerAndThrow(state: *AltState) void {
                const token = addExceptionHandler(&AltState.handler, state);
                std.debug.assert(token != 0);
                throwSample();
            }
        };

        var state1: AltState = .{};
        switch (tryInvoke(Runner.registerAndRemove, .{&state1})) {
            .ok => |res| try res,
            .exception => return error.UnexpectedException,
        }
        try testing.expectEqual(@as(usize, 0), state1.call_count);

        var state2: AltState = .{};
        const removed_caught = switch (tryInvoke(Runner.registerRemoveAndThrow, .{&state2})) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
        };
        defer removed_caught.release();
        try testing.expectEqual(@as(usize, 0), state2.call_count);

        var state3: AltState = .{};
        const active_caught = switch (tryInvoke(Runner.registerAndThrow, .{&state3})) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
        };
        defer active_caught.release();
        try testing.expectEqual(@as(usize, 1), state3.call_count);

        // Ensure handler from the unwound frame does not persist onto subsequent @try frames.
        const followup_caught = switch (tryInvoke(Runner.throwSample, .{})) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
        };
        defer followup_caught.release();
        try testing.expectEqual(@as(usize, 1), state3.call_count);
    }
}

test "non-NSException NSNumber throw, @throw nil, foreign C++ exception, and fast-path return types" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const NSDecimalNumber = objc.getClass("NSDecimalNumber").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const NSString = objc.getClass("NSString").?;

    const Helpers = struct {
        const AllocExcFn = *const fn (usize) callconv(.c) *anyopaque;
        const ThrowExcFn = *const fn (
            *anyopaque,
            ?*const anyopaque,
            ?*const fn (*anyopaque) callconv(.c) void,
        ) callconv(.c) noreturn;

        fn addScalars(a: i64, b: i64) i64 {
            return a + b;
        }

        fn makeRect(scale: f64) NSRect {
            return .{ .x = 1.0 * scale, .y = 2.0 * scale, .w = 3.0 * scale, .h = 4.0 * scale };
        }

        fn maybeObj(present: bool) ?objc.Object {
            if (!present) return null;
            return objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{"ok"});
        }

        fn noopVoid(counter: *usize) void {
            counter.* += 1;
        }

        fn throwObj(obj: ?objc.Object) i32 {
            throw(obj);
        }

        fn throwForeignInt(code: c_int) NSRect {
            const cxxabi = std.c.dlopen("/usr/lib/libc++abi.dylib", .{ .LAZY = true }) orelse
                @panic("failed to dlopen libc++abi.dylib");
            const alloc_exc: AllocExcFn = @ptrCast(@alignCast(std.c.dlsym(cxxabi, "__cxa_allocate_exception") orelse
                @panic("missing __cxa_allocate_exception")));
            const throw_exc: ThrowExcFn = @ptrCast(@alignCast(std.c.dlsym(cxxabi, "__cxa_throw") orelse
                @panic("missing __cxa_throw")));
            const int_tinfo: *const anyopaque = std.c.dlsym(cxxabi, "_ZTIi") orelse
                @panic("missing _ZTIi");

            const slot: *c_int = @ptrCast(@alignCast(alloc_exc(@sizeOf(c_int))));
            slot.* = code;
            throw_exc(slot, int_tinfo, null);
        }
    };

    // 1. Non-throwing fast path returning void, scalar, NSRect struct, and ?objc.Object
    var visits: usize = 0;
    try tryInvokeCatch(Helpers.noopVoid, .{&visits}, null);
    try testing.expectEqual(@as(usize, 1), visits);

    const sum = try tryInvokeCatch(Helpers.addScalars, .{ 19, 23 }, null);
    try testing.expectEqual(@as(i64, 42), sum);

    const scalar_res = tryInvoke(Helpers.makeRect, .{2.5});
    try testing.expect(!scalar_res.hasThrown());
    try testing.expectEqual(@as(f64, 10.0), scalar_res.ok.h);

    const rect = try tryInvokeCatch(Helpers.makeRect, .{3.0}, null);
    try testing.expectEqual(@as(f64, 3.0), rect.x);
    try testing.expectEqual(@as(f64, 12.0), rect.h);

    const opt_some = try tryInvokeCatch(Helpers.maybeObj, .{true}, null);
    try testing.expectEqualStrings("ok", std.mem.span(opt_some.?.msgSend([*:0]const u8, "UTF8String", .{})));
    const opt_none = try tryInvokeCatch(Helpers.maybeObj, .{false}, null);
    try testing.expect(opt_none == null);

    // Verify Object.fromId on unaligned tagged-pointer NSNumber (`@(42)`) via ?*anyopaque
    const tagged_num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 42)});
    const raw_tagged: ?*anyopaque = @ptrFromInt(@intFromPtr(tagged_num.value));
    const roundtrip_tagged = objc.Object.fromId(raw_tagged.?);
    try testing.expectEqual(@as(c_int, 42), roundtrip_tagged.msgSend(c_int, "intValue", .{}));

    // 2. Throw and catch a non-NSException NSNumber subclass (`NSDecimalNumber`; macOS libobjc
    // `_objc_fatal`s inside `objc_exception_throw` if given a tagged pointer directly).
    const forty_two_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"42"});
    const heap_num = NSDecimalNumber.msgSend(objc.Object, "decimalNumberWithString:", .{forty_two_str});
    var caught_num: ?objc.Object = null;
    try testing.expectError(
        error.ExceptionThrown,
        tryInvokeCatch(Helpers.throwObj, .{@as(?objc.Object, heap_num)}, &caught_num),
    );
    try testing.expect(caught_num != null);
    defer caught_num.?.release();
    try testing.expectEqual(@as(c_int, 42), caught_num.?.msgSend(c_int, "intValue", .{}));

    const try_res_num = tryInvoke(Helpers.throwObj, .{@as(?objc.Object, heap_num)});
    try testing.expect(try_res_num.hasThrown());
    try testing.expectEqual(@as(c_int, 42), try_res_num.exception.?.msgSend(c_int, "intValue", .{}));
    try_res_num.exception.?.release();

    // 3. `@throw nil;` -> Error.ExceptionThrown with caught_out == null
    var caught_nil: ?objc.Object = tagged_num;
    try testing.expectError(
        error.ExceptionThrown,
        tryInvokeCatch(Helpers.throwObj, .{@as(?objc.Object, null)}, &caught_nil),
    );
    try testing.expect(caught_nil == null);

    // Passing `caught_out = null` on a real Objective-C object exception releases it without leaking
    const NSMutableString = objc.getClass("NSMutableString").?;
    const str_exc = NSMutableString.msgSend(objc.Object, "stringWithUTF8String:", .{"discarded"});
    try testing.expectError(
        error.ExceptionThrown,
        tryInvokeCatch(Helpers.throwObj, .{@as(?objc.Object, str_exc)}, null),
    );

    // 4. Foreign C++ exception (`throw 404;`) caught via `@catch (...)` -> Error.ForeignExceptionThrown
    var caught_foreign: ?objc.Object = tagged_num;
    try testing.expectError(
        error.ForeignExceptionThrown,
        tryInvokeCatch(Helpers.throwForeignInt, .{@as(c_int, 404)}, &caught_foreign),
    );
    try testing.expect(caught_foreign == null);

    const foreign_try = tryInvoke(Helpers.throwForeignInt, .{@as(c_int, 500)});
    try testing.expect(foreign_try.hasThrown());
    try testing.expect(foreign_try.exception == null);
}

test "msgSendVarargsTry and msgSendSuperVarargsTry handle ok and throwing variadic calls" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClassCached("NSString").?;
    const NSMutableString = objc.getClassCached("NSMutableString").?;
    const NSPredicate = objc.getClassCached("NSPredicate").?;

    const fmt = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"%s:%d"});
    switch (NSString.msgSendVarargsTry(objc.Object, objc.S("stringWithFormat:"), .{fmt}, .{ "ok", @as(c_int, 7) })) {
        .ok => |s| try testing.expectEqualStrings("ok:7", std.mem.span(s.msgSend([*:0]const u8, objc.S("UTF8String"), .{}))),
        .exception => return error.UnexpectedException,
    }

    // Throwing class variadic call: malformed NSPredicate format string
    const bad_pred_fmt = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"INVALID === %%%"});
    const pred_exc = switch (NSPredicate.msgSendVarargsTry(objc.Object, objc.S("predicateWithFormat:"), .{bad_pred_fmt}, .{@as(c_int, 1)})) {
        .ok => return error.ExpectedException,
        .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
    };
    defer pred_exc.release();

    // Throwing variadic call via msgSendVarargsCatch: +[NSException raise:format:]
    const NSException = objc.getClassCached("NSException").?;
    const exc_name = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"ZigVarargCatchTest"});
    const exc_fmt = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"err=%s:%d"});
    var caught_vararg_exc: ?objc.Object = null;
    try testing.expectError(
        error.ExceptionThrown,
        msgSendVarargsCatch(NSException, void, objc.S("raise:format:"), .{ exc_name, exc_fmt }, .{ "boom", @as(c_int, 17) }, &caught_vararg_exc),
    );
    try testing.expect(caught_vararg_exc != null);
    defer caught_vararg_exc.?.release();
    try testing.expectEqualStrings(
        "err=boom:17",
        std.mem.span(caught_vararg_exc.?.msgSend(objc.Object, objc.S("reason"), .{}).msgSend([*:0]const u8, objc.S("UTF8String"), .{})),
    );

    // Superclass variadic ok path on instance (`-[NSMutableString appendFormat:]`) and
    // throwing path on metaclass (`+[NSException raise:format:]`)
    const CustomMutStr = objc.allocateClassPair(NSMutableString, "ZigObjcExcVarargMutStr").?;
    defer objc.disposeClassPair(CustomMutStr);

    try testing.expect(CustomMutStr.addMethod("init", struct {
        fn init(self_obj: objc.Object, _: objc.Sel) callconv(.c) c.id {
            self_obj.release();
            return objc.getClassCached("NSMutableString").?.msgSend(objc.Object, objc.S("alloc"), .{}).msgSend(
                objc.Object,
                objc.S("initWithUTF8String:"),
                .{"base"},
            ).value;
        }
    }.init));
    objc.registerClassPair(CustomMutStr);

    const sub_str = objc.allocInit(CustomMutStr).?;
    defer sub_str.release();

    const suffix_fmt = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{":%d"});
    switch (sub_str.msgSendSuperVarargsTry(NSMutableString, void, objc.S("appendFormat:"), .{suffix_fmt}, .{@as(c_int, 99)})) {
        .ok => {},
        .exception => return error.UnexpectedException,
    }
    try testing.expectEqualStrings("base:99", std.mem.span(sub_str.msgSend([*:0]const u8, objc.S("UTF8String"), .{})));

    const SubException = objc.allocateClassPair(NSException, "ZigObjcSubVarargException").?;
    defer objc.disposeClassPair(SubException);
    objc.registerClassPair(SubException);

    {
        // Drain the autoreleased SubException instance before `disposeClassPair(SubException)` runs.
        var inner_pool = objc.AutoreleasePool.init();
        defer inner_pool.deinit();

        const exc_meta = objc.getMetaClass("NSException").?;
        const sup_exc = switch (SubException.msgSendSuperVarargsTry(exc_meta, void, objc.S("raise:format:"), .{ exc_name, exc_fmt }, .{ "super", @as(c_int, 55) })) {
            .ok => return error.ExpectedException,
            .exception => |maybe_exc| maybe_exc orelse return error.ExpectedExceptionObject,
        };
        defer sup_exc.release();
        try testing.expectEqualStrings(
            "err=super:55",
            std.mem.span(sup_exc.msgSend(objc.Object, objc.S("reason"), .{}).msgSend([*:0]const u8, objc.S("UTF8String"), .{})),
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}
