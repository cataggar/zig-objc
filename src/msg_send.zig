const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const abi = @import("abi.zig");
const cpkg = @import("c.zig");
const c = cpkg.c;
const exception = @import("exception.zig");
const objc = @import("main.zig");

/// Entry point for the Objective-C runtime's message forwarding machinery.
/// Can be installed as a method `IMP` or compared against `class_getMethodImplementation`.
pub const msgForward: c.IMP = @ptrCast(&c._objc_msgForward);

/// Structure-returning message forwarding entry point on architectures that use
/// separate `stret` dispatch (`x86_64`). `null` on `aarch64` where `_objc_msgForward_stret`
/// is unavailable in the ABI.
pub const msgForwardStret: c.IMP = if (builtin.target.cpu.arch != .aarch64 and @hasDecl(c, "_objc_msgForward_stret"))
    @ptrCast(&c._objc_msgForward_stret)
else
    null;

/// Sets custom handlers invoked by `_objc_msgForward` and `_objc_msgForward_stret`.
pub inline fn setForwardHandler(fwd: *anyopaque, fwd_stret: *anyopaque) void {
    c.objc_setForwardHandler(fwd, fwd_stret);
}

/// Invokes a C-variadic Objective-C selector on `target`, passing `fixed_args` in
/// fixed C-ABI parameter slots and `var_args` with C99 default argument promotions
/// (stack-passed on `aarch64-macos`).
pub inline fn msgSendVarargs(
    target: anytype,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
) Return {
    return MsgSend(@TypeOf(target)).msgSendVarargs(target, Return, sel_raw, fixed_args, var_args);
}

/// Invokes a C-variadic Objective-C selector on `target`'s `superclass`, passing
/// `fixed_args` in fixed C-ABI parameter slots and `var_args` with C99 default
/// argument promotions (stack-passed on `aarch64-macos`).
pub inline fn msgSendSuperVarargs(
    target: anytype,
    superclass: objc.Class,
    comptime Return: type,
    sel_raw: anytype,
    fixed_args: anytype,
    var_args: anytype,
) Return {
    return MsgSend(@TypeOf(target)).msgSendSuperVarargs(target, superclass, Return, sel_raw, fixed_args, var_args);
}

/// Returns a struct that implements Objective-C `msgSend` dispatch functions for `T`.
pub fn MsgSend(comptime T: type) type {
    return struct {
        /// Invoke a selector on the target, i.e. an instance method on an
        /// object or a class method on a class. The args should be a tuple.
        pub inline fn msgSend(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            @setEvalBranchQuota(100_000);
            const RealReturn = abi.UnwrapReturnType(Return, true);
            const sel = resolveSel(sel_raw);
            const target_id = unwrapReceiver(target);

            const Fn = MsgSendFn(RealReturn, @TypeOf(target_id), @TypeOf(args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, false);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));

            const call_args = abi.buildCallArgs(.{ target_id, sel.value }, args, true);
            const target_can_be_null = @typeInfo(@TypeOf(target_id)) == .optional or
                (@typeInfo(@TypeOf(target_id)) == .pointer and @typeInfo(@TypeOf(target_id)).pointer.size == .c);
            if (comptime (cpkg.usesIndirectReturn(RealReturn) and target_can_be_null)) {
                if (target_id == null) return abi.wrapReturn(Return, std.mem.zeroes(RealReturn), true);
            }
            const result = @call(.auto, msg_send_ptr, call_args);

            return abi.wrapReturn(Return, result, true);
        }

        /// Invoke a selector on the superclass.
        pub inline fn msgSendSuper(
            target: T,
            superclass: objc.Class,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            @setEvalBranchQuota(100_000);
            const RealReturn = abi.UnwrapReturnType(Return, true);
            const sel = resolveSel(sel_raw);
            const target_id = unwrapReceiver(target);

            const Fn = MsgSendFn(RealReturn, *c.objc_super, @TypeOf(args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, true);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));
            var super = initSuper(target_id, superclass);

            const call_args = abi.buildCallArgs(.{ &super, sel.value }, args, true);
            const target_can_be_null = @typeInfo(@TypeOf(target_id)) == .optional or
                (@typeInfo(@TypeOf(target_id)) == .pointer and @typeInfo(@TypeOf(target_id)).pointer.size == .c);
            if (comptime (cpkg.usesIndirectReturn(RealReturn) and target_can_be_null)) {
                if (target_id == null) return abi.wrapReturn(Return, std.mem.zeroes(RealReturn), true);
            }
            const result = @call(.auto, msg_send_ptr, call_args);

            return abi.wrapReturn(Return, result, true);
        }

        /// Invoke a C-variadic Objective-C selector (such as `+[NSString stringWithFormat:]`
        /// or `+[NSArray arrayWithObjects:]`) on `target`.
        ///
        /// `fixed_args` holds the tuple of non-variadic Objective-C parameters declared
        /// before `...`; `var_args` holds the tuple of variadic arguments after `...`,
        /// which undergo C99 default promotions and pass on the stack on Apple Silicon.
        pub inline fn msgSendVarargs(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            fixed_args: anytype,
            var_args: anytype,
        ) Return {
            @setEvalBranchQuota(100_000);
            const RealReturn = abi.UnwrapReturnType(Return, true);
            const sel = resolveSel(sel_raw);
            const target_id = unwrapReceiver(target);

            const Fn = VarargMsgSendFn(RealReturn, @TypeOf(target_id), @TypeOf(fixed_args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, false);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));

            const call_args = abi.buildVarargCallArgs(.{ target_id, sel.value }, fixed_args, var_args);
            const target_can_be_null = @typeInfo(@TypeOf(target_id)) == .optional or
                (@typeInfo(@TypeOf(target_id)) == .pointer and @typeInfo(@TypeOf(target_id)).pointer.size == .c);
            if (comptime (cpkg.usesIndirectReturn(RealReturn) and target_can_be_null)) {
                if (target_id == null) return abi.wrapReturn(Return, std.mem.zeroes(RealReturn), true);
            }
            const result = @call(.auto, msg_send_ptr, call_args);

            return abi.wrapReturn(Return, result, true);
        }

        /// Invoke a C-variadic Objective-C selector on `target`'s `superclass`.
        ///
        /// `fixed_args` holds the tuple of non-variadic Objective-C parameters declared
        /// before `...`; `var_args` holds the tuple of variadic arguments after `...`,
        /// which undergo C99 default promotions and pass on the stack on Apple Silicon.
        pub inline fn msgSendSuperVarargs(
            target: T,
            superclass: objc.Class,
            comptime Return: type,
            sel_raw: anytype,
            fixed_args: anytype,
            var_args: anytype,
        ) Return {
            @setEvalBranchQuota(100_000);
            const RealReturn = abi.UnwrapReturnType(Return, true);
            const sel = resolveSel(sel_raw);
            const target_id = unwrapReceiver(target);

            const Fn = VarargMsgSendFn(RealReturn, *c.objc_super, @TypeOf(fixed_args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, true);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));
            var super = initSuper(target_id, superclass);

            const call_args = abi.buildVarargCallArgs(.{ &super, sel.value }, fixed_args, var_args);
            const target_can_be_null = @typeInfo(@TypeOf(target_id)) == .optional or
                (@typeInfo(@TypeOf(target_id)) == .pointer and @typeInfo(@TypeOf(target_id)).pointer.size == .c);
            if (comptime (cpkg.usesIndirectReturn(RealReturn) and target_can_be_null)) {
                if (target_id == null) return abi.wrapReturn(Return, std.mem.zeroes(RealReturn), true);
            }
            const result = @call(.auto, msg_send_ptr, call_args);

            return abi.wrapReturn(Return, result, true);
        }

        /// Invoke a selector on the target inside an Objective-C `@try / @catch`
        /// frame, returning `exception.TryResult(Return)`.
        pub fn msgSendTry(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) exception.TryResult(Return) {
            return exception.msgSendTry(target, Return, sel_raw, args);
        }

        /// Invoke a selector on the superclass inside an Objective-C `@try / @catch`
        /// frame, returning `exception.TryResult(Return)`.
        pub fn msgSendSuperTry(
            target: T,
            superclass: objc.Class,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) exception.TryResult(Return) {
            return exception.msgSendSuperTry(target, superclass, Return, sel_raw, args);
        }

        /// Invoke a C-variadic selector on the target inside an Objective-C
        /// `@try / @catch` frame, returning `exception.TryResult(Return)`.
        pub fn msgSendVarargsTry(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            fixed_args: anytype,
            var_args: anytype,
        ) exception.TryResult(Return) {
            return exception.msgSendVarargsTry(target, Return, sel_raw, fixed_args, var_args);
        }

        /// Invoke a C-variadic selector on the superclass inside an Objective-C
        /// `@try / @catch` frame, returning `exception.TryResult(Return)`.
        pub fn msgSendSuperVarargsTry(
            target: T,
            superclass: objc.Class,
            comptime Return: type,
            sel_raw: anytype,
            fixed_args: anytype,
            var_args: anytype,
        ) exception.TryResult(Return) {
            return exception.msgSendSuperVarargsTry(target, superclass, Return, sel_raw, fixed_args, var_args);
        }

        /// Returns the objc_msgSend or objc_msgSendSuper pointer for the
        /// given C-ABI return type.
        fn msgSendPtr(
            comptime Return: type,
            comptime super: bool,
        ) *const fn () callconv(.c) void {
            // See objc/message.h. Depending on the target architecture and
            // return type, we must use the matching objc_msgSend entry point.
            return switch (builtin.target.cpu.arch) {
                // AArch64 uses objc_msgSend / objc_msgSendSuper for all types.
                .aarch64 => if (super) &c.objc_msgSendSuper else &c.objc_msgSend,

                // x86_64 SysV AMD64 ABI routing:
                // - MEMORY-class aggregates (> 16 bytes, unaligned fields, or mixed x87)
                //   return on the stack via objc_msgSend_stret / objc_msgSendSuper_stret
                // - [X87, X87UP] 80-bit `long double` (and single-leaf `long double`
                //   aggregates at offset 0) return in x87 %st(0) via objc_msgSend_fpret
                //   (super calls still use objc_msgSendSuper; no Super_fpret exists)
                // - `float` (f32), `double` (f64 / CGFloat), register-class structs/unions,
                //   and packed structs <= 128 bits return via objc_msgSend / objc_msgSendSuper
                .x86_64 => blk: {
                    if (cpkg.usesStret(Return)) {
                        break :blk if (super) &c.objc_msgSendSuper_stret else &c.objc_msgSend_stret;
                    }
                    if (cpkg.usesFpret(Return)) {
                        break :blk if (super) &c.objc_msgSendSuper else &c.objc_msgSend_fpret;
                    }
                    switch (@typeInfo(Return)) {
                        .int,
                        .bool,
                        .@"enum",
                        .pointer,
                        .void,
                        .vector,
                        .float,
                        .@"struct",
                        .@"union",
                        => break :blk if (super) &c.objc_msgSendSuper else &c.objc_msgSend,

                        .optional => |opt| {
                            assert(@typeInfo(opt.child) == .pointer);
                            break :blk if (super) &c.objc_msgSendSuper else &c.objc_msgSend;
                        },

                        else => {
                            @compileLog(@typeInfo(Return));
                            @compileError("unsupported return type for objc runtime on x86_64");
                        },
                    }
                },

                else => @compileError("unsupported objc architecture"),
            };
        }
    };
}

inline fn resolveSel(sel_raw: anytype) objc.Sel {
    return switch (@TypeOf(sel_raw)) {
        objc.Sel => sel_raw,
        c.SEL => .{ .value = sel_raw },
        else => objc.sel(sel_raw),
    };
}

fn ReceiverAbiType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => {
            if (!@hasField(T, "value")) {
                @compileError("msgSend: receiver struct " ++ @typeName(T) ++ " must have a 'value' field");
            }
            return ReceiverAbiType(@TypeOf(@as(T, undefined).value));
        },
        .pointer => |p| {
            if (p.size == .slice or @sizeOf(T) != @sizeOf(c.id)) {
                @compileError("msgSend: receiver " ++ @typeName(T) ++ " is not C-ABI compatible with id");
            }
            return T;
        },
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice or @sizeOf(T) != @sizeOf(c.id)) {
                @compileError("msgSend: receiver " ++ @typeName(T) ++ " is not C-ABI compatible with id");
            }
            return T;
        },
        else => @compileError("msgSend: invalid receiver type " ++ @typeName(T)),
    };
}

fn ReceiverUnwrapper(comptime T: type) type {
    return struct {
        inline fn unwrap(target: T) ReceiverAbiType(T) {
            if (comptime @typeInfo(T) == .@"struct") {
                return ReceiverUnwrapper(@TypeOf(target.value)).unwrap(target.value);
            }
            return target;
        }
    };
}

inline fn unwrapReceiver(target: anytype) ReceiverAbiType(@TypeOf(target)) {
    return ReceiverUnwrapper(@TypeOf(target)).unwrap(target);
}

inline fn initSuper(target_id: anytype, superclass: objc.Class) c.objc_super {
    const receiver_id: c.id = if (@TypeOf(target_id) == c.id)
        target_id
    else
        objc.Object.fromId(target_id).value;

    return if (comptime @hasField(c.objc_super, "super_class"))
        .{
            .receiver = receiver_id,
            .super_class = superclass.value,
        }
    else
        .{
            .receiver = receiver_id,
            .class = superclass.value,
        };
}

/// Returns a non-variadic `@Fn` signature for `objc_msgSend` / `objc_msgSendSuper`
/// matching the given C-ABI return type, receiver type, and arguments tuple type.
fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    if (@typeInfo(Args) != .@"struct" or !@typeInfo(Args).@"struct".is_tuple) {
        @compileError("msgSend: args must be a tuple, got " ++ @typeName(Args));
    }
    const args_info = @typeInfo(Args).@"struct";
    assert(@sizeOf(Target) == @sizeOf(c.id));

    var param_types: [args_info.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (args_info.field_types, 0..) |field_type, i| {
        param_types[i + 2] = abi.UnwrapParamType(field_type, true);
    }

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

/// Returns a C-variadic (`.varargs = true`) `@Fn` signature for `objc_msgSend` /
/// `objc_msgSendSuper` with fixed parameter types `(Target, c.SEL, fixed_args...)`.
fn VarargMsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime FixedArgs: type,
) type {
    if (@typeInfo(FixedArgs) != .@"struct" or !@typeInfo(FixedArgs).@"struct".is_tuple) {
        @compileError("msgSendVarargs: fixed_args must be a tuple, got " ++ @typeName(FixedArgs));
    }
    const fixed_info = @typeInfo(FixedArgs).@"struct";
    assert(@sizeOf(Target) == @sizeOf(c.id));

    var param_types: [fixed_info.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (fixed_info.field_types, 0..) |field_type, i| {
        param_types[i + 2] = abi.UnwrapParamType(field_type, true);
    }

    return @Fn(&param_types, &@splat(.{}), Return, .{
        .@"callconv" = .c,
        .varargs = true,
    });
}

test "MsgSendFn signatures" {
    const testing = std.testing;
    const Ref = objc.BlockRef(.{i32}, i32);

    try testing.expectEqual(fn (
        c.id,
        c.SEL,
    ) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{})));
    try testing.expectEqual(fn (c.id, c.SEL, u16, u32) callconv(.c) u64, MsgSendFn(u64, c.id, @TypeOf(.{
        @as(u16, 0),
        @as(u32, 0),
    })));
    try testing.expectEqual(
        fn (c.id, c.SEL, c.BOOL, c.id, c.Class, ?*c.Protocol, c.SEL) callconv(.c) c.BOOL,
        MsgSendFn(abi.UnwrapReturnType(bool, true), c.id, @TypeOf(.{
            true,
            @as(?objc.Object, null),
            @as(?objc.Class, null),
            @as(?objc.Protocol, null),
            @as(?objc.Sel, null),
        })),
    );
    try testing.expectEqual(
        fn (c.id, c.SEL, *anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
        MsgSendFn(abi.UnwrapReturnType(?Ref, true), c.id, @TypeOf(.{
            @as(Ref, undefined),
            @as(?Ref, null),
        })),
    );
    try testing.expectEqual(
        fn (c.Class, c.SEL, c.id, ...) callconv(.c) c.id,
        VarargMsgSendFn(abi.UnwrapReturnType(objc.Object, true), c.Class, @TypeOf(.{
            @as(objc.Object, .{ .value = null }),
        })),
    );

    if (builtin.target.cpu.arch == .x86_64) {
        const Sender = MsgSend(objc.Object);
        const Small = extern struct { a: u64, b: u64 };
        const Large = extern struct { a: u64, b: u64, d: u64 };
        const Unaligned9 = extern struct { a: u8, b: i64 align(1) };
        const TailPacked9 = extern struct { a: i64 align(1), b: u8 };
        const LongDoubleWrap = extern struct { x: c_longdouble };
        const Packed64 = packed struct(u64) { lo: u32, hi: u32 };
        try testing.expectEqual(&c.objc_msgSend, Sender.msgSendPtr(f32, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(f32, true));
        try testing.expectEqual(&c.objc_msgSend, Sender.msgSendPtr(f64, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(f64, true));
        try testing.expectEqual(&c.objc_msgSend_fpret, Sender.msgSendPtr(c_longdouble, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(c_longdouble, true));
        try testing.expectEqual(&c.objc_msgSend_fpret, Sender.msgSendPtr(LongDoubleWrap, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(LongDoubleWrap, true));
        try testing.expectEqual(&c.objc_msgSend, Sender.msgSendPtr(Small, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(Small, true));
        try testing.expectEqual(&c.objc_msgSend_stret, Sender.msgSendPtr(Large, false));
        try testing.expectEqual(&c.objc_msgSendSuper_stret, Sender.msgSendPtr(Large, true));
        try testing.expectEqual(&c.objc_msgSend_stret, Sender.msgSendPtr(Unaligned9, false));
        try testing.expectEqual(&c.objc_msgSendSuper_stret, Sender.msgSendPtr(Unaligned9, true));
        try testing.expectEqual(&c.objc_msgSend, Sender.msgSendPtr(TailPacked9, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(TailPacked9, true));
        try testing.expectEqual(&c.objc_msgSend, Sender.msgSendPtr(Packed64, false));
        try testing.expectEqual(&c.objc_msgSendSuper, Sender.msgSendPtr(Packed64, true));
        try testing.expect(msgForwardStret != null);
    } else if (builtin.target.cpu.arch == .aarch64) {
        try testing.expect(msgForwardStret == null);
    }
}

test "subClass" {
    const Subclass = objc.allocateClassPair(objc.getClass("NSObject").?, "subclass").?;
    defer objc.disposeClassPair(Subclass);
    const str = struct {
        fn inner(target: objc.c.id, sel: objc.c.SEL) callconv(.c) objc.c.id {
            _ = sel;
            const self = objc.Object.fromId(target);
            self.msgSendSuper(objc.getClass("NSObject").?, void, "init", .{});
            return target;
        }
    };
    _ = Subclass.replaceMethod("init", str.inner);
    objc.registerClassPair(Subclass);
    const subclass_obj = Subclass.msgSend(objc.Object, "alloc", .{});
    defer subclass_obj.msgSend(void, "dealloc", .{});
    subclass_obj.msgSend(void, "init", .{});
}

test "msgSend f32, f64, and bool roundtrips" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSNumber = objc.getClass("NSNumber").?;

    const num_f64 = NSNumber.msgSend(objc.Object, "numberWithDouble:", .{@as(f64, 3.141592653589793)});
    try testing.expectApproxEqAbs(@as(f64, 3.141592653589793), num_f64.msgSend(f64, "doubleValue", .{}), 1e-12);

    const num_f32 = NSNumber.msgSend(objc.Object, "numberWithFloat:", .{@as(f32, -42.5)});
    try testing.expectApproxEqAbs(@as(f32, -42.5), num_f32.msgSend(f32, "floatValue", .{}), 1e-6);

    const num_true = NSNumber.msgSend(objc.Object, "numberWithBool:", .{true});
    try testing.expect(num_true.msgSend(bool, "boolValue", .{}));

    const num_false = NSNumber.msgSend(objc.Object, "numberWithBool:", .{false});
    try testing.expect(!num_false.msgSend(bool, "boolValue", .{}));
}

test "msgSend optional wrappers (?Object, ?Class, ?Protocol, ?Sel)" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSString = objc.getClass("NSString").?;

    const dict = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
    const key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"present"});
    const missing = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"missing"});
    const val = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"hello"});

    try testing.expect(dict.msgSend(?objc.Object, "objectForKey:", .{missing}) == null);

    dict.msgSend(void, "setObject:forKey:", .{ val, key });
    const found = dict.msgSend(?objc.Object, "objectForKey:", .{key}) orelse return error.ExpectedObject;
    try testing.expect(found.msgSend(bool, "isEqualToString:", .{val}));

    // Real runtime root/subclass ?Class returns (`[NSObject superclass]` is nil)
    const NSObject = objc.getClass("NSObject").?;
    const NSMutableString = objc.getClass("NSMutableString").?;
    try testing.expect(NSObject.msgSend(?objc.Class, "superclass", .{}) == null);
    try testing.expectEqual(NSString.value, NSMutableString.msgSend(?objc.Class, "superclass", .{}).?.value);

    // Dynamic class exercising ?Object, ?Class, ?Protocol, ?Sel arguments and returns.
    const Helper = objc.allocateClassPair(NSObject, "ZigObjcOptionalWrapperTest").?;
    defer objc.disposeClassPair(Helper);

    const impls = struct {
        fn echoObj(_: c.id, _: c.SEL, arg: c.id) callconv(.c) c.id {
            return arg;
        }
        fn echoClass(_: c.id, _: c.SEL, arg: c.Class) callconv(.c) c.Class {
            return arg;
        }
        fn echoProto(_: c.id, _: c.SEL, arg: ?*c.Protocol) callconv(.c) ?*c.Protocol {
            return arg;
        }
        fn echoSel(_: c.id, _: c.SEL, arg: c.SEL) callconv(.c) c.SEL {
            return arg;
        }
    };

    try testing.expect(Helper.addMethod("echoObj:", impls.echoObj));
    try testing.expect(Helper.addMethod("echoClass:", impls.echoClass));
    try testing.expect(Helper.addMethod("echoProto:", impls.echoProto));
    try testing.expect(Helper.addMethod("echoSel:", impls.echoSel));
    objc.registerClassPair(Helper);

    const inst = Helper.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.msgSend(void, "release", .{});

    try testing.expect(inst.msgSend(?objc.Object, "echoObj:", .{@as(?objc.Object, null)}) == null);
    const echoed_obj = inst.msgSend(?objc.Object, "echoObj:", .{@as(?objc.Object, val)}).?;
    try testing.expectEqual(val.value, echoed_obj.value);

    try testing.expect(inst.msgSend(?objc.Class, "echoClass:", .{@as(?objc.Class, null)}) == null);
    const echoed_cls = inst.msgSend(?objc.Class, "echoClass:", .{@as(?objc.Class, NSString)}).?;
    try testing.expectEqual(NSString.value, echoed_cls.value);

    const obj_proto = objc.getProtocol("NSObject").?;
    try testing.expect(inst.msgSend(?objc.Protocol, "echoProto:", .{@as(?objc.Protocol, null)}) == null);
    const echoed_proto = inst.msgSend(?objc.Protocol, "echoProto:", .{@as(?objc.Protocol, obj_proto)}).?;
    try testing.expect(echoed_proto.isEqual(obj_proto));

    const init_sel = objc.sel("init");
    try testing.expect(inst.msgSend(?objc.Sel, "echoSel:", .{@as(?objc.Sel, null)}) == null);
    const echoed_sel = inst.msgSend(?objc.Sel, "echoSel:", .{@as(?objc.Sel, init_sel)}).?;
    try testing.expect(echoed_sel.isEqual(init_sel));
}

test "msgSend and msgSendSuper struct returns (<= 16 bytes and > 16 bytes)" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const SmallPair = extern struct { a: u64, b: u64 };
    const LargeRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

    const Base = objc.allocateClassPair(NSObject, "ZigObjcStructBase").?;
    defer objc.disposeClassPair(Base);

    const base_impls = struct {
        fn getSmall(_: c.id, _: c.SEL) callconv(.c) SmallPair {
            return .{ .a = 11, .b = 22 };
        }
        fn getLarge(_: c.id, _: c.SEL) callconv(.c) LargeRect {
            return .{ .x = 1.0, .y = 2.0, .w = 30.0, .h = 40.0 };
        }
    };
    try testing.expect(Base.addMethod("getSmall", base_impls.getSmall));
    try testing.expect(Base.addMethod("getLarge", base_impls.getLarge));
    objc.registerClassPair(Base);

    const Sub = objc.allocateClassPair(Base, "ZigObjcStructSub").?;
    defer objc.disposeClassPair(Sub);

    const sub_impls = struct {
        fn getLarge(target: c.id, _: c.SEL) callconv(.c) LargeRect {
            const self = objc.Object.fromId(target);
            const sup = self.msgSendSuper(objc.getClass("ZigObjcStructBase").?, LargeRect, "getLarge", .{});
            return .{ .x = sup.x + 10.0, .y = sup.y + 20.0, .w = sup.w * 2.0, .h = sup.h * 2.0 };
        }
    };
    try testing.expect(Sub.addMethod("getLarge", sub_impls.getLarge));
    objc.registerClassPair(Sub);

    const sub = Sub.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer sub.msgSend(void, "release", .{});

    const small = sub.msgSend(SmallPair, "getSmall", .{});
    try testing.expectEqual(SmallPair{ .a = 11, .b = 22 }, small);

    const large = sub.msgSend(LargeRect, "getLarge", .{});
    try testing.expectEqual(LargeRect{ .x = 11.0, .y = 22.0, .w = 60.0, .h = 80.0 }, large);
}

test "msgForward" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    try testing.expect(msgForward != null);

    const NSObject = objc.getClass("NSObject").?;
    const missing_imp = c.class_getMethodImplementation(NSObject.value, objc.sel("zigObjcDefinitelyMissingSelector").value);
    try testing.expectEqual(msgForward, missing_imp);

    // Build a lightweight proxy class whose `length` IMP is `msgForward` and
    // which forwards unrecognized selectors to an inner NSString via
    // `forwardingTargetForSelector:`.
    const Proxy = objc.allocateClassPair(NSObject, "ZigObjcForwardProxy").?;
    defer objc.disposeClassPair(Proxy);

    const proxy_impls = struct {
        fn forwardingTarget(_: c.id, _: c.SEL, _: c.SEL) callconv(.c) c.id {
            const NSString = objc.getClass("NSString").?;
            return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"forwarded!"}).value;
        }
    };
    try testing.expect(Proxy.addMethod("forwardingTargetForSelector:", proxy_impls.forwardingTarget));
    try testing.expect(cpkg.boolResult(c.class_addMethod(Proxy.value, objc.sel("length").value, msgForward, "Q@:")));
    objc.registerClassPair(Proxy);

    const proxy = Proxy.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer proxy.msgSend(void, "release", .{});

    const len = proxy.msgSend(objc.NSUInteger, "length", .{});
    try testing.expectEqual(@as(objc.NSUInteger, 10), len);
}

test "WrapperUnderlying Ivar/Method and msgSendTry/msgSendSuperTry delegates" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;

    const Base = objc.allocateClassPair(NSObject, "ZigObjcMsgSendTryBase").?;
    defer objc.disposeClassPair(Base);
    try testing.expect(Base.addIvar(usize, "sample_ivar"));
    try testing.expect(Base.addMethod("echoIvar:", struct {
        fn imp(_: c.id, _: c.SEL, iv: c.Ivar) callconv(.c) c.Ivar {
            return iv;
        }
    }.imp));
    try testing.expect(Base.addMethod("echoMethod:", struct {
        fn imp(_: c.id, _: c.SEL, m: c.Method) callconv(.c) c.Method {
            return m;
        }
    }.imp));
    try testing.expect(Base.addMethod("checkPositive:", struct {
        fn imp(_: c.id, _: c.SEL, val: i64) callconv(.c) i64 {
            if (val < 0) {
                const NSString = objc.getClass("NSString").?;
                const NSException = objc.getClass("NSException").?;
                const name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"ZigNegativeError"});
                const reason = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"negative input"});
                const exc = NSException.msgSend(
                    objc.Object,
                    "exceptionWithName:reason:userInfo:",
                    .{ name, reason, @as(?objc.Object, null) },
                );
                objc.exception.throw(exc);
            }
            return val * 2;
        }
    }.imp));
    objc.registerClassPair(Base);

    const Sub = objc.allocateClassPair(Base, "ZigObjcMsgSendTrySub").?;
    defer objc.disposeClassPair(Sub);
    objc.registerClassPair(Sub);

    const inst = objc.allocInit(Sub).?;
    defer inst.release();

    const iv = Base.getInstanceVariable("sample_ivar").?;
    const got_iv = inst.msgSend(?objc.Ivar, "echoIvar:", .{iv});
    try testing.expectEqual(iv.value, got_iv.?.value);
    try testing.expect(inst.msgSend(?objc.Ivar, "echoIvar:", .{@as(?objc.Ivar, null)}) == null);

    const m = Base.getInstanceMethod(objc.sel("echoMethod:")).?;
    const got_m = inst.msgSend(?objc.Method, "echoMethod:", .{m});
    try testing.expectEqual(m.value, got_m.?.value);
    try testing.expect(inst.msgSend(?objc.Method, "echoMethod:", .{@as(?objc.Method, null)}) == null);

    // Delegate msgSendTry and msgSendSuperTry on Object and Class
    switch (inst.msgSendTry(i64, "checkPositive:", .{@as(i64, 21)})) {
        .ok => |v| try testing.expectEqual(@as(i64, 42), v),
        .exception => return error.UnexpectedException,
    }
    switch (inst.msgSendTry(i64, "checkPositive:", .{@as(i64, -1)})) {
        .ok => return error.ExpectedException,
        .exception => |exc_opt| {
            const exc = exc_opt orelse return error.NullException;
            defer exc.release();
        },
    }
    switch (inst.msgSendSuperTry(Base, i64, "checkPositive:", .{@as(i64, -5)})) {
        .ok => return error.ExpectedException,
        .exception => |exc_opt| {
            const exc = exc_opt orelse return error.NullException;
            defer exc.release();
        },
    }
    switch (NSObject.msgSendTry(objc.Class, "class", .{})) {
        .ok => |cls| try testing.expectEqual(NSObject.value, cls.value),
        .exception => return error.UnexpectedException,
    }
}

test "msgSend and msgSendSuper with unaligned, tail-packed, packed, and long-double structs" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const Unaligned9 = extern struct { a: u8, b: i64 align(1) };
    const TailPacked9 = extern struct { a: i64 align(1), b: u8 };
    const Packed64 = packed struct(u64) { lo: u32, hi: u32 };
    const LongDoubleWrap = extern struct { x: c_longdouble };

    const NSObject = objc.getClass("NSObject").?;
    const Base = objc.allocateClassPair(NSObject, "ZigObjcUnalignedAbiBase").?;
    defer objc.disposeClassPair(Base);

    const base_impls = struct {
        fn getUnaligned(_: c.id, _: c.SEL) callconv(.c) Unaligned9 {
            return .{ .a = 0x5A, .b = -0x1234_5678_9ABC_DEF0 };
        }
        fn getTailPacked(_: c.id, _: c.SEL) callconv(.c) TailPacked9 {
            return .{ .a = 0x0FED_CBA9_8765_4321, .b = 0x7F };
        }
        fn getPacked(_: c.id, _: c.SEL) callconv(.c) Packed64 {
            return .{ .lo = 100, .hi = 200 };
        }
        fn getLongDoubleWrap(_: c.id, _: c.SEL) callconv(.c) LongDoubleWrap {
            return .{ .x = 6.25 };
        }
    };
    try testing.expect(Base.addMethod("getUnaligned", base_impls.getUnaligned));
    try testing.expect(Base.addMethod("getTailPacked", base_impls.getTailPacked));
    try testing.expect(Base.addMethod("getPacked", base_impls.getPacked));
    try testing.expect(Base.addMethod("getLongDoubleWrap", base_impls.getLongDoubleWrap));
    objc.registerClassPair(Base);

    const Sub = objc.allocateClassPair(Base, "ZigObjcUnalignedAbiSub").?;
    defer objc.disposeClassPair(Sub);

    const sub_impls = struct {
        fn getUnaligned(target: c.id, _: c.SEL) callconv(.c) Unaligned9 {
            const self = objc.Object.fromId(target);
            const sup = self.msgSendSuper(objc.getClass("ZigObjcUnalignedAbiBase").?, Unaligned9, "getUnaligned", .{});
            return .{ .a = sup.a + 1, .b = sup.b + 10 };
        }
    };
    try testing.expect(Sub.addMethod("getUnaligned", sub_impls.getUnaligned));
    objc.registerClassPair(Sub);

    const inst = objc.allocInit(Sub).?;
    defer inst.release();

    const unaligned = inst.msgSend(Unaligned9, "getUnaligned", .{});
    try testing.expectEqual(@as(u8, 0x5B), unaligned.a);
    try testing.expectEqual(@as(i64, -0x1234_5678_9ABC_DEE6), unaligned.b);

    const tail_packed = inst.msgSend(TailPacked9, "getTailPacked", .{});
    try testing.expectEqual(@as(i64, 0x0FED_CBA9_8765_4321), tail_packed.a);
    try testing.expectEqual(@as(u8, 0x7F), tail_packed.b);

    const packed_val = inst.msgSend(Packed64, "getPacked", .{});
    try testing.expectEqual(Packed64{ .lo = 100, .hi = 200 }, packed_val);

    const ld_wrap = inst.msgSend(LongDoubleWrap, "getLongDoubleWrap", .{});
    try testing.expectApproxEqAbs(@as(f64, 6.25), @as(f64, @floatCast(ld_wrap.x)), 1e-12);
}

test "msgSend and msgSendSuper with BlockRef and ?BlockRef arguments and returns" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const NSString = objc.getClass("NSString").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const NSSortDescriptor = objc.getClass("NSSortDescriptor").?;

    // 1. Real Foundation ?BlockRef return and argument (`NSSortDescriptor` comparator)
    const ComparatorRef = objc.BlockRef(.{ objc.Object, objc.Object }, objc.NSInteger);
    const self_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"self"});

    const sel_sort_desc = NSSortDescriptor.msgSend(
        objc.Object,
        "sortDescriptorWithKey:ascending:",
        .{ self_key, true },
    );
    try testing.expect(sel_sort_desc.msgSend(?ComparatorRef, "comparator", .{}) == null);

    const CmpBlock = objc.Block(struct {}, .{ objc.Object, objc.Object }, objc.NSInteger);
    const global_cmp = CmpBlock.initGlobal(&(struct {
        fn cmp(_: *const CmpBlock.Context, a: c.id, b: c.id) callconv(.c) objc.NSInteger {
            return objc.Object.fromId(a).msgSend(objc.NSInteger, "compare:", .{objc.Object.fromId(b)});
        }
    }).cmp);
    const cmp_ref = CmpBlock.asBlockRef(global_cmp);

    const block_sort_desc = NSSortDescriptor.msgSend(
        objc.Object,
        "sortDescriptorWithKey:ascending:comparator:",
        .{ self_key, true, @as(?ComparatorRef, cmp_ref) },
    );
    const got_cmp = block_sort_desc.msgSend(?ComparatorRef, "comparator", .{}).?;
    const n5 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 5)});
    const n9 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 9)});
    try testing.expectEqual(@as(objc.NSInteger, -1), got_cmp.invoke(.{ n5, n9 }));

    // 2. Dynamic Base + Sub exercising non-null and null ?BlockRef through msgSend and msgSendSuper
    const CalcBlock = objc.Block(struct { bias: i64 }, .{i64}, i64);
    const CalcRef = CalcBlock.Ref;
    const GlobalCalcBlock = objc.Block(struct {}, .{i64}, i64);

    const Base = objc.allocateClassPair(NSObject, "ZigObjcMsgSendBlockRefBase").?;
    defer objc.disposeClassPair(Base);

    const base_impls = struct {
        const global_calc_ctx = GlobalCalcBlock.initGlobal(&runTriple);

        fn runTriple(_: *const GlobalCalcBlock.Context, x: i64) callconv(.c) i64 {
            return x * 3;
        }
        fn evalOptional(_: c.id, _: c.SEL, maybe_blk: ?*anyopaque, x: i64, fallback: i64) callconv(.c) i64 {
            if (CalcRef.fromPtr(maybe_blk)) |blk| {
                return blk.invoke(.{x});
            }
            return fallback;
        }
        fn makeBlock(_: c.id, _: c.SEL, non_null: c.BOOL) callconv(.c) ?*anyopaque {
            if (cpkg.boolResult(non_null)) {
                return GlobalCalcBlock.asBlockRef(global_calc_ctx).value;
            }
            return null;
        }
    };
    try testing.expect(Base.addMethod("evalOptional:x:fallback:", base_impls.evalOptional));
    try testing.expect(Base.addMethod("makeBlock:", base_impls.makeBlock));
    objc.registerClassPair(Base);

    const Sub = objc.allocateClassPair(Base, "ZigObjcMsgSendBlockRefSub").?;
    defer objc.disposeClassPair(Sub);
    const sub_impls = struct {
        fn evalOptional(target: c.id, _: c.SEL, maybe_blk: ?*anyopaque, x: i64, fallback: i64) callconv(.c) i64 {
            const self_obj = objc.Object.fromId(target);
            const opt_ref = CalcRef.fromPtr(maybe_blk);
            return self_obj.msgSendSuper(
                objc.getClass("ZigObjcMsgSendBlockRefBase").?,
                i64,
                "evalOptional:x:fallback:",
                .{ opt_ref, x + 1, fallback },
            );
        }
    };
    try testing.expect(Sub.addMethod("evalOptional:x:fallback:", sub_impls.evalOptional));
    objc.registerClassPair(Sub);

    const inst = objc.allocInit(Sub).?;
    defer inst.release();

    var stack_calc = CalcBlock.init(.{ .bias = 100 }, &(struct {
        fn run(ctx: *const CalcBlock.Context, x: i64) callconv(.c) i64 {
            return ctx.bias + x;
        }
    }).run);
    const stack_ref = CalcBlock.asBlockRef(&stack_calc);

    try testing.expectEqual(
        @as(i64, 111),
        inst.msgSend(i64, "evalOptional:x:fallback:", .{ @as(?CalcRef, stack_ref), @as(i64, 10), @as(i64, -1) }),
    );
    try testing.expectEqual(
        @as(i64, -99),
        inst.msgSend(i64, "evalOptional:x:fallback:", .{ @as(?CalcRef, null), @as(i64, 10), @as(i64, -99) }),
    );

    try testing.expect(inst.msgSend(?CalcRef, "makeBlock:", .{false}) == null);
    const returned_blk = inst.msgSend(?CalcRef, "makeBlock:", .{true}).?;
    try testing.expectEqual(@as(i64, 21), returned_blk.invoke(.{@as(i64, 7)}));
    const non_opt_blk = inst.msgSend(CalcRef, "makeBlock:", .{true});
    try testing.expectEqual(@as(i64, 27), non_opt_blk.invoke(.{@as(i64, 9)}));

    // Nil receiver returns null for ?BlockRef cleanly
    const nil_obj: objc.Object = .{ .value = null };
    try testing.expect(nil_obj.msgSend(?CalcRef, "makeBlock:", .{true}) == null);
}

test "msgSendVarargs and msgSendSuperVarargs with Foundation variadic selectors" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClass("NSString").?;
    const NSMutableString = objc.getClass("NSMutableString").?;
    const NSArray = objc.getClass("NSArray").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const NSPredicate = objc.getClass("NSPredicate").?;

    // 1. +[NSString stringWithFormat:] with mixed promoted C variadic arguments
    const fmt = NSString.msgSend(objc.Object, objc.Sel.cached("stringWithUTF8String:"), .{"%d %s %.2f %@ %d %hd"});
    const obj_str = NSString.msgSend(objc.Object, objc.Sel.cached("stringWithUTF8String:"), .{"world"});

    const formatted = MsgSend(objc.Class).msgSendVarargs(
        NSString,
        objc.Object,
        objc.Sel.cached("stringWithFormat:"),
        .{fmt},
        .{ @as(c_int, 42), "hello", @as(f32, 3.5), obj_str, true, @as(i16, -7) },
    );
    try testing.expectEqualStrings(
        "42 hello 3.50 world 1 -7",
        std.mem.span(formatted.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    // Exercise > 8 variadic arguments so both aarch64 stack slots and x86_64 register overflow are tested
    const long_fmt = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{"%d-%d-%d-%d-%d-%d-%d-%d-%.1f-%s"},
    );
    const long_str = msgSendVarargs(
        NSString,
        objc.Object,
        "stringWithFormat:",
        .{long_fmt},
        .{
            @as(u8, 1),
            @as(i16, 2),
            @as(c_int, 3),
            4,
            @as(c_int, 5),
            @as(u16, 6),
            @as(i8, 7),
            @as(c_int, 8),
            @as(f32, 9.5),
            "ten",
        },
    );
    try testing.expectEqualStrings(
        "1-2-3-4-5-6-7-8-9.5-ten",
        std.mem.span(long_str.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    // Instance variadic call (`-[NSMutableString appendFormat:]` returning void)
    const mut_str = NSMutableString.msgSend(objc.Object, "stringWithUTF8String:", .{"start"});
    const append_fmt = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{":%s=%d"});
    MsgSend(objc.Object).msgSendVarargs(
        mut_str,
        void,
        "appendFormat:",
        .{append_fmt},
        .{ "k", @as(u8, 77) },
    );
    try testing.expectEqualStrings(
        "start:k=77",
        std.mem.span(mut_str.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    // 2. +[NSArray arrayWithObjects:] with null-terminated variadic object list
    const n1 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 10)});
    const n2 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 20)});
    const n3 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 30)});

    const arr = msgSendVarargs(
        NSArray,
        objc.Object,
        objc.Sel.cached("arrayWithObjects:"),
        .{n1},
        .{ n2, n3, null },
    );
    try testing.expectEqual(@as(usize, 3), arr.msgSend(usize, "count", .{}));
    try testing.expectEqual(@as(c_int, 10), arr.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)}).msgSend(c_int, "intValue", .{}));
    try testing.expectEqual(@as(c_int, 20), arr.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 1)}).msgSend(c_int, "intValue", .{}));
    try testing.expectEqual(@as(c_int, 30), arr.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 2)}).msgSend(c_int, "intValue", .{}));

    // +[NSPredicate predicateWithFormat:]
    const pred_fmt = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"intValue == %d"});
    const pred = msgSendVarargs(NSPredicate, objc.Object, "predicateWithFormat:", .{pred_fmt}, .{@as(c_int, 20)});
    try testing.expect(pred.msgSend(bool, "evaluateWithObject:", .{n2}));
    try testing.expect(!pred.msgSend(bool, "evaluateWithObject:", .{n1}));

    // 3. msgSendSuperVarargs on both an instance (custom NSString subclass calling
    //    super -[NSString stringByAppendingFormat:]) and a metaclass (+[NSArray arrayWithObjects:])
    const CustomStr = objc.allocateClassPair(NSString, "ZigObjcVarargSuperString").?;
    defer objc.disposeClassPair(CustomStr);

    const custom_str_impls = struct {
        const literal = "base";

        fn length(_: c.id, _: c.SEL) callconv(.c) objc.NSUInteger {
            return literal.len;
        }
        fn characterAtIndex(_: c.id, _: c.SEL, idx: objc.NSUInteger) callconv(.c) u16 {
            return literal[idx];
        }
        fn formatSuffix(target: c.id, _: c.SEL, tag: c_int) callconv(.c) c.id {
            const self_obj = objc.Object.fromId(target);
            const NSStringCls = objc.getClass("NSString").?;
            const suffix_fmt = NSStringCls.msgSend(objc.Object, "stringWithUTF8String:", .{":%d:%s:%.1f"});
            return msgSendSuperVarargs(
                self_obj,
                NSStringCls,
                objc.Object,
                "stringByAppendingFormat:",
                .{suffix_fmt},
                .{ tag, "sup", @as(f32, 2.5) },
            ).value;
        }
    };
    try testing.expect(CustomStr.addMethod("length", custom_str_impls.length));
    try testing.expect(CustomStr.addMethod("characterAtIndex:", custom_str_impls.characterAtIndex));
    try testing.expect(CustomStr.addMethod("formatSuffix:", custom_str_impls.formatSuffix));
    objc.registerClassPair(CustomStr);

    const custom_inst = objc.allocInit(CustomStr).?;
    defer custom_inst.release();

    const super_formatted = custom_inst.msgSend(objc.Object, "formatSuffix:", .{@as(c_int, 9)});
    try testing.expectEqualStrings(
        "base:9:sup:2.5",
        std.mem.span(super_formatted.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    // Metaclass msgSendSuperVarargs calling +[NSArray arrayWithObjects:]
    const SubArray = objc.allocateClassPair(NSArray, "ZigObjcVarargSuperArray").?;
    defer objc.disposeClassPair(SubArray);

    try testing.expect(SubArray.addMethod("initWithObjects:count:", struct {
        fn initWithObjectsCount(
            self_id: c.id,
            _: c.SEL,
            objects: [*c]const c.id,
            count: objc.NSUInteger,
        ) callconv(.c) c.id {
            objc.Object.fromId(self_id).release();
            return objc.getClass("NSArray").?.msgSend(objc.Object, "alloc", .{}).msgSend(
                objc.Object,
                "initWithObjects:count:",
                .{ objects, count },
            ).value;
        }
    }.initWithObjectsCount));

    const sub_array_meta = objc.Object.fromId(SubArray.value).getClass().?;
    try testing.expect(sub_array_meta.addMethod("pairFirst:second:", struct {
        fn makePair(cls: objc.Class, _: c.SEL, a: c.id, b: c.id) callconv(.c) c.id {
            const super_meta = objc.getMetaClass("NSArray").?;
            return MsgSend(objc.Class).msgSendSuperVarargs(
                cls,
                super_meta,
                objc.Object,
                "arrayWithObjects:",
                .{objc.Object.fromId(a)},
                .{ objc.Object.fromId(b), null },
            ).value;
        }
    }.makePair));
    objc.registerClassPair(SubArray);

    const super_arr = SubArray.msgSend(objc.Object, "pairFirst:second:", .{ n1, n3 });
    try testing.expectEqual(@as(usize, 2), super_arr.msgSend(usize, "count", .{}));
    try testing.expectEqual(@as(c_int, 10), super_arr.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)}).msgSend(c_int, "intValue", .{}));
    try testing.expectEqual(@as(c_int, 30), super_arr.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 1)}).msgSend(c_int, "intValue", .{}));
}

test "nil receiver zero-initializes indirect-return (sret) aggregates and preserves arg side effects" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const BigInts = extern struct {
        a: u64,
        b: u64,
        c: u64,
        d: u64,
    };
    const CGAffineTransform = extern struct {
        a: f64,
        b: f64,
        c: f64,
        d: f64,
        tx: f64,
        ty: f64,
    };

    try testing.expect(cpkg.usesIndirectReturn(BigInts));
    try testing.expect(cpkg.usesIndirectReturn(CGAffineTransform));

    const Helpers = struct {
        noinline fn dirtyStack() void {
            var poison: [256]u64 = @splat(0xDEAD_BEEF_CAFE_BABE);
            std.mem.doNotOptimizeAway(&poison);
        }

        noinline fn sendNilBigInts(nil_obj: objc.Object, counter: *usize) BigInts {
            return nil_obj.msgSend(BigInts, "anything:", .{blk: {
                counter.* += 1;
                break :blk @as(i32, 7);
            }});
        }

        noinline fn sendNilVarargsBigInts(nil_obj: objc.Object, counter: *usize) BigInts {
            return nil_obj.msgSendVarargs(
                BigInts,
                "anything:",
                .{blk: {
                    counter.* += 10;
                    break :blk @as(i32, 1);
                }},
                .{blk: {
                    counter.* += 100;
                    break :blk @as(i32, 2);
                }},
            );
        }

        noinline fn sendNilAffine(nil_obj: objc.Object) CGAffineTransform {
            return nil_obj.msgSend(CGAffineTransform, "anything", .{});
        }
    };

    const nil_obj: objc.Object = .{ .value = null };
    var side_effects: usize = 0;

    Helpers.dirtyStack();
    const res1 = Helpers.sendNilBigInts(nil_obj, &side_effects);
    try testing.expectEqual(BigInts{ .a = 0, .b = 0, .c = 0, .d = 0 }, res1);
    try testing.expectEqual(@as(usize, 1), side_effects);

    Helpers.dirtyStack();
    const res2 = Helpers.sendNilVarargsBigInts(nil_obj, &side_effects);
    try testing.expectEqual(BigInts{ .a = 0, .b = 0, .c = 0, .d = 0 }, res2);
    try testing.expectEqual(@as(usize, 111), side_effects);

    Helpers.dirtyStack();
    const res3 = Helpers.sendNilAffine(nil_obj);
    try testing.expectEqual(
        CGAffineTransform{ .a = 0, .b = 0, .c = 0, .d = 0, .tx = 0, .ty = 0 },
        res3,
    );
}

test "msgSendVarargs promotes narrow (< 32-bit) packed struct and packed union arguments" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const PackedU8 = packed struct(u8) { lo: u4, hi: u4 };
    const PackedI8 = packed struct(i8) { lo: u4, hi: i4 };
    const PackedUnion8 = packed union { raw: u8, nibbles: PackedU8 };

    const NSString = objc.getClass("NSString").?;
    const fmt = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"%d:%d:%d"});

    const pu8: PackedU8 = .{ .lo = 0x5, .hi = 0xA }; // 0xA5 = 165
    const pi8: PackedI8 = @bitCast(@as(i8, -9));
    const punion: PackedUnion8 = .{ .raw = 200 };

    const formatted = msgSendVarargs(
        NSString,
        objc.Object,
        "stringWithFormat:",
        .{fmt},
        .{ pu8, pi8, punion },
    );
    try testing.expectEqualStrings(
        "165:-9:200",
        std.mem.span(formatted.msgSend([*:0]const u8, "UTF8String", .{})),
    );
}

test "idiomatic NSError** out-parameter pattern using *objc.Object" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const NSString = objc.getClass("NSString").?;

    const ErrClass = objc.allocateClassPair(NSObject, "ZigObjcSafeOutErrorTest").?;
    defer objc.disposeClassPair(ErrClass);

    const impls = struct {
        fn performOperation(
            _: objc.Object,
            _: objc.Sel,
            should_fail: c.BOOL,
            out_err: ?*objc.Object,
        ) callconv(.c) c.BOOL {
            if (cpkg.boolResult(should_fail)) {
                if (out_err) |err_slot| {
                    const domain = objc.getClass("NSString").?.msgSend(
                        objc.Object,
                        "stringWithUTF8String:",
                        .{"com.zig-objc.test"},
                    );
                    err_slot.* = objc.getClass("NSError").?.msgSend(
                        objc.Object,
                        "errorWithDomain:code:userInfo:",
                        .{ domain, @as(objc.NSInteger, 404), @as(?objc.Object, null) },
                    );
                }
                return cpkg.boolParam(false);
            }
            return cpkg.boolParam(true);
        }
    };
    try testing.expect(ErrClass.addMethod("performOperation:error:", impls.performOperation));
    objc.registerClassPair(ErrClass);

    const inst = objc.allocInit(ErrClass).?;
    defer inst.release();

    // 1. Success path: `err.value` remains `null`
    var err: objc.Object = .{ .value = null };
    try testing.expect(inst.msgSend(bool, "performOperation:error:", .{ false, &err }));
    try testing.expect(err.value == null);

    // 2. Failure path: `err` is populated cleanly with the 8-byte `NSError *`
    try testing.expect(!inst.msgSend(bool, "performOperation:error:", .{ true, &err }));
    try testing.expect(err.value != null);
    try testing.expectEqual(@as(objc.NSInteger, 404), err.msgSend(objc.NSInteger, "code", .{}));
    const domain = err.msgSend(objc.Object, "domain", .{});
    try testing.expectEqualStrings(
        "com.zig-objc.test",
        std.mem.span(domain.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    // 3. Real Foundation NSError** selector (`+[NSString stringWithContentsOfFile:encoding:error:]`)
    var cocoa_err: objc.Object = .{ .value = null };
    const missing_path = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{"/nonexistent-zig-objc-path-9f8e7d6c5b4a/missing.txt"},
    );
    const ns_utf8_encoding: objc.NSUInteger = 4;
    const contents = NSString.msgSend(
        ?objc.Object,
        "stringWithContentsOfFile:encoding:error:",
        .{ missing_path, ns_utf8_encoding, &cocoa_err },
    );
    try testing.expect(contents == null);
    try testing.expect(cocoa_err.value != null);
    try testing.expect(cocoa_err.msgSend(objc.NSInteger, "code", .{}) != 0);
}
