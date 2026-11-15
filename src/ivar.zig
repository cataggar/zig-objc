const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;

/// Ivar represents an instance variable in an Objective-C class definition.
pub const Ivar = extern struct {
    value: c.Ivar,

    /// Returns the name of an instance variable, or `null` if unavailable.
    pub fn getName(self: Ivar) ?[:0]const u8 {
        const ptr: [*:0]const u8 = c.ivar_getName(self.value) orelse return null;
        return std.mem.span(ptr);
    }

    /// Returns the Objective-C type encoding of an instance variable, or `null` if unavailable.
    pub fn getTypeEncoding(self: Ivar) ?[:0]const u8 {
        const ptr: [*:0]const u8 = c.ivar_getTypeEncoding(self.value) orelse return null;
        return std.mem.span(ptr);
    }

    /// Returns the byte offset of an instance variable from the start of an object instance.
    ///
    /// For Objective-C object instance variables (`id` / `Object`), prefer
    /// `Object.getIvar` and `Object.setIvar` rather than accessing memory at this offset directly.
    pub fn getOffset(self: Ivar) isize {
        return @intCast(c.ivar_getOffset(self.value));
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(c.Ivar));
        std.debug.assert(@alignOf(@This()) == @alignOf(c.Ivar));
    }
};

test "Ivar layout matches c.Ivar" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(c.Ivar), @sizeOf(Ivar));
    try testing.expectEqual(@alignOf(c.Ivar), @alignOf(Ivar));
}

test "Ivar getName, getTypeEncoding, and getOffset" {
    const testing = std.testing;

    const nsobject = c.objc_getClass("NSObject") orelse return error.ClassNotFound;
    const cls = c.objc_allocateClassPair(nsobject, "ZigObjcIvarTestClass", 0) orelse return error.AllocateClassFailed;
    defer c.objc_disposeClassPair(cls);

    try testing.expect(boolResult(c.class_addIvar(
        cls,
        "obj_field",
        @sizeOf(c.id),
        std.math.log2_int(u8, @alignOf(c.id)),
        "@",
    )));
    try testing.expect(boolResult(c.class_addIvar(
        cls,
        "count_field",
        @sizeOf(u64),
        std.math.log2_int(u8, @alignOf(u64)),
        "Q",
    )));
    try testing.expect(boolResult(c.class_addIvar(
        cls,
        "ratio_field",
        @sizeOf(f64),
        std.math.log2_int(u8, @alignOf(f64)),
        "d",
    )));

    c.objc_registerClassPair(cls);

    const obj_ivar: Ivar = .{
        .value = c.class_getInstanceVariable(cls, "obj_field") orelse return error.IvarNotFound,
    };
    const count_ivar: Ivar = .{
        .value = c.class_getInstanceVariable(cls, "count_field") orelse return error.IvarNotFound,
    };
    const ratio_ivar: Ivar = .{
        .value = c.class_getInstanceVariable(cls, "ratio_field") orelse return error.IvarNotFound,
    };

    try testing.expectEqualStrings("obj_field", obj_ivar.getName().?);
    try testing.expectEqualStrings("@", obj_ivar.getTypeEncoding().?);

    try testing.expectEqualStrings("count_field", count_ivar.getName().?);
    try testing.expectEqualStrings("Q", count_ivar.getTypeEncoding().?);

    try testing.expectEqualStrings("ratio_field", ratio_ivar.getName().?);
    try testing.expectEqualStrings("d", ratio_ivar.getTypeEncoding().?);

    try testing.expect(obj_ivar.getOffset() >= @as(isize, @intCast(@sizeOf(c.Class))));
    try testing.expect(count_ivar.getOffset() >= obj_ivar.getOffset() + @as(isize, @intCast(@sizeOf(c.id))));
    try testing.expect(ratio_ivar.getOffset() >= count_ivar.getOffset() + @as(isize, @intCast(@sizeOf(u64))));

    // Null Ivar safety
    const null_ivar: Ivar = .{ .value = null };
    try testing.expect(null_ivar.getName() == null);
    try testing.expect(null_ivar.getTypeEncoding() == null);
    try testing.expectEqual(@as(isize, 0), null_ivar.getOffset());
}
