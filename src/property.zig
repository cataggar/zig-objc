const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const objc = @import("main.zig");

/// Objective-C property attribute descriptor (`objc_property_attribute_t`).
pub const Attribute = c.objc_property_attribute_t;

const PropertyAttribute = Attribute;

/// Constructs an `Attribute` (`objc_property_attribute_t`) from sentinel-terminated
/// `name` and `value` strings.
pub fn attribute(name: [:0]const u8, value: [:0]const u8) PropertyAttribute {
    return .{
        .name = name.ptr,
        .value = value.ptr,
    };
}

const propertyAttribute = attribute;

/// Opaque Objective-C declared property handle (`objc_property_t`, `<objc/runtime.h>`).
pub const Property = extern struct {
    value: c.objc_property_t,

    /// Objective-C property attribute descriptor (`objc_property_attribute_t`).
    pub const Attribute = PropertyAttribute;

    /// Constructs an `Attribute` (`objc_property_attribute_t`) from sentinel-terminated
    /// `name` and `value` strings.
    pub const attribute = propertyAttribute;

    /// Returns the name of a property (`property_getName`).
    pub fn getName(self: Property) [:0]const u8 {
        return std.mem.span(c.property_getName(self.value));
    }

    /// Returns the raw Objective-C attribute string of a property, or `null` if
    /// unavailable (`property_getAttributes`).
    pub fn getAttributes(self: Property) ?[:0]const u8 {
        const raw = c.property_getAttributes(self.value);
        if (raw == null) return null;
        const ptr: [*:0]const u8 = @ptrCast(raw);
        return std.mem.span(ptr);
    }

    /// Returns a newly allocated string containing the value of property attribute
    /// `attr`, or `null` if the attribute is not present (`property_copyAttributeValue`).
    ///
    /// Caller owns any non-null slice and must free it with `objc.free`.
    pub fn copyAttributeValue(self: Property, attr: [:0]const u8) ?[:0]u8 {
        const raw = c.property_copyAttributeValue(self.value, attr.ptr);
        if (raw == null) return null;
        const ptr: [*:0]u8 = @ptrCast(raw);
        return std.mem.span(ptr);
    }

    /// Returns a newly allocated array of property attributes (`property_copyAttributeList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyAttributeList(self: Property) []PropertyAttribute {
        var count: c_uint = 0;
        const raw = c.property_copyAttributeList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]PropertyAttribute = @ptrCast(raw);
        return ptr[0..count];
    }

    comptime {
        assert(@sizeOf(@This()) == @sizeOf(c.objc_property_t));
        assert(@alignOf(@This()) == @alignOf(c.objc_property_t));
    }
};

test "Property ABI layout matches c.objc_property_t" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(c.objc_property_t), @sizeOf(Property));
    try testing.expectEqual(@alignOf(c.objc_property_t), @alignOf(Property));
}

test "Property getName, getAttributes, copyAttributeValue, and copyAttributeList on NSObject" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    const prop = NSObject.getProperty("description") orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("description", prop.getName());

    const attrs_str = prop.getAttributes() orelse return error.AttributesNotFound;
    try testing.expect(attrs_str.len > 0);
    try testing.expect(std.mem.startsWith(u8, attrs_str, "T@"));

    // "T" (type encoding) attribute should be non-empty; "R" (readonly) should exist with empty value ""
    const type_val = prop.copyAttributeValue("T") orelse return error.TypeAttributeNotFound;
    defer objc.free(type_val);
    try testing.expect(std.mem.startsWith(u8, type_val, "@"));

    const readonly_val = prop.copyAttributeValue("R") orelse return error.ReadonlyAttributeNotFound;
    defer objc.free(readonly_val);
    try testing.expectEqualStrings("", readonly_val);

    // Non-existent attribute returns null
    try testing.expect(prop.copyAttributeValue("S") == null);

    const attr_list = prop.copyAttributeList();
    defer objc.free(attr_list);
    try testing.expect(attr_list.len >= 2);

    var saw_type = false;
    var saw_readonly = false;
    for (attr_list) |attr| {
        const name = std.mem.span(attr.name);
        const val = std.mem.span(attr.value);
        if (std.mem.eql(u8, name, "T")) {
            saw_type = true;
            try testing.expect(std.mem.startsWith(u8, val, "@"));
        } else if (std.mem.eql(u8, name, "R")) {
            saw_readonly = true;
            try testing.expectEqualStrings("", val);
        }
    }
    try testing.expect(saw_type);
    try testing.expect(saw_readonly);
}

test "Property.attribute helper with dynamic class property" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    const cls = objc.allocateClassPair(NSObject, "ZigObjcPropertyTestClass") orelse return error.AllocateClassFailed;
    defer objc.disposeClassPair(cls);

    const attrs = [_]Property.Attribute{
        Property.attribute("T", "Q"),
        Property.attribute("N", ""),
        Property.attribute("G", "customCount"),
        Property.attribute("S", "setCustomCount:"),
        Property.attribute("V", "_count"),
    };
    try testing.expect(cls.addProperty("count", &attrs));
    objc.registerClassPair(cls);

    const prop = cls.getProperty("count") orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("count", prop.getName());
    try testing.expectEqualStrings("TQ,N,GcustomCount,SsetCustomCount:,V_count", prop.getAttributes().?);

    const getter = prop.copyAttributeValue("G") orelse return error.GetterNotFound;
    defer objc.free(getter);
    try testing.expectEqualStrings("customCount", getter);

    const setter = prop.copyAttributeValue("S") orelse return error.SetterNotFound;
    defer objc.free(setter);
    try testing.expectEqualStrings("setCustomCount:", setter);

    const ivar_name = prop.copyAttributeValue("V") orelse return error.BackingIvarNotFound;
    defer objc.free(ivar_name);
    try testing.expectEqualStrings("_count", ivar_name);

    const copied_attrs = prop.copyAttributeList();
    defer objc.free(copied_attrs);
    try testing.expectEqual(@as(usize, 5), copied_attrs.len);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Property);
}
