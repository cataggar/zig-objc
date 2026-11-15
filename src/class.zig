const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const block_pkg = @import("block.zig");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolParam = cpkg.boolParam;
const boolResult = cpkg.boolResult;
const ivar = @import("ivar.zig");
const method = @import("method.zig");
const objc = @import("main.zig");
const MsgSend = @import("msg_send.zig").MsgSend;

/// Objective-C runtime `Class` handle (`<objc/runtime.h>`).
pub const Class = extern struct {
    value: c.Class,

    // Implement msgSend
    const msg_send = MsgSend(Class);
    pub const msgSend = msg_send.msgSend;
    pub const msgSendSuper = msg_send.msgSendSuper;

    /// Returns the name of this class, or `""` if `self.value` is `null` (`class_getName`).
    pub fn getName(self: Class) [:0]const u8 {
        return std.mem.span(c.class_getName(self.value));
    }

    /// Returns the superclass of this class, or `null` if this is a root class or `Nil`
    /// (`class_getSuperclass`).
    pub fn getSuperclass(self: Class) ?Class {
        return .{ .value = c.class_getSuperclass(self.value) orelse return null };
    }

    /// Returns true if this class object is a metaclass (`class_isMetaClass`).
    pub fn isMetaClass(self: Class) bool {
        return boolResult(c.class_isMetaClass(self.value));
    }

    /// Returns the size in bytes of instances of this class (`class_getInstanceSize`).
    pub fn getInstanceSize(self: Class) usize {
        return c.class_getInstanceSize(self.value);
    }

    /// Returns the version number of this class definition (`class_getVersion`).
    pub fn getVersion(self: Class) c_int {
        return c.class_getVersion(self.value);
    }

    /// Sets the version number of this class definition (`class_setVersion`).
    pub fn setVersion(self: Class, version: c_int) void {
        c.class_setVersion(self.value, version);
    }

    /// Returns the path of the dynamic library or framework this class originated from,
    /// or `null` if dynamically created or unavailable (`class_getImageName`).
    pub fn getImageName(self: Class) ?[:0]const u8 {
        const raw = c.class_getImageName(self.value);
        if (raw == null) return null;
        const ptr: [*:0]const u8 = @ptrCast(raw);
        return std.mem.span(ptr);
    }

    /// Returns the `Ivar` for a specified instance variable of `self`, or `null` if not found
    /// (`class_getInstanceVariable`).
    pub fn getInstanceVariable(self: Class, name: [:0]const u8) ?ivar.Ivar {
        return .{ .value = c.class_getInstanceVariable(self.value, name.ptr) orelse return null };
    }

    /// Returns the `Ivar` for a specified class variable of `self`, or `null` if not found
    /// (`class_getClassVariable`).
    pub fn getClassVariable(self: Class, name: [:0]const u8) ?ivar.Ivar {
        return .{ .value = c.class_getClassVariable(self.value, name.ptr) orelse return null };
    }

    /// Returns a newly allocated slice of instance variables declared directly by `self`
    /// (`class_copyIvarList`). Superclass ivars are not included.
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyIvarList(self: Class) []ivar.Ivar {
        var count: c_uint = 0;
        const raw = c.class_copyIvarList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]ivar.Ivar = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns the instance `Method` corresponding to `sel_or_name` for `self` (searching
    /// superclasses), or `null` if not found (`class_getInstanceMethod`).
    pub fn getInstanceMethod(self: Class, sel_or_name: anytype) ?method.Method {
        return .{
            .value = c.class_getInstanceMethod(self.value, resolveSel(sel_or_name).value) orelse return null,
        };
    }

    /// Returns the class `Method` corresponding to `sel_or_name` for `self` (searching
    /// superclasses), or `null` if not found (`class_getClassMethod`).
    pub fn getClassMethod(self: Class, sel_or_name: anytype) ?method.Method {
        return .{
            .value = c.class_getClassMethod(self.value, resolveSel(sel_or_name).value) orelse return null,
        };
    }

    /// Returns a newly allocated slice of instance methods implemented directly by `self`
    /// (`class_copyMethodList`). Superclass methods are not included; inspect the metaclass
    /// to obtain class methods.
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyMethodList(self: Class) []method.Method {
        var count: c_uint = 0;
        const raw = c.class_copyMethodList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]method.Method = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns the `IMP` function pointer that would be called if `sel_or_name` were sent
    /// to an instance of `self`, or `null` if `self` is `Nil` (`class_getMethodImplementation`).
    pub fn getMethodImplementation(self: Class, sel_or_name: anytype) c.IMP {
        return c.class_getMethodImplementation(self.value, resolveSel(sel_or_name).value);
    }

    /// Structure-returning variant of `getMethodImplementation` on non-`aarch64` targets
    /// (`class_getMethodImplementation_stret`). Returns `null` on `aarch64`.
    pub fn getMethodImplementationStret(self: Class, sel_or_name: anytype) c.IMP {
        if (builtin.target.cpu.arch != .aarch64 and @hasDecl(c, "class_getMethodImplementation_stret")) {
            return c.class_getMethodImplementation_stret(self.value, resolveSel(sel_or_name).value);
        }
        return null;
    }

    /// Returns true if instances of `self` respond to `sel_or_name` (`class_respondsToSelector`).
    pub fn respondsToSelector(self: Class, sel_or_name: anytype) bool {
        return boolResult(c.class_respondsToSelector(self.value, resolveSel(sel_or_name).value));
    }

    /// Returns true if `self` directly conforms to `protocol` (`class_conformsToProtocol`).
    pub fn conformsToProtocol(self: Class, protocol: objc.Protocol) bool {
        return boolResult(c.class_conformsToProtocol(self.value, protocol.value));
    }

    /// Adds `protocol` to `self` (`class_addProtocol`). Returns `false` if already adopted.
    pub fn addProtocol(self: Class, protocol: objc.Protocol) bool {
        return boolResult(c.class_addProtocol(self.value, protocol.value));
    }

    /// Returns a newly allocated slice of protocols adopted directly by `self`
    /// (`class_copyProtocolList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyProtocolList(self: Class) []objc.Protocol {
        var count: c_uint = 0;
        const raw = c.class_copyProtocolList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]objc.Protocol = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Returns a property with `name` on `self` (or its superclasses), or `null` if not found
    /// (`class_getProperty`).
    pub fn getProperty(self: Class, name: [:0]const u8) ?objc.Property {
        return .{
            .value = c.class_getProperty(self.value, name.ptr) orelse return null,
        };
    }

    /// Returns a newly allocated slice of properties declared directly by `self`
    /// (`class_copyPropertyList`).
    ///
    /// Caller owns the returned slice and must free it with `objc.free`.
    pub fn copyPropertyList(self: Class) []objc.Property {
        var count: c_uint = 0;
        const raw = c.class_copyPropertyList(self.value, &count);
        if (raw == null) return &.{};
        if (count == 0) {
            std.c.free(@ptrCast(raw));
            return &.{};
        }
        const ptr: [*]objc.Property = @ptrCast(raw);
        return ptr[0..count];
    }

    /// Adds a property with `name` and `attributes` to `self` (`class_addProperty`).
    /// Returns `false` if a property with `name` already exists on `self`.
    pub fn addProperty(
        self: Class,
        name: [:0]const u8,
        attributes: []const objc.Property.Attribute,
    ) bool {
        return boolResult(c.class_addProperty(
            self.value,
            name.ptr,
            if (attributes.len == 0) null else attributes.ptr,
            @intCast(attributes.len),
        ));
    }

    /// Replaces (or adds) a property with `name` and `attributes` on `self`
    /// (`class_replaceProperty`).
    pub fn replaceProperty(
        self: Class,
        name: [:0]const u8,
        attributes: []const objc.Property.Attribute,
    ) void {
        c.class_replaceProperty(
            self.value,
            name.ptr,
            if (attributes.len == 0) null else attributes.ptr,
            @intCast(attributes.len),
        );
    }

    /// Returns the strong ivar layout bitmap for `self`, or `null` if none (`class_getIvarLayout`).
    pub fn getIvarLayout(self: Class) ?[*:0]const u8 {
        const raw = c.class_getIvarLayout(self.value);
        if (raw == null) return null;
        return @ptrCast(raw);
    }

    /// Sets the strong ivar layout bitmap for `self` (`class_setIvarLayout`).
    pub fn setIvarLayout(self: Class, layout: ?[*:0]const u8) void {
        c.class_setIvarLayout(self.value, if (layout) |p| p else null);
    }

    /// Returns the weak ivar layout bitmap for `self`, or `null` if none (`class_getWeakIvarLayout`).
    pub fn getWeakIvarLayout(self: Class) ?[*:0]const u8 {
        const raw = c.class_getWeakIvarLayout(self.value);
        if (raw == null) return null;
        return @ptrCast(raw);
    }

    /// Sets the weak ivar layout bitmap for `self` (`class_setWeakIvarLayout`).
    pub fn setWeakIvarLayout(self: Class, layout: ?[*:0]const u8) void {
        c.class_setWeakIvarLayout(self.value, if (layout) |p| p else null);
    }

    /// Creates a `+1` retained instance of `self` with `extra_bytes` of trailing indexed ivar
    /// storage (`class_createInstance`).
    pub fn createInstance(self: Class, extra_bytes: usize) ?objc.Object {
        const raw = c.class_createInstance(self.value, extra_bytes);
        if (raw == null) return null;
        return objc.Object.fromId(raw);
    }

    /// Constructs an instance of `self` in pre-allocated, zeroed memory `bytes`
    /// (`objc_constructInstance`). Note: returns `null` on modern non-fragile ObjC 2.0
    /// classes that disallow placement construction.
    pub fn constructInstance(self: Class, bytes: ?*anyopaque) ?objc.Object {
        const raw = c.objc_constructInstance(self.value, bytes);
        if (raw == null) return null;
        return objc.Object.fromId(raw);
    }

    /// Replaces the implementation of `sel_or_name` on `self` (or adds it with `imp`'s
    /// comptime Objective-C type encoding if not yet implemented directly on `self`),
    /// returning the previous `IMP` or `null` (`class_replaceMethod`).
    ///
    /// `imp` must be a `callconv(.c)` function or function pointer whose first two
    /// parameters are `(c.id` / `c.Class` / `Class, c.SEL)`.
    pub fn replaceMethod(self: Class, sel_or_name: anytype, imp: anytype) c.IMP {
        const Imp = @TypeOf(imp);
        const Fn = switch (@typeInfo(Imp)) {
            .@"fn" => Imp,
            .pointer => |p| if ((p.size == .one or p.size == .c) and @typeInfo(p.child) == .@"fn")
                p.child
            else
                @compileError("Class.replaceMethod expected a function or function pointer, got " ++ @typeName(Imp)),
            else => @compileError("Class.replaceMethod expected a function or function pointer, got " ++ @typeName(Imp)),
        };
        const fn_info = @typeInfo(Fn).@"fn";
        assert(std.meta.eql(fn_info.attrs.@"callconv", std.builtin.CallingConvention.c));
        assert(fn_info.attrs.varargs == false);
        assert(fn_info.param_types.len >= 2);
        assert(fn_info.param_types[0] == c.id or fn_info.param_types[0] == objc.Object or fn_info.param_types[0] == c.Class or fn_info.param_types[0] == Class);
        assert(fn_info.param_types[1] == c.SEL or fn_info.param_types[1] == objc.Sel);
        const types = comptime objc.comptimeEncode(Fn);
        const imp_ptr: c.IMP = if (comptime @typeInfo(Imp) == .@"fn") @ptrCast(&imp) else @ptrCast(imp);
        return self.replaceMethodRaw(sel_or_name, imp_ptr, &types);
    }

    /// Raw variant of `replaceMethod` accepting a pre-erased `c.IMP` (for example from
    /// `impImplementationWithBlock`) and an optional Objective-C type encoding string
    /// (`class_replaceMethod`). Returns the previous `IMP` or `null`.
    pub fn replaceMethodRaw(
        self: Class,
        sel_or_name: anytype,
        imp: c.IMP,
        types: ?[:0]const u8,
    ) c.IMP {
        return c.class_replaceMethod(
            self.value,
            resolveSel(sel_or_name).value,
            imp,
            if (types) |t| t.ptr else null,
        );
    }

    /// Adds a new method `sel_or_name` to `self` with `imp` and its comptime-derived
    /// Objective-C type encoding (`class_addMethod`). Returns `false` if `self` already
    /// directly implements `sel_or_name`.
    ///
    /// `imp` must be a `callconv(.c)` function or function pointer whose first two
    /// parameters are `(c.id` / `c.Class` / `Class, c.SEL)`.
    pub fn addMethod(self: Class, sel_or_name: anytype, imp: anytype) bool {
        const Imp = @TypeOf(imp);
        const Fn = switch (@typeInfo(Imp)) {
            .@"fn" => Imp,
            .pointer => |p| if ((p.size == .one or p.size == .c) and @typeInfo(p.child) == .@"fn")
                p.child
            else
                @compileError("Class.addMethod expected a function or function pointer, got " ++ @typeName(Imp)),
            else => @compileError("Class.addMethod expected a function or function pointer, got " ++ @typeName(Imp)),
        };
        const fn_info = @typeInfo(Fn).@"fn";
        assert(std.meta.eql(fn_info.attrs.@"callconv", std.builtin.CallingConvention.c));
        assert(fn_info.attrs.varargs == false);
        assert(fn_info.param_types.len >= 2);
        assert(fn_info.param_types[0] == c.id or fn_info.param_types[0] == objc.Object or fn_info.param_types[0] == c.Class or fn_info.param_types[0] == Class);
        assert(fn_info.param_types[1] == c.SEL or fn_info.param_types[1] == objc.Sel);
        const types = comptime objc.comptimeEncode(Fn);
        const imp_ptr: c.IMP = if (comptime @typeInfo(Imp) == .@"fn") @ptrCast(&imp) else @ptrCast(imp);
        return self.addMethodRaw(sel_or_name, imp_ptr, &types);
    }

    /// Raw variant of `addMethod` accepting a pre-erased `c.IMP` (for example from
    /// `impImplementationWithBlock`) and an explicit Objective-C type encoding string
    /// (`class_addMethod`).
    pub fn addMethodRaw(
        self: Class,
        sel_or_name: anytype,
        imp: c.IMP,
        types: [:0]const u8,
    ) bool {
        return boolResult(c.class_addMethod(
            self.value,
            resolveSel(sel_or_name).value,
            imp,
            types.ptr,
        ));
    }

    /// Adds a typed instance variable of type `T` named `name` (`class_addIvar`).
    /// Must only be called between `allocateClassPair` and `registerClassPair` on a
    /// non-metaclass. Computes `@sizeOf(T)`, `log2(@alignOf(T))`, and `comptimeEncode(T)`.
    pub fn addIvar(self: Class, comptime T: type, name: [:0]const u8) bool {
        const alignment_log2: u8 = @intCast(std.math.log2_int(usize, @alignOf(T)));
        const types = comptime objc.comptimeEncode(T);
        return self.addIvarRaw(name, @sizeOf(T), alignment_log2, &types);
    }

    /// Raw variant of `addIvar` accepting explicit byte `size`, `alignment_log2`
    /// (minimum alignment is `1 << alignment_log2`), and Objective-C `types` encoding
    /// (`class_addIvar`).
    pub fn addIvarRaw(
        self: Class,
        name: [:0]const u8,
        size: usize,
        alignment_log2: u8,
        types: [:0]const u8,
    ) bool {
        return boolResult(c.class_addIvar(
            self.value,
            name.ptr,
            size,
            alignment_log2,
            types.ptr,
        ));
    }

    comptime {
        assert(@sizeOf(@This()) == @sizeOf(c.Class));
        assert(@alignOf(@This()) == @alignOf(c.Class));
        assert(@typeInfo(c.IMP) == .optional);
    }
};

fn resolveSel(sel_or_name: anytype) objc.Sel {
    return switch (@TypeOf(sel_or_name)) {
        objc.Sel => sel_or_name,
        c.SEL => .{ .value = sel_or_name },
        else => objc.sel(sel_or_name),
    };
}

/// Returns the registered `Class` named `name`, or `null` if not found (`objc_getClass`).
pub fn getClass(name: [:0]const u8) ?Class {
    return .{ .value = c.objc_getClass(name.ptr) orelse return null };
}

/// Returns the metaclass definition of the class named `name`, or `null` if not registered
/// (`objc_getMetaClass`).
pub fn getMetaClass(name: [:0]const u8) ?Class {
    return .{ .value = c.objc_getMetaClass(name.ptr) orelse return null };
}

/// Returns the registered `Class` named `name` without invoking missing-class handlers,
/// or `null` if not registered (`objc_lookUpClass`).
pub fn lookUpClass(name: [:0]const u8) ?Class {
    return .{ .value = c.objc_lookUpClass(name.ptr) orelse return null };
}

/// Returns the registered `Class` named `name`, aborting the process if not found
/// (`objc_getRequiredClass`).
pub fn getRequiredClass(name: [:0]const u8) Class {
    return .{ .value = c.objc_getRequiredClass(name.ptr) };
}

/// Allocates a new class and metaclass pair with zero extra bytes (`objc_allocateClassPair`).
/// Populate ivars/methods/protocols/properties, then finalize with `registerClassPair`.
pub fn allocateClassPair(superclass: ?Class, name: [:0]const u8) ?Class {
    return allocateClassPairExtra(superclass, name, 0);
}

/// Allocates a new class and metaclass pair with `extra_bytes` of indexed ivar space on
/// the class and metaclass objects (`objc_allocateClassPair`).
pub fn allocateClassPairExtra(superclass: ?Class, name: [:0]const u8, extra_bytes: usize) ?Class {
    return .{ .value = c.objc_allocateClassPair(
        if (superclass) |cls| cls.value else null,
        name.ptr,
        extra_bytes,
    ) orelse return null };
}

/// Registers a class pair previously allocated via `allocateClassPair` (`objc_registerClassPair`).
pub fn registerClassPair(class: Class) void {
    c.objc_registerClassPair(class.value);
}

/// Destroys a dynamically allocated class pair (`objc_disposeClassPair`).
/// Must not be called while instances of `class` or any subclass exist.
pub fn disposeClassPair(class: Class) void {
    c.objc_disposeClassPair(class.value);
}

/// Constructs an instance of `cls` in pre-allocated, zeroed memory `bytes`
/// (`objc_constructInstance`).
pub fn constructInstance(cls: Class, bytes: ?*anyopaque) ?objc.Object {
    return cls.constructInstance(bytes);
}

/// Destroys an Objective-C instance without freeing its memory, removing any associated
/// objects (`objc_destructInstance`).
pub fn destructInstance(obj: objc.Object) ?*anyopaque {
    return c.objc_destructInstance(obj.value);
}

/// Fills up to `buffer.len` registered classes into `buffer` (when non-null and non-empty)
/// and returns the total number of classes currently registered in the runtime
/// (`objc_getClassList`). Pass `null` to query the total class count only.
pub fn getClassList(buffer: ?[]Class) c_int {
    if (buffer) |buf| {
        if (buf.len == 0) return c.objc_getClassList(null, 0);
        const raw_buf: [*c]c.Class = @ptrCast(buf.ptr);
        const cap: c_int = @intCast(@min(buf.len, @as(usize, @intCast(std.math.maxInt(c_int)))));
        return c.objc_getClassList(raw_buf, cap);
    }
    return c.objc_getClassList(null, 0);
}

/// Returns a newly allocated slice of all registered classes in the runtime
/// (`objc_copyClassList`).
///
/// Caller owns the returned slice and must free it with `objc.free`.
pub fn copyClassList() []Class {
    var count: c_uint = 0;
    const raw = c.objc_copyClassList(&count);
    if (raw == null) return &.{};
    if (count == 0) {
        std.c.free(@ptrCast(raw));
        return &.{};
    }
    const ptr: [*]Class = @ptrCast(raw);
    return ptr[0..count];
}

/// Sentinel `image` value (`OBJC_DYNAMIC_CLASSES` = `(const void *)-1`) instructing
/// `enumerateClasses` to enumerate dynamically registered classes.
pub const dynamic_classes_image: *const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

/// Filter options for `enumerateClasses` / `enumerateClassesWithBlock` (`objc_enumerateClasses`).
///
/// Note: per `<objc/runtime.h>`, `image = null` searches the caller's own Mach-O image;
/// pass `dynamic_classes_image` (`OBJC_DYNAMIC_CLASSES`) to search dynamically registered
/// classes, or pass a Mach-O header (`image.copyImageHeaders()`) / `dlopen` handle to
/// search a loaded framework or dylib.
pub const EnumerateClassesFilter = struct {
    image: ?*const anyopaque = null,
    name_prefix: ?[:0]const u8 = null,
    conforming_to: ?objc.Protocol = null,
    subclassing: ?Class = null,
};

/// Enumerates Objective-C classes matching `filter` using a raw Clang block pointer or
/// `BlockRef` (`void (^)(Class aClass, BOOL *stop)` via `objc_enumerateClasses`).
pub fn enumerateClassesWithBlock(filter: EnumerateClassesFilter, blk: anytype) void {
    if (!@hasDecl(c, "objc_enumerateClasses")) return;
    const T = @TypeOf(blk);
    const raw_blk: *anyopaque = switch (T) {
        *anyopaque => blk,
        *const anyopaque => @constCast(blk),
        objc.Object => @ptrCast(blk.value orelse @panic("enumerateClassesWithBlock given nil Object")),
        c.id => @ptrCast(blk orelse @panic("enumerateClassesWithBlock given nil id")),
        else => switch (@typeInfo(T)) {
            .@"struct" => if (@hasDecl(T, "is_objc_block") and @hasField(T, "value"))
                blk.value
            else
                @compileError("enumerateClassesWithBlock expected a Block context pointer or BlockRef, got " ++ @typeName(T)),
            .pointer => |ptr| if (ptr.size == .one)
                @ptrCast(@constCast(blk))
            else
                @compileError("enumerateClassesWithBlock expected a single-item Block context pointer, got " ++ @typeName(T)),
            else => @compileError("enumerateClassesWithBlock expected a Block context pointer or BlockRef, got " ++ @typeName(T)),
        },
    };
    c.objc_enumerateClasses(
        filter.image,
        if (filter.name_prefix) |prefix| prefix.ptr else null,
        if (filter.conforming_to) |proto| proto.value else null,
        if (filter.subclassing) |sup| sup.value else null,
        raw_blk,
    );
}

/// Enumerates Objective-C classes matching `filter`, invoking `callback(context, cls, stop)`.
/// Setting `stop.* = true` aborts enumeration immediately (`objc_enumerateClasses`).
pub fn enumerateClasses(
    filter: EnumerateClassesFilter,
    context: anytype,
    comptime callback: fn (@TypeOf(context), Class, *bool) void,
) void {
    if (!@hasDecl(c, "objc_enumerateClasses")) return;
    const ContextType = @TypeOf(context);
    if (@sizeOf(ContextType) == 0) {
        const EnumBlock = block_pkg.Block(struct {}, .{ c.Class, *c.BOOL }, void);
        const global_blk = EnumBlock.initGlobal(&(struct {
            fn invoke(_: *const EnumBlock.Context, raw_cls: c.Class, stop_raw: *c.BOOL) callconv(.c) void {
                var stop: bool = boolResult(stop_raw.*);
                callback(undefined, .{ .value = raw_cls }, &stop);
                if (stop) stop_raw.* = boolParam(true);
            }
        }).invoke);
        enumerateClassesWithBlock(filter, global_blk);
    } else {
        var ctx_copy: ContextType = context;
        const EnumBlock = block_pkg.Block(struct { ctx_ptr: *anyopaque }, .{ c.Class, *c.BOOL }, void);
        var stack_blk = EnumBlock.init(.{ .ctx_ptr = @ptrCast(&ctx_copy) }, &(struct {
            fn invoke(blk_ctx: *const EnumBlock.Context, raw_cls: c.Class, stop_raw: *c.BOOL) callconv(.c) void {
                const typed_ctx: *const ContextType = @ptrCast(@alignCast(blk_ctx.ctx_ptr));
                var stop: bool = boolResult(stop_raw.*);
                callback(typed_ctx.*, .{ .value = raw_cls }, &stop);
                if (stop) stop_raw.* = boolParam(true);
            }
        }).invoke);
        enumerateClassesWithBlock(filter, &stack_blk);
    }
}

test "Class ABI layout matches c.Class" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(c.Class), @sizeOf(Class));
    try testing.expectEqual(@alignOf(c.Class), @alignOf(Class));
}

test "getClass, lookUpClass, getRequiredClass, getMetaClass" {
    const testing = std.testing;
    const NSObject = getClass("NSObject");
    try testing.expect(NSObject != null);
    try testing.expect(getClass("NoWay") == null);

    try testing.expectEqual(NSObject.?.value, lookUpClass("NSObject").?.value);
    try testing.expect(lookUpClass("NoWay") == null);
    try testing.expectEqual(NSObject.?.value, getRequiredClass("NSObject").value);

    const meta = getMetaClass("NSObject") orelse return error.MetaClassNotFound;
    try testing.expect(meta.isMetaClass());
    try testing.expect(!NSObject.?.isMetaClass());
}

test "msgSend" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;

    // Should work with primitives
    const id = NSObject.msgSend(c.id, "alloc", .{});
    try testing.expect(id != null);
    {
        const obj: objc.Object = .{ .value = id };
        obj.msgSend(void, "dealloc", .{});
    }

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, "alloc", .{});
    try testing.expect(obj.value != null);
    obj.msgSend(void, "dealloc", .{});
}

test "getProperty and copyPropertyList including empty property list" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;

    try testing.expect(NSObject.getProperty("className") != null);
    try testing.expect(NSObject.getProperty("nope") == null);

    const list = NSObject.copyPropertyList();
    defer objc.free(list);
    try testing.expect(list.len > 0);

    // Dynamic class with 0 properties must return empty slice `&.{}` and free safely.
    const empty_cls = allocateClassPair(NSObject, "ZigObjcEmptyPropsClass").?;
    registerClassPair(empty_cls);
    defer disposeClassPair(empty_cls);

    const empty_props = empty_cls.copyPropertyList();
    defer objc.free(empty_props);
    try testing.expectEqual(@as(usize, 0), empty_props.len);
}

test "allocateClassPair and replaceMethod preserves type encoding and returns previous IMP" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;
    const my_object = allocateClassPair(NSObject, "ZigObjcReplaceMethodClass").?;
    defer disposeClassPair(my_object);

    const impls = struct {
        fn hashFirst(_: c.id, _: c.SEL) callconv(.c) u64 {
            return 69;
        }
        fn hashSecond(_: c.id, _: c.SEL) callconv(.c) u64 {
            return 420;
        }
    };

    // First replaceMethod on subclass adds override and sets non-null type encoding.
    const prev_first = my_object.replaceMethod("hash", impls.hashFirst);
    try testing.expect(prev_first == null);

    const m_after_first = my_object.getInstanceMethod("hash") orelse return error.MethodNotFound;
    const enc = m_after_first.getTypeEncoding() orelse return error.MissingTypeEncoding;
    try testing.expectEqualStrings("Q@:", enc);

    // Second replaceMethod on the same class replaces IMP and returns hashFirst!
    const prev_second = my_object.replaceMethod(objc.sel("hash"), &impls.hashSecond);
    try testing.expect(prev_second != null);
    try testing.expectEqual(@as(c.IMP, @ptrCast(&impls.hashFirst)), prev_second);

    registerClassPair(my_object);

    const object = my_object.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer object.release();
    try testing.expectEqual(@as(u64, 420), object.msgSend(u64, "hash", .{}));
}

test "addIvar alignment, copyIvarList, and getInstanceVariable" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;
    const my_object = allocateClassPair(NSObject, "ZigObjcTypedIvarsClass").?;
    defer disposeClassPair(my_object);

    try testing.expect(my_object.addIvar(u8, "byte_flag"));
    try testing.expect(my_object.addIvar(*usize, "state_ptr"));
    try testing.expect(my_object.addIvar(u64, "counter"));
    try testing.expect(my_object.addIvar(objc.Object, "my_ivar"));
    try testing.expect(my_object.addIvarRaw("raw_i32", @sizeOf(i32), 2, "i"));
    // Duplicate ivar name fails
    try testing.expect(!my_object.addIvar(u64, "counter"));

    registerClassPair(my_object);

    const ivars = my_object.copyIvarList();
    defer objc.free(ivars);
    try testing.expectEqual(@as(usize, 5), ivars.len);

    const byte_ivar = my_object.getInstanceVariable("byte_flag") orelse return error.IvarNotFound;
    const ptr_ivar = my_object.getInstanceVariable("state_ptr") orelse return error.IvarNotFound;
    const count_ivar = my_object.getInstanceVariable("counter") orelse return error.IvarNotFound;
    const obj_ivar = my_object.getInstanceVariable("my_ivar") orelse return error.IvarNotFound;
    try testing.expect(my_object.getInstanceVariable("missing_ivar") == null);
    try testing.expect(my_object.getClassVariable("missing_cvar") == null);

    try testing.expectEqualStrings("^Q", ptr_ivar.getTypeEncoding().?);
    try testing.expectEqualStrings("Q", count_ivar.getTypeEncoding().?);
    try testing.expectEqualStrings("@", obj_ivar.getTypeEncoding().?);

    // Verify 8-byte alignment (offset == 16 after 8-byte isa + 1-byte u8 + 7 bytes padding, NOT 256!)
    try testing.expectEqual(@as(isize, 8), byte_ivar.getOffset());
    try testing.expectEqual(@as(isize, 16), ptr_ivar.getOffset());
    try testing.expectEqual(@as(isize, 24), count_ivar.getOffset());
    try testing.expectEqual(@as(isize, 32), obj_ivar.getOffset());
    try testing.expect(my_object.getInstanceSize() < 64);

    var state_slot: usize = 12345;
    const inst = my_object.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.release();

    try testing.expect(inst.setTypedIvar(*usize, "state_ptr", &state_slot));
    try testing.expectEqual(@as(usize, 12345), inst.getTypedIvar(*usize, "state_ptr").?.*);

    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const NSString = getClass("NSString").?;
    const my_string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"69---nice"});
    inst.setInstanceVariable("my_ivar", my_string);
    const loaded_str = inst.getInstanceVariable("my_ivar");
    const slice = std.mem.sliceTo(loaded_str.getProperty([*c]const u8, "UTF8String"), 0);
    try testing.expectEqualSlices(u8, "69---nice", slice);
}

test "addMethod, addMethodRaw with impImplementationWithBlock, copyMethodList, getInstanceMethod, getClassMethod, getMethodImplementation" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;

    const MyClass = allocateClassPair(NSObject, "ZigObjcMethodsTestClass").?;

    try testing.expect(MyClass.addMethod("my_addition", struct {
        fn imp(_: objc.c.id, _: objc.c.SEL, a: i32, b: i32) callconv(.c) i32 {
            return a + b;
        }
    }.imp));

    // Block-backed IMP added via addMethodRaw
    const MultBlock = block_pkg.Block(struct { factor: i32 }, .{ c.id, i32 }, i32);
    var stack_blk = MultBlock.init(.{ .factor = 7 }, &(struct {
        fn run(ctx: *const MultBlock.Context, _: c.id, x: i32) callconv(.c) i32 {
            return ctx.factor * x;
        }
    }).run);
    const block_imp = block_pkg.impImplementationWithBlock(&stack_blk);
    defer _ = block_pkg.impRemoveBlock(block_imp);

    try testing.expect(MyClass.addMethodRaw("multiplyBySeven:", block_imp, "i@:i"));

    // Add a class method on the metaclass
    const meta = objc.Object.fromId(MyClass.value).getClass().?;
    try testing.expect(meta.isMetaClass());
    try testing.expect(meta.addMethod("classConstant", struct {
        fn imp(_: Class, _: c.SEL) callconv(.c) i32 {
            return 99;
        }
    }.imp));

    registerClassPair(MyClass);
    defer disposeClassPair(MyClass);

    try testing.expect(MyClass.respondsToSelector("my_addition"));
    try testing.expect(MyClass.respondsToSelector(objc.sel("multiplyBySeven:")));
    try testing.expect(!MyClass.respondsToSelector("definitelyNotImplemented:"));

    const methods = MyClass.copyMethodList();
    defer objc.free(methods);
    try testing.expectEqual(@as(usize, 2), methods.len);

    const inst_m = MyClass.getInstanceMethod("my_addition") orelse return error.MethodNotFound;
    try testing.expectEqualStrings("my_addition", inst_m.getName().getName());

    const cls_m = MyClass.getClassMethod("classConstant") orelse return error.ClassMethodNotFound;
    try testing.expectEqualStrings("classConstant", cls_m.getName().getName());
    try testing.expectEqual(@as(i32, 99), MyClass.msgSend(i32, "classConstant", .{}));

    const imp_ptr = MyClass.getMethodImplementation("multiplyBySeven:");
    try testing.expectEqual(block_imp, imp_ptr);
    if (builtin.target.cpu.arch == .aarch64) {
        try testing.expect(MyClass.getMethodImplementationStret("multiplyBySeven:") == null);
    } else {
        try testing.expect(MyClass.getMethodImplementationStret("multiplyBySeven:") != null);
    }

    const inst = MyClass.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer inst.release();
    try testing.expectEqual(@as(i32, 5), inst.msgSend(i32, "my_addition", .{ @as(i32, 2), @as(i32, 3) }));
    try testing.expectEqual(@as(i32, 42), inst.msgSend(i32, "multiplyBySeven:", .{@as(i32, 6)}));
}

test "conformsToProtocol, addProtocol, and copyProtocolList" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;
    const copying_proto = objc.getProtocol("NSCopying") orelse return error.ProtocolNotFound;
    const coding_proto = objc.getProtocol("NSCoding") orelse return error.ProtocolNotFound;

    const cls = allocateClassPair(NSObject, "ZigObjcProtocolsTestClass").?;
    defer disposeClassPair(cls);

    // Initially adopts 0 protocols directly -> empty slice safe to free
    {
        const empty_protos = cls.copyProtocolList();
        defer objc.free(empty_protos);
        try testing.expectEqual(@as(usize, 0), empty_protos.len);
    }

    try testing.expect(!cls.conformsToProtocol(copying_proto));
    try testing.expect(cls.addProtocol(copying_proto));
    // Adding same protocol twice returns false
    try testing.expect(!cls.addProtocol(copying_proto));

    registerClassPair(cls);

    try testing.expect(cls.conformsToProtocol(copying_proto));
    try testing.expect(!cls.conformsToProtocol(coding_proto));

    const adopted = cls.copyProtocolList();
    defer objc.free(adopted);
    try testing.expectEqual(@as(usize, 1), adopted.len);
    try testing.expect(adopted[0].eql(copying_proto));
}

test "addProperty and replaceProperty" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;

    const cls = allocateClassPair(NSObject, "ZigObjcAddReplacePropClass").?;
    registerClassPair(cls);
    defer disposeClassPair(cls);

    const ro_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "q"),
        objc.Property.attribute("R", ""),
        objc.Property.attribute("N", ""),
    };
    try testing.expect(cls.addProperty("score", &ro_attrs));
    // Adding duplicate property returns false
    try testing.expect(!cls.addProperty("score", &ro_attrs));

    const p1 = cls.getProperty("score") orelse return error.PropertyNotFound;
    try testing.expect(p1.copyAttributeValue("R") != null);
    if (p1.copyAttributeValue("R")) |ro| objc.free(ro);

    // Replace with readwrite + custom setter
    const rw_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "q"),
        objc.Property.attribute("N", ""),
        objc.Property.attribute("S", "updateScore:"),
    };
    cls.replaceProperty("score", &rw_attrs);

    const p2 = cls.getProperty("score") orelse return error.PropertyNotFound;
    try testing.expect(p2.copyAttributeValue("R") == null);
    const setter = p2.copyAttributeValue("S") orelse return error.SetterNotFound;
    defer objc.free(setter);
    try testing.expectEqualStrings("updateScore:", setter);

    const props = cls.copyPropertyList();
    defer objc.free(props);
    try testing.expectEqual(@as(usize, 1), props.len);
    try testing.expectEqualStrings("score", props[0].getName());
}

test "getName, getSuperclass, getVersion/setVersion, getImageName, ivar layouts, createInstance, destructInstance" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;
    const NSString = getClass("NSString").?;
    const NSMutableString = getClass("NSMutableString").?;

    try testing.expectEqualStrings("NSObject", NSObject.getName());
    try testing.expect(NSObject.getSuperclass() == null);
    try testing.expectEqual(NSString.value, NSMutableString.getSuperclass().?.value);

    const img = NSObject.getImageName() orelse return error.ImageNameNotFound;
    try testing.expect(img.len > 0);

    const cls = allocateClassPairExtra(NSObject, "ZigObjcMetaInfoClass", 0).?;
    try testing.expect(cls.addIvar(?objc.Object, "strong_slot"));
    const layout_bytes: [:0]const u8 = "\x01";
    cls.setIvarLayout(layout_bytes.ptr);
    cls.setWeakIvarLayout(null);
    registerClassPair(cls);
    defer disposeClassPair(cls);

    try testing.expectEqualStrings("ZigObjcMetaInfoClass", cls.getName());
    try testing.expectEqual(NSObject.value, cls.getSuperclass().?.value);
    try testing.expectEqual(@as(c_int, 0), cls.getVersion());
    cls.setVersion(7);
    try testing.expectEqual(@as(c_int, 7), cls.getVersion());

    if (cls.getIvarLayout()) |layout| {
        try testing.expectEqual(@as(u8, 0x01), layout[0]);
    }
    try testing.expect(cls.getWeakIvarLayout() == null);

    // createInstance with extra_bytes + getIndexedIvars
    const ExtraPayload = extern struct { magic: u64, tag: u64 };
    const inst = (cls.createInstance(@sizeOf(ExtraPayload)) orelse return error.CreateInstanceFailed)
        .msgSend(objc.Object, "init", .{});
    defer inst.release();

    const extra: *align(1) ExtraPayload = @ptrCast(inst.getIndexedIvars().?);
    try testing.expectEqual(@as(u64, 0), extra.magic);
    extra.* = .{ .magic = 0xCAFE_BABE_DEAD_BEEF, .tag = 42 };
    const extra_read: *align(1) const ExtraPayload = @ptrCast(inst.getIndexedIvars().?);
    try testing.expectEqual(@as(u64, 0xCAFE_BABE_DEAD_BEEF), extra_read.magic);
    try testing.expectEqual(@as(u64, 42), extra_read.tag);

    // Null destructInstance is a safe no-op
    try testing.expect(destructInstance(.{ .value = null }) == null);
}

test "getClassList, copyClassList, and enumerateClasses" {
    const testing = std.testing;
    const NSObject = getClass("NSObject").?;

    const total = getClassList(null);
    try testing.expect(total > 0);

    var small_buf: [8]Class = undefined;
    const total_with_buf = getClassList(&small_buf);
    try testing.expect(total_with_buf >= 8);
    for (small_buf) |cls| {
        try testing.expect(cls.value != null);
        try testing.expect(cls.getName().len > 0);
    }

    var empty_buf: [0]Class = .{};
    try testing.expect(getClassList(&empty_buf) > 0);

    const all_classes = copyClassList();
    defer objc.free(all_classes);
    try testing.expect(all_classes.len > 0);
    var saw_nsobject = false;
    for (all_classes) |cls| {
        if (cls.value == NSObject.value) {
            saw_nsobject = true;
            break;
        }
    }
    try testing.expect(saw_nsobject);

    // Test enumerateClasses on dynamically registered classes with prefix, protocol, subclassing, and early stop.
    if (@hasDecl(c, "objc_enumerateClasses")) {
        const copying_proto = objc.getProtocol("NSCopying") orelse return error.ProtocolNotFound;

        const Base = allocateClassPair(NSObject, "ZigObjcEnumDyn_Base").?;
        registerClassPair(Base);
        defer disposeClassPair(Base);

        const SubA = allocateClassPair(Base, "ZigObjcEnumDyn_SubA").?;
        try testing.expect(SubA.addProtocol(copying_proto));
        registerClassPair(SubA);
        defer disposeClassPair(SubA);

        const SubB = allocateClassPair(Base, "ZigObjcEnumDyn_SubB").?;
        registerClassPair(SubB);
        defer disposeClassPair(SubB);

        const Other = allocateClassPair(NSObject, "ZigObjcEnumOther_Unrelated").?;
        registerClassPair(Other);
        defer disposeClassPair(Other);

        // 1. Filter by dynamic_classes_image + name_prefix
        var prefix_count: usize = 0;
        enumerateClasses(
            .{ .image = dynamic_classes_image, .name_prefix = "ZigObjcEnumDyn_" },
            &prefix_count,
            struct {
                fn visit(count: *usize, cls: Class, _: *bool) void {
                    assert(std.mem.startsWith(u8, cls.getName(), "ZigObjcEnumDyn_"));
                    count.* += 1;
                }
            }.visit,
        );
        try testing.expectEqual(@as(usize, 3), prefix_count);

        // 2. Filter by subclassing (`Base` -> matches `SubA` and `SubB`, or `Base` + subclasses depending on runtime; verify SubA & SubB found and Other excluded)
        const SubCollector = struct {
            saw_sub_a: bool = false,
            saw_sub_b: bool = false,
            saw_other: bool = false,
        };
        var sub_state: SubCollector = .{};
        enumerateClasses(
            .{
                .image = dynamic_classes_image,
                .name_prefix = "ZigObjcEnum",
                .subclassing = Base,
            },
            &sub_state,
            struct {
                fn visit(st: *SubCollector, cls: Class, _: *bool) void {
                    const n = cls.getName();
                    if (std.mem.eql(u8, n, "ZigObjcEnumDyn_SubA")) st.saw_sub_a = true;
                    if (std.mem.eql(u8, n, "ZigObjcEnumDyn_SubB")) st.saw_sub_b = true;
                    if (std.mem.eql(u8, n, "ZigObjcEnumOther_Unrelated")) st.saw_other = true;
                }
            }.visit,
        );
        try testing.expect(sub_state.saw_sub_a);
        try testing.expect(sub_state.saw_sub_b);
        try testing.expect(!sub_state.saw_other);

        // 3. Filter by conforming_to (`NSCopying` -> only `SubA`)
        var proto_matches: usize = 0;
        var matched_cls: ?Class = null;
        const ProtoCtx = struct { count: *usize, matched: *?Class };
        enumerateClasses(
            .{
                .image = dynamic_classes_image,
                .name_prefix = "ZigObjcEnumDyn_",
                .conforming_to = copying_proto,
            },
            ProtoCtx{ .count = &proto_matches, .matched = &matched_cls },
            struct {
                fn visit(ctx: ProtoCtx, cls: Class, _: *bool) void {
                    ctx.count.* += 1;
                    ctx.matched.* = cls;
                }
            }.visit,
        );
        try testing.expectEqual(@as(usize, 1), proto_matches);
        try testing.expectEqual(SubA.value, matched_cls.?.value);

        // 4. Early stop via `stop.* = true` stops after 1 callback
        var stop_visits: usize = 0;
        enumerateClasses(
            .{ .image = dynamic_classes_image, .name_prefix = "ZigObjcEnumDyn_" },
            &stop_visits,
            struct {
                fn visit(visits: *usize, _: Class, stop: *bool) void {
                    visits.* += 1;
                    stop.* = true;
                }
            }.visit,
        );
        try testing.expectEqual(@as(usize, 1), stop_visits);

        // 5. Zero-sized (`void`) context path
        const ZeroState = struct {
            var count: usize = 0;
        };
        ZeroState.count = 0;
        enumerateClasses(
            .{ .image = dynamic_classes_image, .name_prefix = "ZigObjcEnumDyn_Base" },
            {},
            struct {
                fn visit(_: void, _: Class, _: *bool) void {
                    ZeroState.count += 1;
                }
            }.visit,
        );
        try testing.expectEqual(@as(usize, 1), ZeroState.count);
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Class);
}
