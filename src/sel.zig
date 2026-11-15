const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;

// Shorthand, equivalent to Sel.registerName
pub inline fn sel(name: [:0]const u8) Sel {
    return Sel.registerName(name);
}

pub const Sel = extern struct {
    value: c.SEL,

    /// Looks up and caches `name` in a lock-free `.acquire`/`.release` atomic static slot
    /// per comptime selector string (`sel_registerName` runs once on first call).
    pub inline fn cached(comptime name: [:0]const u8) Sel {
        const Cache = struct {
            var slot: c.SEL = null;
            noinline fn resolve() Sel {
                @branchHint(.unlikely);
                const resolved = c.sel_registerName(name.ptr);
                @atomicStore(c.SEL, &slot, resolved, .release);
                return .{ .value = resolved };
            }
        };
        if (@atomicLoad(c.SEL, &Cache.slot, .acquire)) |ptr| {
            return .{ .value = ptr };
        }
        return Cache.resolve();
    }

    /// Registers a method with the Objective-C runtime system, maps the
    /// method name to a selector, and returns the selector value.
    pub inline fn registerName(name: [:0]const u8) Sel {
        return Sel{
            .value = c.sel_registerName(name.ptr),
        };
    }

    /// Registers a method name with the Objective-C runtime system.
    pub inline fn getUid(str: [:0]const u8) Sel {
        return Sel{
            .value = c.sel_getUid(str.ptr),
        };
    }

    /// Returns the name of the method specified by a given selector.
    pub inline fn getName(self: Sel) [:0]const u8 {
        return std.mem.span(c.sel_getName(self.value));
    }

    /// Returns true if the selector is valid and mapped in the runtime.
    pub inline fn isMapped(self: Sel) bool {
        return boolResult(c.sel_isMapped(self.value));
    }

    /// Returns true if two selectors are equal.
    pub inline fn isEqual(self: Sel, other: Sel) bool {
        return boolResult(c.sel_isEqual(self.value, other.value));
    }

    pub const eql = isEqual;
};

test "Sel extern layout and cached lookup" {
    const testing = std.testing;

    try testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(Sel).@"struct".layout);
    try testing.expectEqual(@sizeOf(c.SEL), @sizeOf(Sel));
    try testing.expectEqual(@alignOf(c.SEL), @alignOf(Sel));

    const expected_len = sel("length");
    const cached_len_1 = Sel.cached("length");
    const cached_len_2 = Sel.cached("length");
    try testing.expectEqual(expected_len.value, cached_len_1.value);
    try testing.expectEqual(expected_len.value, cached_len_2.value);
    try testing.expect(cached_len_1.eql(expected_len));

    // Distinct comptime strings of identical byte length (6 bytes) must use distinct slots.
    const cached_retain = Sel.cached("retain");
    try testing.expectEqual(sel("retain").value, cached_retain.value);
    try testing.expect(!Sel.cached("length").eql(Sel.cached("retain")));
}

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
