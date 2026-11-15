const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;

// Shorthand, equivalent to Sel.registerName
pub inline fn sel(name: [:0]const u8) Sel {
    return Sel.registerName(name);
}

pub const Sel = struct {
    value: c.SEL,

    /// Registers a method with the Objective-C runtime system, maps the
    /// method name to a selector, and returns the selector value.
    pub fn registerName(name: [:0]const u8) Sel {
        return Sel{
            .value = c.sel_registerName(name.ptr),
        };
    }

    /// Registers a method name with the Objective-C runtime system.
    pub fn getUid(str: [:0]const u8) Sel {
        return Sel{
            .value = c.sel_getUid(str.ptr),
        };
    }

    /// Returns the name of the method specified by a given selector.
    pub fn getName(self: Sel) [:0]const u8 {
        return std.mem.span(c.sel_getName(self.value));
    }

    /// Returns true if the selector is valid and mapped in the runtime.
    pub fn isMapped(self: Sel) bool {
        return boolResult(c.sel_isMapped(self.value));
    }

    /// Returns true if two selectors are equal.
    pub fn isEqual(self: Sel, other: Sel) bool {
        return boolResult(c.sel_isEqual(self.value, other.value));
    }

    pub const eql = isEqual;
};

test "Sel runtime operations" {
    const testing = std.testing;

    const s1 = Sel.registerName("zigObjcTestSelector:");
    try testing.expectEqualStrings("zigObjcTestSelector:", s1.getName());
    try testing.expect(s1.isMapped());

    const s2 = Sel.getUid("zigObjcTestSelector:");
    try testing.expectEqualStrings("zigObjcTestSelector:", s2.getName());
    try testing.expect(s2.isMapped());
    try testing.expect(s1.isEqual(s2));
    try testing.expect(s1.eql(s2));

    const s3 = sel("otherZigObjcTestSelector");
    try testing.expect(s3.isMapped());
    try testing.expect(!s1.isEqual(s3));
    try testing.expect(!s1.eql(s3));

    const null_sel: Sel = .{ .value = null };
    try testing.expect(!null_sel.isMapped());
    try testing.expect(!s1.isEqual(null_sel));
    try testing.expect(null_sel.isEqual(null_sel));
}
