const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
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
pub fn setForwardHandler(fwd: *anyopaque, fwd_stret: *anyopaque) void {
    c.objc_setForwardHandler(fwd, fwd_stret);
}

/// Returns a struct that implements the msgSend function for type T.
pub fn MsgSend(comptime T: type) type {
    // 1. T should be a struct
    // 2. T should have a field "value" that can be an "id" (same size)

    return struct {
        /// Invoke a selector on the target, i.e. an instance method on an
        /// object or a class method on a class. The args should be a tuple.
        pub fn msgSend(
            target: T,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            const RealReturn = unwrapType(Return);

            // We accept multiple types for sel but we need to turn it into
            // an objc.sel ultimately.
            const sel: objc.Sel = switch (@TypeOf(sel_raw)) {
                objc.Sel => sel_raw,
                else => objc.sel(sel_raw),
            };

            // Build our function type and call it
            const Fn = MsgSendFn(RealReturn, @TypeOf(target.value), @TypeOf(args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, false);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));

            const unwrapped_args = buildUnwrappedArgs(args);
            const result = @call(.auto, msg_send_ptr, .{ target.value, sel.value } ++ unwrapped_args);

            return wrapReturn(Return, result);
        }

        /// Invoke a selector on the superclass.
        pub fn msgSendSuper(
            target: T,
            superclass: objc.Class,
            comptime Return: type,
            sel_raw: anytype,
            args: anytype,
        ) Return {
            const RealReturn = unwrapType(Return);
            const sel: objc.Sel = switch (@TypeOf(sel_raw)) {
                objc.Sel => sel_raw,
                else => objc.sel(sel_raw),
            };

            const Fn = MsgSendFn(RealReturn, *c.objc_super, @TypeOf(args));
            const msg_send_fn = comptime msgSendPtr(RealReturn, true);
            const msg_send_ptr: *const Fn = @ptrCast(@alignCast(msg_send_fn));
            var super: c.objc_super =
                if (comptime @hasField(c.objc_super, "super_class"))
                    .{
                        .receiver = target.value,
                        .super_class = superclass.value,
                    }
                else
                    .{
                        .receiver = target.value,
                        .class = superclass.value,
                    };

            const unwrapped_args = buildUnwrappedArgs(args);
            const result = @call(.auto, msg_send_ptr, .{ &super, sel.value } ++ unwrapped_args);

            return wrapReturn(Return, result);
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

/// If `T` is an `objc` runtime handle wrapper (`Object`, `Class`, `Protocol`,
/// `Sel`, `Property`, `Ivar`, or `Method`), returns its underlying C ABI pointer type.
fn WrapperUnderlying(comptime T: type) ?type {
    return switch (T) {
        objc.Object => c.id,
        objc.Class => c.Class,
        objc.Protocol => *c.Protocol,
        objc.Sel => c.SEL,
        objc.Property => c.objc_property_t,
        objc.Ivar => c.Ivar,
        objc.Method => c.Method,
        else => null,
    };
}

fn NullablePtr(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .optional => V,
        .pointer => |p| if (p.size == .c) V else ?V,
        else => unreachable,
    };
}

/// This returns a function body type for `objc_msgSend` that matches
/// the given return type, target type, and arguments tuple type.
fn MsgSendFn(
    comptime Return: type,
    comptime Target: type,
    comptime Args: type,
) type {
    const argsInfo = @typeInfo(Args).@"struct";
    assert(argsInfo.is_tuple);

    // Target must always be an "id". Lots of types (Class, Object, etc.)
    // are an "id" so we just make sure the sizes match for ABI reasons.
    assert(@sizeOf(Target) == @sizeOf(c.id));

    // Build up our argument types for @Fn
    var param_types: [argsInfo.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = c.SEL;
    for (argsInfo.field_types, 0..) |field_type, i| param_types[i + 2] = unwrapType(field_type);

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    const field_types = @typeInfo(Args).@"struct".field_types;
    var types: [field_types.len]type = undefined;
    for (field_types, 0..) |field_type, i| types[i] = unwrapType(field_type);
    return @Tuple(&types);
}

/// Maps objc wrapper types and `bool` to their underlying C ABI types for use in `@Fn`
/// signatures, and validates that all other types are C-ABI compatible.
fn unwrapType(comptime T: type) type {
    if (T == bool) return c.BOOL;

    if (WrapperUnderlying(T)) |V| return V;

    switch (@typeInfo(T)) {
        .int, .float, .void, .@"enum", .vector => {},
        .pointer => |p| {
            if (p.size == .slice)
                @compileError("msgSend: " ++ @typeName(T) ++ " — Zig slices are not C-ABI compatible");
        },
        .optional => |opt| {
            if (WrapperUnderlying(opt.child)) |V| return NullablePtr(V);
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice)
                @compileError("msgSend: " ++ @typeName(T) ++ " — optional must wrap a pointer or objc wrapper");
        },
        .@"struct" => |s| {
            if (s.layout != .@"extern" and s.layout != .@"packed")
                @compileError("msgSend: " ++ @typeName(T) ++ " — struct must be extern or packed");
            if (s.layout == .@"packed" and @bitSizeOf(T) > 128)
                @compileError("msgSend: " ++ @typeName(T) ++ " — packed struct larger than 128 bits is not C-ABI compatible");
        },
        .@"union" => |u| {
            if (u.layout != .@"extern")
                @compileError("msgSend: " ++ @typeName(T) ++ " — union must be extern");
        },
        else => @compileError("msgSend: " ++ @typeName(T) ++ " — not C-ABI compatible"),
    }

    return T;
}

inline fn unwrapArg(arg: anytype) unwrapType(@TypeOf(arg)) {
    const T = @TypeOf(arg);
    if (T == bool) return cpkg.boolParam(arg);
    if (comptime WrapperUnderlying(T) != null) return arg.value;
    if (comptime @typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (comptime WrapperUnderlying(Child) != null) {
            return if (arg) |unwrapped| unwrapped.value else null;
        }
    }
    return arg;
}

inline fn wrapReturn(comptime Return: type, raw: unwrapType(Return)) Return {
    if (Return == bool) return cpkg.boolResult(raw);
    if (comptime WrapperUnderlying(Return) != null) return Return{ .value = raw };
    if (comptime @typeInfo(Return) == .optional) {
        const Child = @typeInfo(Return).optional.child;
        if (comptime WrapperUnderlying(Child)) |V| {
            if (comptime @typeInfo(V) == .optional or (@typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .c)) {
                return if (raw == null) null else Child{ .value = raw };
            } else {
                return if (raw) |ptr| Child{ .value = ptr } else null;
            }
        }
    }
    return raw;
}

inline fn buildUnwrappedArgs(args: anytype) UnwrappedArgs(@TypeOf(args)) {
    const field_types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    var result: UnwrappedArgs(@TypeOf(args)) = undefined;
    inline for (field_types, 0..) |_, i| {
        result[i] = unwrapArg(args[i]);
    }
    return result;
}

test "MsgSendFn signatures" {
    const testing = std.testing;
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
        MsgSendFn(unwrapType(bool), c.id, @TypeOf(.{
            true,
            @as(?objc.Object, null),
            @as(?objc.Class, null),
            @as(?objc.Protocol, null),
            @as(?objc.Sel, null),
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
