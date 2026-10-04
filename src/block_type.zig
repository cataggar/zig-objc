const std = @import("std");

pub fn function(comptime Context: type, comptime Args: anytype, comptime Return: type) type {
    var params: [Args.len + 1]type = undefined;
    params[0] = *const Context;
    for (Args, 1..) |Arg, i| params[i] = Arg;
    const attrs: [Args.len + 1]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    return @Fn(&params, &attrs, Return, .{ .@"callconv" = .c });
}

pub fn context(comptime Captures: type, comptime InvokeFn: type, comptime Flags: type, comptime Descriptor: type) type {
    const captures = @typeInfo(Captures).@"struct";
    const count = captures.field_names.len + 5;
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var attrs: [count]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    @memcpy(names[0..5], &[_][]const u8{ "isa", "flags", "reserved", "invoke", "descriptor" });
    @memcpy(types[0..5], &[_]type{ ?*anyopaque, Flags, c_int, *const InvokeFn, *const Descriptor });
    for (captures.field_names, captures.field_types, captures.field_attrs, 5..) |name, T, attr, i| {
        switch (T) {
            comptime_int => @compileError("capture should not be a comptime_int, try using @as"),
            comptime_float => @compileError("capture should not be a comptime_float, try using @as"),
            else => {},
        }
        names[i] = name;
        types[i] = T;
        attrs[i] = .{ .@"align" = attr.@"align" };
    }
    return @Struct(.@"extern", null, &names, &types, &attrs);
}

test "block types preserve invocation ABI and explicitly aligned captures" {
    const Captures = extern struct {
        value: i32,
        aligned: u32 align(32),
    };
    const Flags = packed struct(c_int) { bits: u32 };
    const Descriptor = extern struct { size: c_ulong };
    const Invoke = function(anyopaque, .{c_int}, c_int);
    const Context = context(Captures, Invoke, Flags, Descriptor);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Context, "isa"));
    try std.testing.expectEqual(@sizeOf(?*anyopaque), @offsetOf(Context, "flags"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Context, "aligned") % 32);
    try std.testing.expectEqual(@as(usize, 32), @alignOf(Context));
    try std.testing.expectEqual(@as(type, u32), @FieldType(Context, "aligned"));
    const info = @typeInfo(Invoke).@"fn";
    try std.testing.expectEqual(@as(type, *const anyopaque), info.param_types[0].?);
    try std.testing.expectEqual(@as(type, c_int), info.param_types[1].?);
    try std.testing.expectEqual(std.lang.CallingConvention.c, info.attrs.@"callconv");
}
