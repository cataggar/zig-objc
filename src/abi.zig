const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

/// Reports whether `T` is a `BlockRef(...)` `extern struct` handle.
pub fn isBlockRefType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.layout == .@"extern" and
            (@hasDecl(T, "zig_objc_is_block_ref") or @hasDecl(T, "is_objc_block")) and
            @hasField(T, "value"),
        else => false,
    };
}

/// Reports whether `T` is a Clang/Zig `Block` context layout struct (`BlockLayout` or `Block(...).Context`).
pub fn isBlockContextStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "is_objc_block_context")) return true;
    const info = @typeInfo(T).@"struct";
    if (info.field_names.len < 5) return false;
    return std.mem.eql(u8, info.field_names[0], "isa") and
        std.mem.eql(u8, info.field_names[1], "flags") and
        std.mem.eql(u8, info.field_names[2], "reserved") and
        std.mem.eql(u8, info.field_names[3], "invoke") and
        std.mem.eql(u8, info.field_names[4], "descriptor");
}

/// If `T` is an `objc` runtime handle wrapper (`Object`, `Class`, `Protocol`,
/// `Sel`, `Property`, `Ivar`, or `Method`), returns its underlying C ABI pointer type.
pub fn WrapperUnderlying(comptime T: type) ?type {
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

/// Turns single/many non-optional pointers (`*X`, `[*]X`) into `?*X` / `?[*]X`,
/// while keeping already-optional or `[*c]` pointers unchanged.
pub fn NullablePtr(comptime P: type) type {
    return switch (@typeInfo(P)) {
        .optional => P,
        .pointer => |p| switch (p.size) {
            .c => P,
            .one, .many => ?P,
            .slice => @compileError("C-ABI call cannot use Zig slice " ++ @typeName(P) ++ "; pass .ptr and .len"),
        },
        else => @compileError("NullablePtr expected a pointer or optional pointer type, got " ++ @typeName(P)),
    };
}

/// Maps `T` to its C-ABI parameter type when invoking Objective-C functions,
/// `objc_msgSend`, `method_invoke`, or blocks.
pub fn UnwrapParamType(comptime T: type, comptime convert_bool: bool) type {
    if (convert_bool and T == bool) return c.BOOL;
    if (WrapperUnderlying(T)) |U| return U;
    if (isBlockRefType(T)) return *anyopaque;

    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .vector => return T,
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("C-ABI call cannot pass Zig slice " ++ @typeName(T) ++ " directly; pass .ptr and .len");
            }
            return T;
        },
        .@"struct" => |s| {
            if (s.layout == .auto) {
                @compileError("C-ABI call requires an extern or packed struct, got auto-layout struct " ++ @typeName(T));
            }
            if (s.layout == .@"packed" and @bitSizeOf(T) > 128) {
                @compileError("C-ABI call does not support packed struct larger than 128 bits: " ++ @typeName(T));
            }
            return T;
        },
        .@"union" => |u| {
            if (u.layout == .auto) {
                @compileError("C-ABI call requires an extern or packed union, got auto-layout union " ++ @typeName(T));
            }
            if (u.layout == .@"packed" and @bitSizeOf(T) > 128) {
                @compileError("C-ABI call does not support packed union larger than 128 bits: " ++ @typeName(T));
            }
            return T;
        },
        .optional => |opt| {
            if (WrapperUnderlying(opt.child)) |U| return NullablePtr(U);
            if (isBlockRefType(opt.child)) return ?*anyopaque;
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice) {
                @compileError("C-ABI optional must wrap a non-slice pointer, objc wrapper, or BlockRef, got " ++ @typeName(T));
            }
            return T;
        },
        .comptime_int => @compileError("C-ABI call cannot pass untyped comptime_int directly; cast with @as(T, value)"),
        .comptime_float => @compileError("C-ABI call cannot pass untyped comptime_float directly; cast with @as(T, value)"),
        .null => @compileError("C-ABI call cannot pass untyped null directly; cast with @as(?T, null)"),
        .undefined => @compileError("C-ABI call cannot pass untyped undefined directly; cast with @as(T, undefined)"),
        .void => @compileError("C-ABI parameter cannot have type void"),
        else => @compileError("C-ABI call does not support type " ++ @typeName(T)),
    }
}

/// Maps `T` to its C-ABI return type across the FFI boundary.
///
/// Non-optional `objc.Protocol` and `BlockRef(...)` cross the C FFI boundary as
/// nullable `?*c.Protocol` / `?*anyopaque` so a `nil` (`0x0`) Objective-C return
/// never triggers LLVM/Zig non-null pointer undefined behavior before `wrapReturn`.
pub fn UnwrapReturnType(comptime T: type, comptime convert_bool: bool) type {
    if (T == void) return void;
    if (convert_bool and T == bool) return c.BOOL;
    if (T == objc.Protocol) return ?*c.Protocol;
    if (isBlockRefType(T)) return ?*anyopaque;
    if (WrapperUnderlying(T)) |U| return U;
    return UnwrapParamType(T, convert_bool);
}

/// Unwraps a Zig argument `arg` to its C-ABI parameter representation.
pub inline fn unwrapArg(
    arg: anytype,
    comptime convert_bool: bool,
) UnwrapParamType(@TypeOf(arg), convert_bool) {
    const T = @TypeOf(arg);
    if (comptime (convert_bool and T == bool)) {
        return cpkg.boolParam(arg);
    }
    if (comptime (WrapperUnderlying(T) != null or isBlockRefType(T))) {
        return arg.value;
    }
    if (comptime @typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (comptime (WrapperUnderlying(Child) != null or isBlockRefType(Child))) {
            return if (arg) |unwrapped| unwrapped.value else null;
        }
    }
    return arg;
}

/// Wraps a raw C-ABI return value `raw_in` back into `Return`.
pub inline fn wrapReturn(
    comptime Return: type,
    raw_in: anytype,
    comptime convert_bool: bool,
) Return {
    if (Return == void) return;
    const raw: UnwrapReturnType(Return, convert_bool) = raw_in;

    if (comptime (convert_bool and Return == bool)) {
        return if (c.BOOL == bool) raw else (raw != 0);
    }
    if (Return == objc.Object) {
        return objc.Object.fromId(raw);
    }
    if (Return == objc.Protocol) {
        return .{ .value = raw orelse @panic("zig-objc: unexpected nil Protocol return; use ?objc.Protocol for nullable returns") };
    }
    if (comptime isBlockRefType(Return)) {
        return .{ .value = raw orelse @panic("zig-objc: unexpected nil BlockRef return; use ?BlockRef(...) for nullable returns") };
    }
    if (comptime WrapperUnderlying(Return) != null) {
        return Return{ .value = raw };
    }
    if (comptime @typeInfo(Return) == .optional) {
        const Child = @typeInfo(Return).optional.child;
        if (Child == objc.Object) {
            return if (raw != null) objc.Object.fromId(raw) else null;
        }
        if (comptime isBlockRefType(Child)) {
            return if (raw) |ptr| Child{ .value = ptr } else null;
        }
        if (comptime WrapperUnderlying(Child)) |U| {
            if (comptime (@typeInfo(U) == .optional or (@typeInfo(U) == .pointer and @typeInfo(U).pointer.size == .c))) {
                return if (raw == null) null else Child{ .value = raw };
            } else {
                return if (raw) |ptr| Child{ .value = ptr } else null;
            }
        }
    }
    return raw;
}

/// Tuple type combining `PrefixTuple` (e.g. `(receiver, SEL)`) and unwrapped `ArgsTuple`
/// for a single-pass `@call(.auto, ...)` without intermediate stack tuple copies.
pub fn CallTuple(
    comptime PrefixTuple: type,
    comptime ArgsTuple: type,
    comptime convert_bool: bool,
) type {
    const prefix_info = expectTupleInfo(PrefixTuple, "CallTuple prefix");
    const args_info = expectTupleInfo(ArgsTuple, "C-ABI call args");

    var types: [prefix_info.field_types.len + args_info.field_types.len]type = undefined;
    for (prefix_info.field_types, 0..) |P, i| {
        types[i] = P;
    }
    for (args_info.field_types, 0..) |A, i| {
        types[prefix_info.field_types.len + i] = UnwrapParamType(A, convert_bool);
    }
    return @Tuple(&types);
}

/// Constructs `(prefix..., unwrapped_args...)` in a single pass.
pub inline fn buildCallArgs(
    prefix: anytype,
    args: anytype,
    comptime convert_bool: bool,
) CallTuple(@TypeOf(prefix), @TypeOf(args), convert_bool) {
    const Result = CallTuple(@TypeOf(prefix), @TypeOf(args), convert_bool);
    const prefix_len = @typeInfo(@TypeOf(prefix)).@"struct".field_types.len;
    const args_len = @typeInfo(@TypeOf(args)).@"struct".field_types.len;
    if (comptime (prefix_len + args_len == 0)) return .{};

    var out: Result = undefined;
    inline for (0..prefix_len) |i| {
        out[i] = prefix[i];
    }
    inline for (0..args_len) |i| {
        out[prefix_len + i] = unwrapArg(args[i], convert_bool);
    }
    return out;
}

/// Tuple type combining `PrefixTuple` (e.g. `(block_ctx,)`) and `param_types` unwrapped
/// according to a known parameter signature (used by `Block.invoke` and `BlockRef.invoke`).
pub fn TypedCallTuple(
    comptime PrefixTuple: type,
    comptime param_types: []const type,
    comptime convert_bool: bool,
) type {
    const prefix_info = expectTupleInfo(PrefixTuple, "TypedCallTuple prefix");

    var types: [prefix_info.field_types.len + param_types.len]type = undefined;
    for (prefix_info.field_types, 0..) |P, i| {
        types[i] = P;
    }
    for (param_types, 0..) |P, i| {
        types[prefix_info.field_types.len + i] = UnwrapParamType(P, convert_bool);
    }
    return @Tuple(&types);
}

/// Coerces each element of `args` to `param_types[i]` and unwraps `(prefix..., args...)`
/// in a single pass.
pub inline fn buildTypedCallArgs(
    prefix: anytype,
    comptime param_types: []const type,
    args: anytype,
    comptime convert_bool: bool,
) TypedCallTuple(@TypeOf(prefix), param_types, convert_bool) {
    const prefix_info = expectTupleInfo(@TypeOf(prefix), "TypedCallTuple prefix");
    const args_info = expectTupleInfo(@TypeOf(args), "C-ABI call args");
    if (args_info.field_types.len != param_types.len) {
        @compileError("C-ABI call argument count mismatch");
    }

    const Result = TypedCallTuple(@TypeOf(prefix), param_types, convert_bool);
    const prefix_len = prefix_info.field_types.len;
    if (comptime (prefix_len + param_types.len == 0)) return .{};

    var out: Result = undefined;
    inline for (0..prefix_len) |i| {
        out[i] = prefix[i];
    }
    inline for (param_types, 0..) |ParamType, i| {
        const typed_arg: ParamType = args[i];
        out[prefix_len + i] = unwrapArg(typed_arg, convert_bool);
    }
    return out;
}

fn isCStringArrayPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .array => |arr| arr.child == u8 and (T == *const [arr.len:0]u8 or T == *[arr.len:0]u8),
            else => false,
        },
        else => false,
    };
}

/// Computes the C default argument promotion type (C99 §6.5.2.2p6) for a variadic
/// argument passed to `objc_msgSend` / `objc_msgSendSuper`.
pub fn PromoteVarargType(comptime T: type) type {
    if (WrapperUnderlying(T)) |U| return U;
    if (isBlockRefType(T)) return *anyopaque;
    if (T == @TypeOf(null)) return ?*anyopaque;
    if (T == bool) return c_int;
    if (T == comptime_int) return c_int;
    if (T == comptime_float) return f64;
    if (T == f16 or T == f32) return f64;
    if (isCStringArrayPtr(T)) return [*:0]const u8;

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits < @typeInfo(c_int).int.bits) return c_int;
            return T;
        },
        .float => return T,
        .@"enum" => |e| {
            if (@typeInfo(e.tag_type).int.bits < @typeInfo(c_int).int.bits) return c_int;
            return T;
        },
        .vector => return T,
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("C variadic call cannot pass Zig slice " ++ @typeName(T) ++ " directly; pass .ptr and .len or a [*:0]const u8 C string");
            }
            return T;
        },
        .@"struct" => |s| {
            if (s.layout == .auto) {
                @compileError("C variadic call requires an extern or packed struct, got auto-layout struct " ++ @typeName(T));
            }
            if (s.layout == .@"packed" and @bitSizeOf(T) > 128) {
                @compileError("C variadic call does not support packed struct larger than 128 bits: " ++ @typeName(T));
            }
            return T;
        },
        .@"union" => |u| {
            if (u.layout == .auto) {
                @compileError("C variadic call requires an extern or packed union, got auto-layout union " ++ @typeName(T));
            }
            if (u.layout == .@"packed" and @bitSizeOf(T) > 128) {
                @compileError("C variadic call does not support packed union larger than 128 bits: " ++ @typeName(T));
            }
            return T;
        },
        .optional => |opt| {
            if (WrapperUnderlying(opt.child)) |U| return NullablePtr(U);
            if (isBlockRefType(opt.child)) return ?*anyopaque;
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice) {
                @compileError("C variadic optional must wrap a non-slice pointer, objc wrapper, or BlockRef, got " ++ @typeName(T));
            }
            return T;
        },
        .undefined => @compileError("C variadic call cannot pass untyped undefined directly; cast with @as(T, undefined)"),
        .void => @compileError("C variadic argument cannot have type void"),
        else => @compileError("C variadic call does not support type " ++ @typeName(T)),
    }
}

/// Applies C default argument promotions and `objc` handle unwrapping to `arg`.
pub inline fn promoteVararg(arg: anytype) PromoteVarargType(@TypeOf(arg)) {
    const T = @TypeOf(arg);
    if (comptime (WrapperUnderlying(T) != null or isBlockRefType(T))) {
        return arg.value;
    }
    if (comptime T == @TypeOf(null)) {
        return null;
    }
    if (comptime T == bool) {
        return @intFromBool(arg);
    }
    if (comptime T == comptime_int) {
        return @as(c_int, arg);
    }
    if (comptime T == comptime_float) {
        return @as(f64, arg);
    }
    if (comptime (T == f16 or T == f32)) {
        return @floatCast(arg);
    }
    if (comptime isCStringArrayPtr(T)) {
        return arg;
    }
    switch (comptime @typeInfo(T)) {
        .int => |info| {
            if (comptime (info.bits < @typeInfo(c_int).int.bits)) {
                return @intCast(arg);
            }
            return arg;
        },
        .@"enum" => |e| {
            if (comptime (@typeInfo(e.tag_type).int.bits < @typeInfo(c_int).int.bits)) {
                return @intCast(@backingInt(arg));
            }
            return arg;
        },
        .optional => |opt| {
            if (comptime (WrapperUnderlying(opt.child) != null or isBlockRefType(opt.child))) {
                return if (arg) |unwrapped| unwrapped.value else null;
            }
            return arg;
        },
        else => return arg,
    }
}

/// Tuple type combining `PrefixTuple` (`(receiver, SEL)`), unwrapped `FixedTuple`,
/// and C-promoted `VarTuple` for variadic Objective-C dispatch.
pub fn VarargCallTuple(
    comptime PrefixTuple: type,
    comptime FixedTuple: type,
    comptime VarTuple: type,
) type {
    const prefix_info = expectTupleInfo(PrefixTuple, "VarargCallTuple prefix");
    const fixed_info = expectTupleInfo(FixedTuple, "C variadic fixed_args");
    const var_info = expectTupleInfo(VarTuple, "C variadic var_args");

    const p_len = prefix_info.field_types.len;
    const f_len = fixed_info.field_types.len;
    const v_len = var_info.field_types.len;

    var types: [p_len + f_len + v_len]type = undefined;
    for (prefix_info.field_types, 0..) |P, i| {
        types[i] = P;
    }
    for (fixed_info.field_types, 0..) |F, i| {
        types[p_len + i] = UnwrapParamType(F, true);
    }
    for (var_info.field_types, 0..) |V, i| {
        types[p_len + f_len + i] = PromoteVarargType(V);
    }
    return @Tuple(&types);
}

/// Constructs `(prefix..., unwrapped_fixed..., promoted_varargs...)` in a single pass.
pub inline fn buildVarargCallArgs(
    prefix: anytype,
    fixed_args: anytype,
    var_args: anytype,
) VarargCallTuple(@TypeOf(prefix), @TypeOf(fixed_args), @TypeOf(var_args)) {
    const Result = VarargCallTuple(@TypeOf(prefix), @TypeOf(fixed_args), @TypeOf(var_args));
    const p_len = @typeInfo(@TypeOf(prefix)).@"struct".field_types.len;
    const f_len = @typeInfo(@TypeOf(fixed_args)).@"struct".field_types.len;
    const v_len = @typeInfo(@TypeOf(var_args)).@"struct".field_types.len;
    if (comptime (p_len + f_len + v_len == 0)) return .{};

    var out: Result = undefined;
    inline for (0..p_len) |i| {
        out[i] = prefix[i];
    }
    inline for (0..f_len) |i| {
        out[p_len + i] = unwrapArg(fixed_args[i], true);
    }
    inline for (0..v_len) |i| {
        out[p_len + f_len + i] = promoteVararg(var_args[i]);
    }
    return out;
}

fn expectTupleInfo(comptime T: type, comptime label: []const u8) std.builtin.Type.Struct {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple)
            s
        else
            @compileError(label ++ " must be a tuple, got struct " ++ @typeName(T)),
        else => @compileError(label ++ " must be a tuple, got " ++ @typeName(T)),
    };
}

comptime {
    // Verify that all non-Protocol wrapper types already use nullable (`?*` or `[*c]`)
    // C pointer representations so `UnwrapReturnType` never exposes a non-null `*T` to FFI.
    for ([_]type{
        objc.Object,
        objc.Class,
        objc.Sel,
        objc.Property,
        objc.Ivar,
        objc.Method,
    }) |W| {
        const U = WrapperUnderlying(W).?;
        std.debug.assert(@typeInfo(U) == .optional or (@typeInfo(U) == .pointer and @typeInfo(U).pointer.size == .c));
    }
    std.debug.assert(@typeInfo(UnwrapReturnType(objc.Protocol, true)) == .optional);
}

test "abi wrapper, ?BlockRef, and non-null FFI return hardening" {
    const testing = std.testing;

    const Ref = objc.BlockRef(.{i32}, i32);
    const MarkedRef = extern struct {
        pub const zig_objc_is_block_ref = true;
        value: *anyopaque,
    };
    const MyBlk = objc.Block(struct {}, .{i32}, i32);

    try testing.expect(isBlockRefType(Ref));
    try testing.expect(isBlockRefType(MarkedRef));
    try testing.expect(!isBlockRefType(MyBlk));
    try testing.expect(!isBlockRefType(MyBlk.Context));
    try testing.expect(isBlockContextStruct(MyBlk.Context));
    try testing.expect(isBlockContextStruct(objc.BlockLayout));

    // Parameter unwrapping: non-optional Protocol & BlockRef stay non-null; optionals become ?*
    try testing.expectEqual(c.BOOL, UnwrapParamType(bool, true));
    try testing.expectEqual(bool, UnwrapParamType(bool, false));
    try testing.expectEqual(c.id, UnwrapParamType(objc.Object, true));
    try testing.expectEqual(c.id, UnwrapParamType(?objc.Object, true));
    try testing.expectEqual(c.Class, UnwrapParamType(objc.Class, true));
    try testing.expectEqual(c.Class, UnwrapParamType(?objc.Class, true));
    try testing.expectEqual(*c.Protocol, UnwrapParamType(objc.Protocol, true));
    try testing.expectEqual(?*c.Protocol, UnwrapParamType(?objc.Protocol, true));
    try testing.expectEqual(c.SEL, UnwrapParamType(objc.Sel, true));
    try testing.expectEqual(*anyopaque, UnwrapParamType(Ref, true));
    try testing.expectEqual(?*anyopaque, UnwrapParamType(?Ref, true));
    try testing.expectEqual(*anyopaque, UnwrapParamType(MarkedRef, true));
    try testing.expectEqual(?*anyopaque, UnwrapParamType(?MarkedRef, true));

    // Return unwrapping: non-optional Protocol & BlockRef MUST be nullable at FFI boundary!
    try testing.expectEqual(void, UnwrapReturnType(void, true));
    try testing.expectEqual(?*c.Protocol, UnwrapReturnType(objc.Protocol, true));
    try testing.expectEqual(?*c.Protocol, UnwrapReturnType(?objc.Protocol, true));
    try testing.expectEqual(?*anyopaque, UnwrapReturnType(Ref, true));
    try testing.expectEqual(?*anyopaque, UnwrapReturnType(?Ref, true));
    try testing.expectEqual(?*anyopaque, UnwrapReturnType(MarkedRef, true));
    try testing.expectEqual(?*anyopaque, UnwrapReturnType(?MarkedRef, true));

    // wrapReturn & unwrapArg round-trips, including ?BlockRef and tagged-pointer Object
    var dummy_byte: u8 = 0x5A;
    const dummy_ptr: *anyopaque = @ptrCast(&dummy_byte);
    const ref_val: Ref = .{ .value = dummy_ptr };
    try testing.expectEqual(dummy_ptr, unwrapArg(ref_val, true));
    try testing.expectEqual(@as(?*anyopaque, dummy_ptr), unwrapArg(@as(?Ref, ref_val), true));
    try testing.expectEqual(@as(?*anyopaque, null), unwrapArg(@as(?Ref, null), true));

    const wrapped_ref = wrapReturn(Ref, @as(?*anyopaque, dummy_ptr), true);
    try testing.expectEqual(dummy_ptr, wrapped_ref.value);
    try testing.expectEqual(@as(?Ref, null), wrapReturn(?Ref, @as(?*anyopaque, null), true));
    try testing.expectEqual(dummy_ptr, wrapReturn(?Ref, @as(?*anyopaque, dummy_ptr), true).?.value);

    const NSObjectProto = objc.getProtocol("NSObject").?;
    try testing.expectEqual(NSObjectProto.value, wrapReturn(objc.Protocol, @as(?*c.Protocol, NSObjectProto.value), true).value);
    try testing.expectEqual(@as(?objc.Protocol, null), wrapReturn(?objc.Protocol, @as(?*c.Protocol, null), true));

    // Tagged/unaligned Objective-C pointer bit-pattern must wrap cleanly without alignment fault
    var tagged_addr: usize = (@as(usize, 1) << (@bitSizeOf(usize) - 1)) | 0x35;
    _ = &tagged_addr;
    const raw_tagged: c.id = blk: {
        @setRuntimeSafety(false);
        break :blk @ptrFromInt(tagged_addr);
    };
    const wrapped_tagged = wrapReturn(objc.Object, raw_tagged, true);
    try testing.expectEqual(tagged_addr, @intFromPtr(wrapped_tagged.value));
    const wrapped_opt_tagged = wrapReturn(?objc.Object, raw_tagged, true);
    try testing.expectEqual(tagged_addr, @intFromPtr(wrapped_opt_tagged.?.value));
    try testing.expectEqual(@as(?objc.Object, null), wrapReturn(?objc.Object, @as(c.id, null), true));

    // Also test a live Foundation NSNumber tagged pointer through wrapReturn
    const NSNumber = objc.getClass("NSNumber").?;
    const NumWithIntFn = *const fn (c.Class, c.SEL, c_int) callconv(.c) c.id;
    const num_fn: NumWithIntFn = @ptrCast(&c.objc_msgSend);
    const raw_num = num_fn(NSNumber.value, objc.Sel.cached("numberWithInt:").value, 42);
    const wrapped_num = wrapReturn(objc.Object, raw_num, true);
    try testing.expectEqual(@as(c_int, 42), wrapped_num.msgSend(c_int, "intValue", .{}));

    wrapReturn(void, {}, true);
    try testing.expect(wrapReturn(bool, cpkg.boolParam(true), true));
    try testing.expect(!wrapReturn(bool, cpkg.boolParam(false), true));
}

test "abi single-pass buildCallArgs and buildTypedCallArgs" {
    const testing = std.testing;

    const Ref = objc.BlockRef(.{i32}, i32);
    var dummy: u8 = 1;
    const ref_val: Ref = .{ .value = @ptrCast(&dummy) };
    const NSObject = objc.getClass("NSObject").?;
    const s = objc.Sel.cached("description");

    const call_tuple = buildCallArgs(
        .{ NSObject.value, s.value },
        .{ true, @as(?Ref, ref_val), @as(?Ref, null), @as(u32, 99) },
        true,
    );
    try testing.expectEqual(NSObject.value, call_tuple[0]);
    try testing.expectEqual(s.value, call_tuple[1]);
    try testing.expectEqual(cpkg.boolParam(true), call_tuple[2]);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&dummy)), call_tuple[3]);
    try testing.expectEqual(@as(?*anyopaque, null), call_tuple[4]);
    try testing.expectEqual(@as(u32, 99), call_tuple[5]);

    const typed_tuple = buildTypedCallArgs(
        .{@as(*anyopaque, @ptrCast(&dummy))},
        &.{ ?objc.Object, i64, bool },
        .{ null, 42, true },
        true,
    );
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&dummy)), typed_tuple[0]);
    try testing.expectEqual(@as(c.id, null), typed_tuple[1]);
    try testing.expectEqual(@as(i64, 42), typed_tuple[2]);
    try testing.expectEqual(cpkg.boolParam(true), typed_tuple[3]);
}

test "abi promoteVararg and buildVarargCallArgs with live Apple Silicon variadic ObjC call" {
    const testing = std.testing;

    const NarrowEnum = enum(u8) { alpha = 7 };
    const WideEnum = enum(i64) { big = -99 };
    const Ref = objc.BlockRef(.{}, void);
    var mut_str = [_:0]u8{ 'o', 'k' };

    try testing.expectEqual(c_int, PromoteVarargType(bool));
    try testing.expectEqual(c_int, PromoteVarargType(u8));
    try testing.expectEqual(c_int, PromoteVarargType(i8));
    try testing.expectEqual(c_int, PromoteVarargType(u16));
    try testing.expectEqual(c_int, PromoteVarargType(i16));
    try testing.expectEqual(u32, PromoteVarargType(u32));
    try testing.expectEqual(i64, PromoteVarargType(i64));
    try testing.expectEqual(c_int, PromoteVarargType(comptime_int));
    try testing.expectEqual(f64, PromoteVarargType(comptime_float));
    try testing.expectEqual(f64, PromoteVarargType(f16));
    try testing.expectEqual(f64, PromoteVarargType(f32));
    try testing.expectEqual(f64, PromoteVarargType(f64));
    try testing.expectEqual(?*anyopaque, PromoteVarargType(@TypeOf(null)));
    try testing.expectEqual([*:0]const u8, PromoteVarargType(@TypeOf("literal")));
    try testing.expectEqual([*:0]const u8, PromoteVarargType(*[2:0]u8));
    try testing.expectEqual(*anyopaque, PromoteVarargType(Ref));
    try testing.expectEqual(?*anyopaque, PromoteVarargType(?Ref));
    try testing.expectEqual(c_int, PromoteVarargType(NarrowEnum));
    try testing.expectEqual(WideEnum, PromoteVarargType(WideEnum));

    try testing.expectEqual(@as(c_int, 1), promoteVararg(true));
    try testing.expectEqual(@as(c_int, 0), promoteVararg(false));
    try testing.expectEqual(@as(c_int, 250), promoteVararg(@as(u8, 250)));
    try testing.expectEqual(@as(c_int, -12), promoteVararg(@as(i8, -12)));
    try testing.expectEqual(@as(c_int, 1234), promoteVararg(1234));
    try testing.expectEqual(@as(f64, 3.5), promoteVararg(@as(f32, 3.5)));
    try testing.expectEqual(@as(f64, 2.25), promoteVararg(2.25));
    try testing.expectEqual(@as(?*anyopaque, null), promoteVararg(null));
    try testing.expectEqual(@as(c_int, 7), promoteVararg(NarrowEnum.alpha));
    try testing.expectEqualStrings("ok", std.mem.span(promoteVararg(&mut_str)));
    try testing.expectEqualStrings("hello", std.mem.span(promoteVararg("hello")));

    // End-to-end variadic Objective-C call (`+[NSString stringWithFormat:]`) exercising
    // stack-passed varargs on aarch64 and register/stack varargs on x86_64.
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClass("NSString").?;
    const fmt = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"%s:%d:%.1f:%@:%d"});
    const arg_obj = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"obj"});

    const VarFn = fn (c.Class, c.SEL, c.id, ...) callconv(.c) c.id;
    const fn_ptr: *const VarFn = @ptrCast(@alignCast(&c.objc_msgSend));
    const call_args = buildVarargCallArgs(
        .{ NSString.value, objc.Sel.cached("stringWithFormat:").value },
        .{fmt},
        .{ "tag", @as(u8, 42), @as(f32, 1.5), arg_obj, true },
    );
    const formatted = wrapReturn(objc.Object, @call(.auto, fn_ptr, call_args), true);
    const utf8 = std.mem.span(formatted.msgSend([*:0]const u8, "UTF8String", .{}));
    try testing.expectEqualStrings("tag:42:1.5:obj:1", utf8);
}
