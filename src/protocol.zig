const std = @import("std");
const assert = std.debug.assert;
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolParam = cpkg.boolParam;
const boolResult = cpkg.boolResult;
const method = @import("method.zig");
const objc = @import("main.zig");

/// Objective-C runtime `Protocol` handle (`Protocol *`, `<objc/runtime.h>`).
pub const Protocol = extern struct {
    value: *c.Protocol,

    /// Returns true if two `Protocol` handles refer to the same protocol (`protocol_isEqual`).
    pub inline fn eql(self: Protocol, other: Protocol) bool {
        return boolResult(c.protocol_isEqual(self.value, other.value));
    }

    pub const isEqual = eql;

    /// Returns the name of this protocol (`protocol_getName`).
    pub inline fn getName(self: Protocol) [:0]const u8 {
        const raw = c.protocol_getName(self.value);
        if (raw == null) return "";
        const ptr: [*:0]const u8 = @ptrCast(raw);
        return std.mem.span(ptr);
    }

    /// Returns true if `self` conforms to `other` (`protocol_conformsToProtocol`).
    pub inline fn conformsToProtocol(self: Protocol, other: Protocol) bool {
        return boolResult(c.protocol_conformsToProtocol(self.value, other.value));
    }

    /// Looks up a property matching `name`, `is_required`, and `is_instance` in `self`
    /// (`protocol_getProperty`).
    pub fn getProperty(
        self: Protocol,
        name: [:0]const u8,
        is_required: bool,
        is_instance: bool,
    ) ?objc.Property {
        return .{ .value = c.protocol_getProperty(
            self.value,
            name.ptr,
            boolParam(is_required),
            boolParam(is_instance),
        ) orelse return null };
    }

    /// Returns the `objc_method_description` for a method matching `sel`,
    /// `is_required_method`, and `is_instance_method` (`protocol_getMethodDescription`).
    /// Recursively searches adopted protocols. If not found, returns `{ .name = null, .types = null }`.
    pub fn getMethodDescription(
        self: Protocol,
        sel: anytype,
        is_required_method: bool,
        is_instance_method: bool,
    ) method.MethodDescription {
        return c.protocol_getMethodDescription(
            self.value,
            resolveSel(sel).value,
            boolParam(is_required_method),
            boolParam(is_instance_method),
        );
    }

    /// Returns a newly allocated slice of method descriptions declared directly by `self`
    /// matching `is_required_method` and `is_instance_method` (`protocol_copyMethodDescriptionList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyMethodDescriptionList(
        self: Protocol,
        is_required_method: bool,
        is_instance_method: bool,
    ) []method.MethodDescription {
        var count: c_uint = 0;
        const raw = c.protocol_copyMethodDescriptionList(
            self.value,
            boolParam(is_required_method),
            boolParam(is_instance_method),
            &count,
        );
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]method.MethodDescription = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns a newly allocated slice of required instance properties declared by `self`
    /// (`protocol_copyPropertyList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyPropertyList(self: Protocol) []objc.Property {
        var count: c_uint = 0;
        const raw = c.protocol_copyPropertyList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]objc.Property = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns a newly allocated slice of properties declared directly by `self` matching
    /// `is_required_property` and `is_instance_property` (`protocol_copyPropertyList2`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyPropertyList2(
        self: Protocol,
        is_required_property: bool,
        is_instance_property: bool,
    ) []objc.Property {
        var count: c_uint = 0;
        const raw = c.protocol_copyPropertyList2(
            self.value,
            &count,
            boolParam(is_required_property),
            boolParam(is_instance_property),
        );
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]objc.Property = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns a newly allocated slice of protocols adopted directly by `self`
    /// (`protocol_copyProtocolList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyProtocolList(self: Protocol) []Protocol {
        var count: c_uint = 0;
        const raw = c.protocol_copyProtocolList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]Protocol = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Adds a method signature to an under-construction protocol (`protocol_addMethodDescription`).
    /// Must be called between `allocateProtocol` and `registerProtocol`.
    pub fn addMethodDescription(
        self: Protocol,
        sel: anytype,
        types: [:0]const u8,
        is_required_method: bool,
        is_instance_method: bool,
    ) void {
        c.protocol_addMethodDescription(
            self.value,
            resolveSel(sel).value,
            types.ptr,
            boolParam(is_required_method),
            boolParam(is_instance_method),
        );
    }

    /// Convenience wrapper around `addMethodDescription` that computes the Objective-C
    /// method encoding at comptime from `Fn` (`fn (receiver, objc.Sel / c.SEL, ...) callconv(.c) ...`).
    pub fn addMethod(
        self: Protocol,
        sel: anytype,
        comptime Fn: type,
        is_required_method: bool,
        is_instance_method: bool,
    ) void {
        const RealFn = switch (@typeInfo(Fn)) {
            .@"fn" => Fn,
            .pointer => |ptr| if ((ptr.size == .one or ptr.size == .c) and @typeInfo(ptr.child) == .@"fn")
                ptr.child
            else
                @compileError("Protocol.addMethod expected a function or function pointer type, got " ++ @typeName(Fn)),
            else => @compileError("Protocol.addMethod expected a function or function pointer type, got " ++ @typeName(Fn)),
        };
        comptime validateProtocolMethodFn(RealFn);
        const types = comptime objc.comptimeEncode(RealFn);
        self.addMethodDescription(sel, &types, is_required_method, is_instance_method);
    }

    /// Incorporates an already-registered protocol `addition` into an under-construction
    /// protocol `self` (`protocol_addProtocol`).
    pub fn addProtocol(self: Protocol, addition: Protocol) void {
        c.protocol_addProtocol(self.value, addition.value);
    }

    /// Adds a property declaration to an under-construction protocol (`protocol_addProperty`).
    /// Must be called between `allocateProtocol` and `registerProtocol`.
    pub fn addProperty(
        self: Protocol,
        name: [:0]const u8,
        attributes: []const objc.Property.Attribute,
        is_required_property: bool,
        is_instance_property: bool,
    ) void {
        c.protocol_addProperty(
            self.value,
            name.ptr,
            if (attributes.len == 0) null else attributes.ptr,
            @intCast(attributes.len),
            boolParam(is_required_property),
            boolParam(is_instance_property),
        );
    }

    comptime {
        assert(@sizeOf(@This()) == @sizeOf(*c.Protocol));
        assert(@alignOf(@This()) == @alignOf(*c.Protocol));
    }
};

fn validateProtocolMethodFn(comptime Fn: type) void {
    if (@typeInfo(Fn) != .@"fn") {
        @compileError("Protocol method must be a function type, got " ++ @typeName(Fn));
    }
    const fn_info = @typeInfo(Fn).@"fn";
    if (!std.meta.eql(fn_info.attrs.@"callconv", std.builtin.CallingConvention.c)) {
        @compileError("Objective-C protocol method function must use callconv(.c): " ++ @typeName(Fn));
    }
    if (fn_info.attrs.varargs) {
        @compileError("Protocol.addMethod comptime encoding does not support varargs signatures directly; use addMethodDescription");
    }
    if (fn_info.param_types.len < 2) {
        @compileError("Objective-C protocol method function must accept at least (receiver, SEL) parameters");
    }
    const Receiver = fn_info.param_types[0] orelse
        @compileError("Objective-C protocol method receiver parameter (index 0) cannot be generic (`anytype`): " ++ @typeName(Fn));
    const valid_receiver = (Receiver == c.id or
        Receiver == objc.Object or
        Receiver == c.Class or
        Receiver == objc.Class or
        Receiver == ?*anyopaque or
        Receiver == *anyopaque);
    if (!valid_receiver) {
        @compileError("Objective-C protocol method first parameter (receiver) must be objc.Object, c.id, objc.Class, c.Class, ?*anyopaque, or *anyopaque, got " ++ @typeName(Receiver));
    }
    const Selector = fn_info.param_types[1] orelse
        @compileError("Objective-C protocol method selector parameter (index 1) cannot be generic (`anytype`): " ++ @typeName(Fn));
    if (Selector != c.SEL and Selector != objc.Sel) {
        @compileError("Objective-C protocol method second parameter (_cmd) must be objc.Sel or c.SEL, got " ++ @typeName(Selector));
    }
}

inline fn resolveSel(sel_or_name: anytype) objc.Sel {
    return switch (@TypeOf(sel_or_name)) {
        objc.Sel => sel_or_name,
        c.SEL => .{ .value = sel_or_name },
        else => objc.sel(sel_or_name),
    };
}

/// Returns the registered protocol named `name`, or `null` if not found (`objc_getProtocol`).
pub fn getProtocol(name: [:0]const u8) ?Protocol {
    const raw: ?*c.Protocol = c.objc_getProtocol(name.ptr);
    return .{ .value = raw orelse return null };
}

/// Returns a newly allocated slice of all protocols known to the Objective-C runtime
/// (`objc_copyProtocolList`).
///
/// Caller owns the returned slice and must free it with `objc.free`.
pub fn copyProtocolList() []Protocol {
    var count: c_uint = 0;
    const raw = c.objc_copyProtocolList(&count);
    if (raw == null) return &.{};
    if (count == 0) {
        std.c.free(@ptrCast(raw));
        return &.{};
    }
    const ptr: [*]Protocol = @ptrCast(raw);
    return ptr[0..count];
}

/// Allocates a new protocol under construction (`objc_allocateProtocol`).
/// Returns `null` if a protocol named `name` already exists.
/// Populate with `addProtocol`, `addMethodDescription`/`addMethod`, and `addProperty`,
/// then finalize with `registerProtocol`.
pub fn allocateProtocol(name: [:0]const u8) ?Protocol {
    const raw: ?*c.Protocol = c.objc_allocateProtocol(name.ptr);
    return .{ .value = raw orelse return null };
}

/// Registers a newly constructed protocol with the Objective-C runtime (`objc_registerProtocol`).
/// Once registered, the protocol is immutable and ready for use.
pub fn registerProtocol(proto: Protocol) void {
    c.objc_registerProtocol(proto.value);
}

test "Protocol ABI layout matches *c.Protocol" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(*c.Protocol), @sizeOf(Protocol));
    try testing.expectEqual(@alignOf(*c.Protocol), @alignOf(Protocol));
}

test "Protocol inspection on existing Foundation protocols and global copyProtocolList" {
    const testing = std.testing;

    // Ensure Foundation classes/protocols are realized in the runtime.
    _ = objc.getClass("NSObject");
    _ = objc.getClass("NSFileManager");
    _ = objc.getClass("NSString");

    const fs_proto = getProtocol("NSFileManagerDelegate") orelse return error.ProtocolNotFound;
    try testing.expectEqualStrings("NSFileManagerDelegate", fs_proto.getName());

    const obj_proto = getProtocol("NSObject") orelse return error.ProtocolNotFound;
    try testing.expect(fs_proto.conformsToProtocol(obj_proto));
    try testing.expect(obj_proto.eql(getProtocol("NSObject").?));
    try testing.expect(obj_proto.isEqual(getProtocol("NSObject").?));
    try testing.expect(!fs_proto.eql(obj_proto));

    const copying_proto = getProtocol("NSCopying") orelse return error.ProtocolNotFound;
    try testing.expectEqualStrings("NSCopying", copying_proto.getName());
    try testing.expect(!fs_proto.conformsToProtocol(copying_proto));

    // NSCopying requires -copyWithZone:
    const copy_desc = copying_proto.getMethodDescription("copyWithZone:", true, true);
    try testing.expect(copy_desc.name != null);
    try testing.expect(copy_desc.types != null);
    try testing.expectEqualStrings("copyWithZone:", (objc.Sel{ .value = copy_desc.name }).getName());

    // Non-existent method returns { null, null }
    const missing_desc = copying_proto.getMethodDescription("zigObjcDefinitelyMissingSelector:", true, true);
    try testing.expect(missing_desc.name == null);
    try testing.expect(missing_desc.types == null);

    const copying_req_methods = copying_proto.copyMethodDescriptionList(true, true);
    defer objc.free(copying_req_methods);
    try testing.expectEqual(@as(usize, 1), copying_req_methods.len);
    try testing.expectEqualStrings("copyWithZone:", (objc.Sel{ .value = copying_req_methods[0].name }).getName());

    // Empty method list returns safe empty slice
    const copying_opt_methods = copying_proto.copyMethodDescriptionList(false, true);
    defer objc.free(copying_opt_methods);
    try testing.expectEqual(@as(usize, 0), copying_opt_methods.len);

    // NSObject protocol properties & adopted protocols
    const hash_prop = obj_proto.getProperty("hash", true, true) orelse return error.ProtocolPropertyNotFound;
    try testing.expectEqualStrings("hash", hash_prop.getName());

    const obj_props = obj_proto.copyPropertyList();
    defer objc.free(obj_props);
    try testing.expect(obj_props.len > 0);

    const obj_props2 = obj_proto.copyPropertyList2(true, true);
    defer objc.free(obj_props2);
    try testing.expectEqual(obj_props.len, obj_props2.len);

    const fs_adopted = fs_proto.copyProtocolList();
    defer objc.free(fs_adopted);
    try testing.expect(fs_adopted.len > 0);

    // Global copyProtocolList
    const all_protos = copyProtocolList();
    defer objc.free(all_protos);
    try testing.expect(all_protos.len > 0);
    var saw_nsobject = false;
    for (all_protos) |p| {
        if (p.eql(obj_proto)) {
            saw_nsobject = true;
            break;
        }
    }
    try testing.expect(saw_nsobject);
}

test "Dynamic Protocol allocation, population, registration, and introspection" {
    const testing = std.testing;

    const ns_object_proto = getProtocol("NSObject") orelse return error.ProtocolNotFound;

    // Allocating an already-registered protocol returns null.
    try testing.expect(allocateProtocol("NSObject") == null);

    const proto_name = "ZigObjcDynamicTestProtocol_Wave2";
    const proto = allocateProtocol(proto_name) orelse return error.AllocateProtocolFailed;

    proto.addProtocol(ns_object_proto);
    proto.addMethodDescription("rawPingWithCode:", "B@:i", true, true);
    proto.addMethod(
        objc.sel("computeSumA:b:"),
        fn (c.id, c.SEL, i32, i32) callconv(.c) i64,
        true,
        true,
    );
    proto.addMethod(
        "optionalDidFinish:",
        fn (objc.Object, objc.Sel, bool) callconv(.c) void,
        false,
        true,
    );
    proto.addMethod(
        "sharedIdentifier",
        fn (c.Class, c.SEL) callconv(.c) c.id,
        true,
        false,
    );

    const prop_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "Q"),
        objc.Property.attribute("R", ""),
        objc.Property.attribute("N", ""),
    };
    proto.addProperty("itemCount", &prop_attrs, true, true);

    registerProtocol(proto);

    // Duplicate allocation after registration must fail with null.
    try testing.expect(allocateProtocol(proto_name) == null);

    const looked_up = getProtocol(proto_name) orelse return error.RegisteredProtocolNotFound;
    try testing.expect(looked_up.eql(proto));
    try testing.expectEqualStrings(proto_name, looked_up.getName());
    try testing.expect(looked_up.conformsToProtocol(ns_object_proto));

    // Verify adopted protocol list
    const adopted = looked_up.copyProtocolList();
    defer objc.free(adopted);
    try testing.expectEqual(@as(usize, 1), adopted.len);
    try testing.expect(adopted[0].eql(ns_object_proto));

    // Verify required instance methods
    const req_inst = looked_up.copyMethodDescriptionList(true, true);
    defer objc.free(req_inst);
    try testing.expectEqual(@as(usize, 2), req_inst.len);

    const sum_desc = looked_up.getMethodDescription("computeSumA:b:", true, true);
    try testing.expect(sum_desc.name != null);
    try testing.expectEqualStrings("q@:ii", std.mem.span(sum_desc.types));

    const ping_desc = looked_up.getMethodDescription(objc.sel("rawPingWithCode:"), true, true);
    try testing.expect(ping_desc.name != null);
    try testing.expectEqualStrings("B@:i", std.mem.span(ping_desc.types));

    // Verify optional instance method
    const opt_inst = looked_up.copyMethodDescriptionList(false, true);
    defer objc.free(opt_inst);
    try testing.expectEqual(@as(usize, 1), opt_inst.len);
    const opt_desc = looked_up.getMethodDescription("optionalDidFinish:", false, true);
    try testing.expect(opt_desc.name != null);
    try testing.expectEqualStrings("v@:B", std.mem.span(opt_desc.types));

    // Verify required class method
    const req_cls = looked_up.copyMethodDescriptionList(true, false);
    defer objc.free(req_cls);
    try testing.expectEqual(@as(usize, 1), req_cls.len);
    const cls_desc = looked_up.getMethodDescription("sharedIdentifier", true, false);
    try testing.expect(cls_desc.name != null);
    try testing.expectEqualStrings("@#:", std.mem.span(cls_desc.types));

    // Verify empty optional class method list
    const opt_cls = looked_up.copyMethodDescriptionList(false, false);
    defer objc.free(opt_cls);
    try testing.expectEqual(@as(usize, 0), opt_cls.len);

    // Verify required instance property
    const item_prop = looked_up.getProperty("itemCount", true, true) orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("itemCount", item_prop.getName());
    try testing.expectEqualStrings("TQ,R,N", item_prop.getAttributes().?);

    const req_props = looked_up.copyPropertyList();
    defer objc.free(req_props);
    try testing.expectEqual(@as(usize, 1), req_props.len);
    try testing.expectEqualStrings("itemCount", req_props[0].getName());

    const req_props2 = looked_up.copyPropertyList2(true, true);
    defer objc.free(req_props2);
    try testing.expectEqual(@as(usize, 1), req_props2.len);

    const opt_props2 = looked_up.copyPropertyList2(false, true);
    defer objc.free(opt_props2);
    try testing.expectEqual(@as(usize, 0), opt_props2.len);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Protocol);
}
