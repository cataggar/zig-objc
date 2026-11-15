const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

/// C method descriptor (`struct objc_method_description`) containing `name` (`c.SEL`)
/// and `types` (`[*c]u8`).
pub const MethodDescription = c.objc_method_description;

/// Opaque Objective-C runtime `Method` handle (`<objc/runtime.h>` and `<objc/message.h>`).
pub const Method = extern struct {
    value: c.Method,

    /// Returns the selector naming this method (`method_getName`).
    pub fn getName(self: Method) objc.Sel {
        return .{ .value = c.method_getName(self.value) };
    }

    /// Returns the `IMP` function pointer implementing this method (`method_getImplementation`).
    pub fn getImplementation(self: Method) c.IMP {
        return c.method_getImplementation(self.value);
    }

    /// Returns the Objective-C type encoding string describing the method's return
    /// and parameter types, or `null` if unavailable (`method_getTypeEncoding`).
    pub fn getTypeEncoding(self: Method) ?[:0]const u8 {
        const ptr: ?[*:0]const u8 = c.method_getTypeEncoding(self.value);
        return std.mem.span(ptr orelse return null);
    }

    /// Returns the total number of arguments accepted by the method, including the
    /// implicit `self` (`0`) and `_cmd` (`1`) parameters (`method_getNumberOfArguments`).
    pub fn getNumberOfArguments(self: Method) u32 {
        return @intCast(c.method_getNumberOfArguments(self.value));
    }

    /// Returns a newly allocated string describing the method's return type
    /// (`method_copyReturnType`). Caller owns the returned slice and must free it
    /// with `objc.free`.
    pub fn copyReturnType(self: Method) ?[:0]u8 {
        const ptr: ?[*:0]u8 = c.method_copyReturnType(self.value);
        return std.mem.span(ptr orelse return null);
    }

    /// Copies the method's return type encoding into `dst` with `strncpy` semantics
    /// (`method_getReturnType`): NUL-padded when `dst.len` exceeds the encoding length,
    /// and not NUL-terminated when truncated.
    pub fn getReturnType(self: Method, dst: []u8) void {
        if (dst.len == 0) return;
        c.method_getReturnType(self.value, dst.ptr, dst.len);
    }

    /// Returns a newly allocated string describing the parameter type at `index`,
    /// or `null` if `index` is out of bounds (`method_copyArgumentType`).
    /// Indices `0` and `1` are the implicit `self` (`@`) and `_cmd` (`:`) arguments.
    /// Caller owns any non-null slice and must free it with `objc.free`.
    pub fn copyArgumentType(self: Method, index: u32) ?[:0]u8 {
        const ptr: ?[*:0]u8 = c.method_copyArgumentType(self.value, @intCast(index));
        return std.mem.span(ptr orelse return null);
    }

    /// Copies the parameter type encoding at `index` into `dst` with `strncpy` semantics
    /// (`method_getArgumentType`). If `index` is out of bounds, `dst` is NUL-filled.
    pub fn getArgumentType(self: Method, index: u32, dst: []u8) void {
        if (dst.len == 0) return;
        c.method_getArgumentType(self.value, @intCast(index), dst.ptr, dst.len);
    }

    /// Returns a pointer to the runtime `objc_method_description` structure for this
    /// method (`method_getDescription`).
    pub fn getDescription(self: Method) *const MethodDescription {
        return c.method_getDescription(self.value);
    }

    /// Replaces this method's implementation with `imp`, returning the previous `IMP`
    /// (`method_setImplementation`).
    pub fn setImplementation(self: Method, imp: c.IMP) c.IMP {
        return c.method_setImplementation(self.value, imp);
    }

    /// Atomically swaps the implementations of `m1` and `m2`
    /// (`method_exchangeImplementations`).
    pub fn exchangeImplementations(m1: Method, m2: Method) void {
        c.method_exchangeImplementations(m1.value, m2.value);
    }

    /// Directly invokes this `Method` on `target` (`objc.Object`, `objc.Class`, or raw
    /// `c.id`/`c.Class`) with the given `Return` type and `args` tuple.
    ///
    /// Routes through `method_invoke` (or `method_invoke_stret` on `x86_64` for aggregates
    /// larger than 16 bytes). On `x86_64` 80-bit `long double` (`f80`), Apple does not
    /// provide `method_invoke_fpret`, so this invokes `self.getImplementation()` directly
    /// with `(receiver, self.getName().value, ...)` to preserve the x87 `%st(0)` return.
    pub fn invoke(
        self: Method,
        target: anytype,
        comptime Return: type,
        args: anytype,
    ) Return {
        const RealReturn = unwrapType(Return);
        const target_val = unwrapTarget(target);
        const Target = @TypeOf(target_val);
        const unwrapped_args = buildUnwrappedArgs(args);

        if (comptime isX86LongDouble(RealReturn)) {
            if (comptime (@typeInfo(Target) == .optional or (@typeInfo(Target) == .pointer and @typeInfo(Target).pointer.size == .c))) {
                if (target_val == null) return 0;
            }
            const ImpFn = InvokeFn(RealReturn, Target, c.SEL, @TypeOf(args));
            const imp = self.getImplementation() orelse unreachable;
            const imp_ptr: *const ImpFn = @ptrCast(@alignCast(imp));
            const result = @call(.auto, imp_ptr, .{ target_val, self.getName().value } ++ unwrapped_args);
            return wrapReturn(Return, result);
        }

        const Fn = InvokeFn(RealReturn, Target, c.Method, @TypeOf(args));
        const invoke_fn = comptime methodInvokePtr(RealReturn);
        const invoke_ptr: *const Fn = @ptrCast(@alignCast(invoke_fn));
        const result = @call(.auto, invoke_ptr, .{ target_val, self.value } ++ unwrapped_args);
        return wrapReturn(Return, result);
    }

    comptime {
        assert(@sizeOf(@This()) == @sizeOf(c.Method));
        assert(@alignOf(@This()) == @alignOf(c.Method));
    }
};

fn isX86LongDouble(comptime Return: type) bool {
    if (builtin.target.cpu.arch != .x86_64) return false;
    return switch (@typeInfo(Return)) {
        .float => |float| Return == c_longdouble or float.bits == 80,
        else => false,
    };
}

/// Returns `&c.method_invoke` or `&c.method_invoke_stret` for a non-`f80` C-ABI return type.
fn methodInvokePtr(comptime Return: type) *const fn () callconv(.c) void {
    return switch (builtin.target.cpu.arch) {
        .aarch64 => &c.method_invoke,

        .x86_64 => switch (@typeInfo(Return)) {
            inline .int,
            .bool,
            .@"enum",
            .pointer,
            .void,
            .vector,
            => &c.method_invoke,

            .optional => |opt| opt: {
                assert(@typeInfo(opt.child) == .pointer);
                break :opt &c.method_invoke;
            },

            .@"struct", .@"union" => if (@sizeOf(Return) > 16)
                &c.method_invoke_stret
            else
                &c.method_invoke,

            .float => |float| blk: {
                assert(!(Return == c_longdouble or float.bits == 80));
                break :blk &c.method_invoke;
            },

            else => {
                @compileLog(@typeInfo(Return));
                @compileError("unsupported return type for objc Method.invoke on x86_64");
            },
        },

        else => @compileError("unsupported objc architecture"),
    };
}

fn TargetAbiType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => {
            if (!@hasField(T, "value")) {
                @compileError("Method.invoke: target struct " ++ @typeName(T) ++ " must have a 'value' field");
            }
            return TargetAbiType(@TypeOf(@as(T, undefined).value));
        },
        .pointer => |p| {
            if (p.size == .slice or @sizeOf(T) != @sizeOf(c.id)) {
                @compileError("Method.invoke: target " ++ @typeName(T) ++ " is not C-ABI compatible with id");
            }
            return T;
        },
        .optional => |opt| {
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice or @sizeOf(T) != @sizeOf(c.id)) {
                @compileError("Method.invoke: target " ++ @typeName(T) ++ " is not C-ABI compatible with id");
            }
            return T;
        },
        else => @compileError("Method.invoke: invalid target type " ++ @typeName(T)),
    };
}

fn unwrapTarget(target: anytype) TargetAbiType(@TypeOf(target)) {
    const T = @TypeOf(target);
    if (comptime @typeInfo(T) == .@"struct") {
        return unwrapTarget(target.value);
    }
    return target;
}

fn WrapperUnderlying(comptime T: type) ?type {
    return switch (T) {
        objc.Object => c.id,
        objc.Class => c.Class,
        objc.Protocol => *c.Protocol,
        objc.Sel => c.SEL,
        objc.Property => c.objc_property_t,
        Method => c.Method,
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

fn InvokeFn(
    comptime Return: type,
    comptime Target: type,
    comptime SecondParam: type,
    comptime Args: type,
) type {
    if (@typeInfo(Args) != .@"struct" or !@typeInfo(Args).@"struct".is_tuple) {
        @compileError("Method.invoke: args must be a tuple, got " ++ @typeName(Args));
    }
    const args_info = @typeInfo(Args).@"struct";
    assert(@sizeOf(Target) == @sizeOf(c.id));
    assert(SecondParam == c.Method or SecondParam == c.SEL);

    var param_types: [args_info.field_types.len + 2]type = undefined;
    param_types[0] = Target;
    param_types[1] = SecondParam;
    for (args_info.field_types, 0..) |field_type, i| {
        param_types[i + 2] = unwrapType(field_type);
    }

    return @Fn(&param_types, &@splat(.{}), Return, .{ .@"callconv" = .c });
}

fn UnwrappedArgs(comptime Args: type) type {
    if (@typeInfo(Args) != .@"struct" or !@typeInfo(Args).@"struct".is_tuple) {
        @compileError("Method.invoke: args must be a tuple, got " ++ @typeName(Args));
    }
    const field_types = @typeInfo(Args).@"struct".field_types;
    var types: [field_types.len]type = undefined;
    for (field_types, 0..) |field_type, i| types[i] = unwrapType(field_type);
    return @Tuple(&types);
}

fn unwrapType(comptime T: type) type {
    if (T == bool) return c.BOOL;

    if (WrapperUnderlying(T)) |V| return V;

    switch (@typeInfo(T)) {
        .int, .float, .void, .@"enum", .vector => {},
        .pointer => |p| {
            if (p.size == .slice)
                @compileError("Method.invoke: " ++ @typeName(T) ++ " — Zig slices are not C-ABI compatible");
        },
        .optional => |opt| {
            if (WrapperUnderlying(opt.child)) |V| return NullablePtr(V);
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice)
                @compileError("Method.invoke: " ++ @typeName(T) ++ " — optional must wrap a pointer or objc wrapper");
        },
        .@"struct" => |s| {
            if (s.layout != .@"extern" and s.layout != .@"packed")
                @compileError("Method.invoke: " ++ @typeName(T) ++ " — struct must be extern or packed");
        },
        .@"union" => |u| {
            if (u.layout != .@"extern")
                @compileError("Method.invoke: " ++ @typeName(T) ++ " — union must be extern");
        },
        else => @compileError("Method.invoke: " ++ @typeName(T) ++ " — not C-ABI compatible"),
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

test "Method ABI layout and InvokeFn signatures" {
    const testing = std.testing;

    try testing.expectEqual(@sizeOf(c.Method), @sizeOf(Method));
    try testing.expectEqual(@alignOf(c.Method), @alignOf(Method));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Method);

    try testing.expectEqual(
        fn (c.id, c.Method) callconv(.c) u64,
        InvokeFn(u64, c.id, c.Method, @TypeOf(.{})),
    );
    try testing.expectEqual(
        fn (c.Class, c.Method, c_int) callconv(.c) c.id,
        InvokeFn(c.id, c.Class, c.Method, @TypeOf(.{@as(c_int, 0)})),
    );
    try testing.expectEqual(
        fn (c.id, c.Method, c.BOOL, c.id, c.Class, ?*c.Protocol, c.SEL) callconv(.c) c.BOOL,
        InvokeFn(unwrapType(bool), c.id, c.Method, @TypeOf(.{
            true,
            @as(?objc.Object, null),
            @as(?objc.Class, null),
            @as(?objc.Protocol, null),
            @as(?objc.Sel, null),
        })),
    );

    const Small = extern struct { a: u64, b: u64 };
    const Large = extern struct { a: u64, b: u64, d: u64 };
    if (builtin.target.cpu.arch == .x86_64) {
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(f32));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(f64));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(Small));
        try testing.expectEqual(&c.method_invoke_stret, methodInvokePtr(Large));
        try testing.expect(isX86LongDouble(c_longdouble));
        try testing.expect(isX86LongDouble(f80));
        try testing.expect(!isX86LongDouble(f64));
    } else if (builtin.target.cpu.arch == .aarch64) {
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(f32));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(f64));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(c_longdouble));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(Small));
        try testing.expectEqual(&c.method_invoke, methodInvokePtr(Large));
        try testing.expect(!isX86LongDouble(c_longdouble));
    }
}

test "Method inspection on NSString and NSNumber instance and class methods" {
    const testing = std.testing;

    const NSString = objc.getClass("NSString").?;
    const NSNumber = objc.getClass("NSNumber").?;

    // Inspect -[NSString length]
    const length_sel = objc.sel("length");
    const m_length = Method{
        .value = c.class_getInstanceMethod(NSString.value, length_sel.value) orelse return error.MethodNotFound,
    };
    try testing.expect(m_length.getName().isEqual(length_sel));
    try testing.expectEqualStrings("length", m_length.getName().getName());
    try testing.expect(m_length.getImplementation() != null);
    try testing.expectEqual(
        c.class_getMethodImplementation(NSString.value, length_sel.value),
        m_length.getImplementation(),
    );

    const length_enc = m_length.getTypeEncoding() orelse return error.MissingTypeEncoding;
    try testing.expect(length_enc.len >= 3);
    try testing.expectEqual(@as(u8, 'Q'), length_enc[0]);
    try testing.expectEqual(@as(u32, 2), m_length.getNumberOfArguments());

    const length_ret = m_length.copyReturnType() orelse return error.MissingReturnType;
    defer objc.free(length_ret);
    try testing.expectEqualStrings("Q", length_ret);

    var ret_buf: [16]u8 = @splat(0xAA);
    m_length.getReturnType(&ret_buf);
    try testing.expectEqualStrings("Q", std.mem.sliceTo(&ret_buf, 0));
    m_length.getReturnType(&.{});

    const length_arg0 = m_length.copyArgumentType(0) orelse return error.MissingArgType;
    defer objc.free(length_arg0);
    try testing.expectEqualStrings("@", length_arg0);

    const length_arg1 = m_length.copyArgumentType(1) orelse return error.MissingArgType;
    defer objc.free(length_arg1);
    try testing.expectEqualStrings(":", length_arg1);

    try testing.expect(m_length.copyArgumentType(2) == null);

    var arg_buf: [16]u8 = undefined;
    m_length.getArgumentType(0, &arg_buf);
    try testing.expectEqualStrings("@", std.mem.sliceTo(&arg_buf, 0));
    m_length.getArgumentType(1, &arg_buf);
    try testing.expectEqualStrings(":", std.mem.sliceTo(&arg_buf, 0));
    @memset(&arg_buf, 0xFF);
    m_length.getArgumentType(2, &arg_buf);
    try testing.expectEqualStrings("", std.mem.sliceTo(&arg_buf, 0));
    m_length.getArgumentType(0, &.{});

    const desc = m_length.getDescription();
    try testing.expectEqual(length_sel.value, desc.name);
    try testing.expect(desc.types != null);
    try testing.expectEqualStrings(length_enc, std.mem.span(@as([*:0]const u8, @ptrCast(desc.types))));

    // Inspect -[NSString isEqualToString:] (3 arguments: self, _cmd, aString)
    const eq_sel = objc.sel("isEqualToString:");
    const m_eq = Method{
        .value = c.class_getInstanceMethod(NSString.value, eq_sel.value) orelse return error.MethodNotFound,
    };
    try testing.expect(m_eq.getName().isEqual(eq_sel));
    try testing.expectEqual(@as(u32, 3), m_eq.getNumberOfArguments());

    const eq_ret = m_eq.copyReturnType() orelse return error.MissingReturnType;
    defer objc.free(eq_ret);
    try testing.expect(std.mem.eql(u8, eq_ret, "B") or std.mem.eql(u8, eq_ret, "c"));

    const eq_arg0 = m_eq.copyArgumentType(0) orelse return error.MissingArgType;
    defer objc.free(eq_arg0);
    const eq_arg1 = m_eq.copyArgumentType(1) orelse return error.MissingArgType;
    defer objc.free(eq_arg1);
    const eq_arg2 = m_eq.copyArgumentType(2) orelse return error.MissingArgType;
    defer objc.free(eq_arg2);
    try testing.expectEqualStrings("@", eq_arg0);
    try testing.expectEqualStrings(":", eq_arg1);
    try testing.expectEqualStrings("@", eq_arg2);
    try testing.expect(m_eq.copyArgumentType(3) == null);

    m_eq.getArgumentType(2, &arg_buf);
    try testing.expectEqualStrings("@", std.mem.sliceTo(&arg_buf, 0));

    // Inspect +[NSNumber numberWithInt:] and -[NSNumber doubleValue]
    const num_int_sel = objc.sel("numberWithInt:");
    const m_num_int = Method{
        .value = c.class_getClassMethod(NSNumber.value, num_int_sel.value) orelse return error.MethodNotFound,
    };
    try testing.expect(m_num_int.getName().isEqual(num_int_sel));
    try testing.expect(m_num_int.getImplementation() != null);
    try testing.expectEqual(@as(u32, 3), m_num_int.getNumberOfArguments());

    const num_int_ret = m_num_int.copyReturnType() orelse return error.MissingReturnType;
    defer objc.free(num_int_ret);
    try testing.expectEqualStrings("@", num_int_ret);

    const num_int_arg2 = m_num_int.copyArgumentType(2) orelse return error.MissingArgType;
    defer objc.free(num_int_arg2);
    try testing.expectEqualStrings("i", num_int_arg2);

    const m_double_val = Method{
        .value = c.class_getInstanceMethod(NSNumber.value, objc.sel("doubleValue").value) orelse return error.MethodNotFound,
    };
    const dbl_ret = m_double_val.copyReturnType() orelse return error.MissingReturnType;
    defer objc.free(dbl_ret);
    try testing.expectEqualStrings("d", dbl_ret);
    m_double_val.getReturnType(&ret_buf);
    try testing.expectEqualStrings("d", std.mem.sliceTo(&ret_buf, 0));
    try testing.expectEqual(objc.sel("doubleValue").value, m_double_val.getDescription().name);
}

test "Method.invoke with Foundation classes, optionals, wrappers, structs, and long double" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClass("NSString").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSObject = objc.getClass("NSObject").?;

    // Class method invoke on objc.Class: +[NSString stringWithUTF8String:]
    const m_str_utf8 = Method{
        .value = c.class_getClassMethod(NSString.value, objc.sel("stringWithUTF8String:").value) orelse return error.MethodNotFound,
    };
    const s_hello = m_str_utf8.invoke(NSString, objc.Object, .{@as([*:0]const u8, "hello world")});
    const s_same = m_str_utf8.invoke(NSString, objc.Object, .{@as([*:0]const u8, "hello world")});
    const s_other = m_str_utf8.invoke(NSString, objc.Object, .{@as([*:0]const u8, "different")});

    // Instance methods on s_hello's concrete NSString class (NSString is a class cluster
    // whose abstract -[NSString length] primitive throws unless looked up on object_getClass):
    const str_cls = s_hello.getClass().?;
    const m_length = Method{
        .value = c.class_getInstanceMethod(str_cls.value, objc.sel("length").value) orelse return error.MethodNotFound,
    };
    try testing.expectEqual(@as(usize, 11), m_length.invoke(s_hello, usize, .{}));
    try testing.expectEqual(@as(usize, 11), m_length.invoke(s_hello.value, usize, .{}));
    const WrappedString = struct { value: objc.Object };
    try testing.expectEqual(@as(usize, 11), m_length.invoke(WrappedString{ .value = s_hello }, usize, .{}));

    const m_utf8 = Method{
        .value = c.class_getInstanceMethod(str_cls.value, objc.sel("UTF8String").value) orelse return error.MethodNotFound,
    };
    const cstr = m_utf8.invoke(s_hello, [*:0]const u8, .{});
    try testing.expectEqualStrings("hello world", std.mem.span(cstr));

    const m_eq = Method{
        .value = c.class_getInstanceMethod(str_cls.value, objc.sel("isEqualToString:").value) orelse return error.MethodNotFound,
    };
    try testing.expect(m_eq.invoke(s_hello, bool, .{s_same}));
    try testing.expect(!m_eq.invoke(s_hello, bool, .{s_other}));

    // Tagged pointer NSNumber via Method.invoke
    const m_num_double = Method{
        .value = c.class_getClassMethod(NSNumber.value, objc.sel("numberWithDouble:").value) orelse return error.MethodNotFound,
    };
    const num = m_num_double.invoke(NSNumber, objc.Object, .{@as(f64, 2.718281828)});
    const num_cls = num.getClass().?;
    const m_double_val = Method{
        .value = c.class_getInstanceMethod(num_cls.value, objc.sel("doubleValue").value) orelse return error.MethodNotFound,
    };
    try testing.expectApproxEqAbs(@as(f64, 2.718281828), m_double_val.invoke(num, f64, .{}), 1e-9);

    // NSMutableDictionary setObject:forKey: (void) and objectForKey: (?objc.Object null & non-null)
    const dict = NSMutableDictionary.msgSend(objc.Object, "dictionary", .{});
    const dict_cls = dict.getClass().?;
    const m_set_obj = Method{
        .value = c.class_getInstanceMethod(dict_cls.value, objc.sel("setObject:forKey:").value) orelse return error.MethodNotFound,
    };
    const m_obj_for_key = Method{
        .value = c.class_getInstanceMethod(dict_cls.value, objc.sel("objectForKey:").value) orelse return error.MethodNotFound,
    };
    try testing.expect(m_obj_for_key.invoke(dict, ?objc.Object, .{s_other}) == null);
    m_set_obj.invoke(dict, void, .{ s_hello, s_other });
    const found = m_obj_for_key.invoke(dict, ?objc.Object, .{s_other}) orelse return error.ExpectedObject;
    try testing.expect(m_eq.invoke(found, bool, .{s_hello}));

    // Struct <= 16 bytes on real Foundation method: -[NSString rangeOfString:] -> NSRange (16 bytes)
    const NSRange = extern struct { location: usize, length: usize };
    const m_range = Method{
        .value = c.class_getInstanceMethod(str_cls.value, objc.sel("rangeOfString:").value) orelse return error.MethodNotFound,
    };
    const sub_world = m_str_utf8.invoke(NSString, objc.Object, .{@as([*:0]const u8, "world")});
    const range = m_range.invoke(s_hello, NSRange, .{sub_world});
    try testing.expectEqual(NSRange{ .location = 6, .length = 5 }, range);

    // Dynamic class testing structs <= 16 bytes, structs > 16 bytes (stret on x86_64),
    // optional wrappers (?Object, ?Class, ?Protocol, ?Sel), and c_longdouble (f80 on x86_64).
    const SmallPoint = extern struct { x: f64, y: f64 };
    const LargeRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

    const Helper = objc.allocateClassPair(NSObject, "ZigObjcMethodInvokeTest").?;
    defer objc.disposeClassPair(Helper);

    const impls = struct {
        fn makeSmall(_: c.id, _: c.SEL, x: f64, y: f64) callconv(.c) SmallPoint {
            return .{ .x = x, .y = y };
        }
        fn insetRect(_: c.id, _: c.SEL, r: LargeRect, dx: f64, dy: f64) callconv(.c) LargeRect {
            return .{ .x = r.x + dx, .y = r.y + dy, .w = r.w - 2.0 * dx, .h = r.h - 2.0 * dy };
        }
        fn echoClass(_: c.id, _: c.SEL, cls: c.Class) callconv(.c) c.Class {
            return cls;
        }
        fn echoProto(_: c.id, _: c.SEL, proto: ?*c.Protocol) callconv(.c) ?*c.Protocol {
            return proto;
        }
        fn echoSel(_: c.id, _: c.SEL, s: c.SEL) callconv(.c) c.SEL {
            return s;
        }
        fn scaleLongDouble(_: c.id, _: c.SEL, v: c_longdouble) callconv(.c) c_longdouble {
            return v * 3.5;
        }
    };

    try testing.expect(Helper.addMethod("makeSmallX:y:", impls.makeSmall));
    try testing.expect(Helper.addMethod("insetRect:dx:dy:", impls.insetRect));
    try testing.expect(Helper.addMethod("echoClass:", impls.echoClass));
    try testing.expect(Helper.addMethod("echoProto:", impls.echoProto));
    try testing.expect(Helper.addMethod("echoSel:", impls.echoSel));
    try testing.expect(Helper.addMethod("scaleLongDouble:", impls.scaleLongDouble));
    objc.registerClassPair(Helper);

    const inst = Helper.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.msgSend(void, "release", .{});

    const m_small = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("makeSmallX:y:").value).? };
    try testing.expectEqual(
        SmallPoint{ .x = 12.5, .y = -4.25 },
        m_small.invoke(inst, SmallPoint, .{ @as(f64, 12.5), @as(f64, -4.25) }),
    );

    const m_large = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("insetRect:dx:dy:").value).? };
    const input_rect = LargeRect{ .x = 10.0, .y = 20.0, .w = 100.0, .h = 200.0 };
    try testing.expectEqual(
        LargeRect{ .x = 15.0, .y = 28.0, .w = 90.0, .h = 184.0 },
        m_large.invoke(inst, LargeRect, .{ input_rect, @as(f64, 5.0), @as(f64, 8.0) }),
    );

    const m_echo_cls = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("echoClass:").value).? };
    try testing.expect(m_echo_cls.invoke(inst, ?objc.Class, .{@as(?objc.Class, null)}) == null);
    try testing.expectEqual(NSString.value, m_echo_cls.invoke(inst, ?objc.Class, .{@as(?objc.Class, NSString)}).?.value);
    try testing.expectEqual(NSString.value, m_echo_cls.invoke(inst, objc.Class, .{NSString}).value);

    const obj_proto = objc.getProtocol("NSObject").?;
    const m_echo_proto = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("echoProto:").value).? };
    try testing.expect(m_echo_proto.invoke(inst, ?objc.Protocol, .{@as(?objc.Protocol, null)}) == null);
    try testing.expect(m_echo_proto.invoke(inst, ?objc.Protocol, .{@as(?objc.Protocol, obj_proto)}).?.isEqual(obj_proto));
    try testing.expect(m_echo_proto.invoke(inst, objc.Protocol, .{obj_proto}).isEqual(obj_proto));

    const m_echo_sel = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("echoSel:").value).? };
    try testing.expect(m_echo_sel.invoke(inst, ?objc.Sel, .{@as(?objc.Sel, null)}) == null);
    try testing.expect(m_echo_sel.invoke(inst, ?objc.Sel, .{@as(?objc.Sel, objc.sel("init"))}).?.isEqual(objc.sel("init")));
    try testing.expect(m_echo_sel.invoke(inst, objc.Sel, .{objc.sel("init")}).isEqual(objc.sel("init")));

    const m_ld = Method{ .value = c.class_getInstanceMethod(Helper.value, objc.sel("scaleLongDouble:").value).? };
    const ld_res = m_ld.invoke(inst, c_longdouble, .{@as(c_longdouble, 4.0)});
    try testing.expectApproxEqAbs(@as(f64, 14.0), @as(f64, @floatCast(ld_res)), 1e-12);
}

test "Method.setImplementation and Method.exchangeImplementations swizzling" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const cls_raw = c.objc_allocateClassPair(NSObject.value, "ZigObjcMethodSwizzleTest", 0) orelse
        return error.AllocateClassFailed;
    defer c.objc_disposeClassPair(cls_raw);

    const impls = struct {
        fn alpha(_: c.id, _: c.SEL, x: i64) callconv(.c) i64 {
            return x + 10;
        }
        fn beta(_: c.id, _: c.SEL, x: i64) callconv(.c) i64 {
            return x * 2;
        }
        fn replacement(_: c.id, _: c.SEL, x: i64) callconv(.c) i64 {
            return x + 1000;
        }
        fn swizzledAlpha(self_id: c.id, _: c.SEL, x: i64) callconv(.c) i64 {
            // Once exchanged with `alpha:`, sending `swizzledAlpha:` invokes the original `alpha:` IMP.
            const self_obj = objc.Object.fromId(self_id);
            return self_obj.msgSend(i64, "swizzledAlpha:", .{x}) * 10;
        }
    };

    const sel_alpha = objc.sel("alpha:");
    const sel_beta = objc.sel("beta:");
    const sel_swizzled = objc.sel("swizzledAlpha:");

    try testing.expect(cpkg.boolResult(c.class_addMethod(cls_raw, sel_alpha.value, @ptrCast(&impls.alpha), "q@:q")));
    try testing.expect(cpkg.boolResult(c.class_addMethod(cls_raw, sel_beta.value, @ptrCast(&impls.beta), "q@:q")));
    try testing.expect(cpkg.boolResult(c.class_addMethod(cls_raw, sel_swizzled.value, @ptrCast(&impls.swizzledAlpha), "q@:q")));
    c.objc_registerClassPair(cls_raw);

    const SwizzleCls = objc.Class{ .value = cls_raw };
    const inst = SwizzleCls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.msgSend(void, "release", .{});

    const m_alpha = Method{ .value = c.class_getInstanceMethod(cls_raw, sel_alpha.value).? };
    const m_beta = Method{ .value = c.class_getInstanceMethod(cls_raw, sel_beta.value).? };
    const m_swizzled = Method{ .value = c.class_getInstanceMethod(cls_raw, sel_swizzled.value).? };

    // Baseline behavior
    try testing.expectEqual(@as(i64, 15), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 10), inst.msgSend(i64, sel_beta, .{@as(i64, 5)}));

    // setImplementation replaces IMP and returns previous IMP; restore cleanly
    const orig_alpha_imp = m_alpha.getImplementation();
    const prev_imp = m_alpha.setImplementation(@ptrCast(&impls.replacement));
    try testing.expectEqual(orig_alpha_imp, prev_imp);
    try testing.expectEqual(@as(i64, 1005), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 1005), m_alpha.invoke(inst, i64, .{@as(i64, 5)}));

    const replaced_imp = m_alpha.setImplementation(prev_imp);
    try testing.expectEqual(@as(c.IMP, @ptrCast(&impls.replacement)), replaced_imp);
    try testing.expectEqual(@as(i64, 15), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));

    // exchangeImplementations swaps two distinct methods and restores cleanly
    Method.exchangeImplementations(m_alpha, m_beta);
    try testing.expectEqual(@as(i64, 10), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 15), inst.msgSend(i64, sel_beta, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 10), m_alpha.invoke(inst, i64, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 15), m_beta.invoke(inst, i64, .{@as(i64, 5)}));

    m_alpha.exchangeImplementations(m_beta);
    try testing.expectEqual(@as(i64, 15), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));
    try testing.expectEqual(@as(i64, 10), inst.msgSend(i64, sel_beta, .{@as(i64, 5)}));

    // Classic wrapper swizzling chaining into the original implementation
    Method.exchangeImplementations(m_alpha, m_swizzled);
    try testing.expectEqual(@as(i64, 150), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));

    Method.exchangeImplementations(m_alpha, m_swizzled);
    try testing.expectEqual(@as(i64, 15), inst.msgSend(i64, sel_alpha, .{@as(i64, 5)}));
}
