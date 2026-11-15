const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;
const objc = @import("main.zig");
const ivar_pkg = @import("ivar.zig");
const Ivar = ivar_pkg.Ivar;
const MsgSend = @import("msg_send.zig").MsgSend;
const Iterator = @import("iterator.zig").Iterator;
const sync = @import("sync.zig");

const CustomSelectorAttr = union(enum) {
    none,
    stack: [:0]const u8,
    overflow,
};

fn defaultSetterName(comptime n: [:0]const u8) *const [n.len + 4:0]u8 {
    if (n.len == 0) @compileError("property name cannot be empty");
    return comptime ("set" ++ [1]u8{std.ascii.toUpper(n[0])} ++ n[1..n.len] ++ ":");
}

/// Scans an Objective-C `property_getAttributes` string (`attrs`, e.g. `"Ti,GisReady,ScustomSet:,V_ready"`)
/// for a comma-separated attribute starting with `code` (`'G'` or `'S'`), tracking `{...}`, `(...)`,
/// `[...]`, and `"..."` nesting inside compound `T` type encodings (`T{Pair="a"i,"b"i}`, etc.).
/// Copies the selector + NUL into `buf` with zero heap allocation unless a pathological selector
/// exceeds 255 bytes (`.overflow`).
fn findCustomSelectorAttr(attrs: [:0]const u8, code: u8, buf: *[256]u8) CustomSelectorAttr {
    var i: usize = 0;
    while (i < attrs.len) {
        const seg_start = i;
        var brace_depth: usize = 0;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var in_quotes = false;
        while (i < attrs.len) : (i += 1) {
            const ch = attrs[i];
            if (in_quotes) {
                if (ch == '\\' and i + 1 < attrs.len) {
                    i += 1;
                } else if (ch == '"') {
                    in_quotes = false;
                }
            } else {
                switch (ch) {
                    '"' => in_quotes = true,
                    '{' => brace_depth += 1,
                    '}' => brace_depth -|= 1,
                    '(' => paren_depth += 1,
                    ')' => paren_depth -|= 1,
                    '[' => bracket_depth += 1,
                    ']' => bracket_depth -|= 1,
                    ',' => if (brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) break,
                    else => {},
                }
            }
        }
        const segment = attrs[seg_start..i];
        if (i < attrs.len) i += 1;

        if (segment.len > 1 and segment[0] == code) {
            const sel_bytes = segment[1..];
            if (sel_bytes.len >= buf.len) return .overflow;
            @memcpy(buf[0..sel_bytes.len], sel_bytes);
            buf[sel_bytes.len] = 0;
            return .{ .stack = buf[0..sel_bytes.len :0] };
        }
    }
    return .none;
}

/// Memory management policies for Objective-C associated objects (`objc_setAssociatedObject`).
pub const AssociationPolicy = enum(c.objc_AssociationPolicy) {
    assign = @intCast(c.OBJC_ASSOCIATION_ASSIGN),
    retain_nonatomic = @intCast(c.OBJC_ASSOCIATION_RETAIN_NONATOMIC),
    copy_nonatomic = @intCast(c.OBJC_ASSOCIATION_COPY_NONATOMIC),
    retain = @intCast(c.OBJC_ASSOCIATION_RETAIN),
    copy = @intCast(c.OBJC_ASSOCIATION_COPY),
};

const OuterAssociationPolicy = AssociationPolicy;

/// Object is an instance of a class.
pub const Object = extern struct {
    value: c.id,

    pub const AssociationPolicy = OuterAssociationPolicy;

    // Implement msgSend
    const msg_send = MsgSend(Object);
    pub const msgSend = msg_send.msgSend;
    pub const msgSendSuper = msg_send.msgSendSuper;
    pub const msgSendVarargs = msg_send.msgSendVarargs;
    pub const msgSendSuperVarargs = msg_send.msgSendSuperVarargs;
    pub const msgSendTry = msg_send.msgSendTry;
    pub const msgSendSuperTry = msg_send.msgSendSuperTry;
    pub const msgSendVarargsTry = msg_send.msgSendVarargsTry;
    pub const msgSendSuperVarargsTry = msg_send.msgSendSuperVarargsTry;

    /// Convert a raw "id" into an Object. id must fit the size of the
    /// normal C "id" type (i.e. a `usize`).
    pub inline fn fromId(id: anytype) Object {
        if (@sizeOf(@TypeOf(id)) != @sizeOf(c.id)) {
            @compileError("invalid id type");
        }

        // Some pointers in Objective-C are "tagged pointers", which
        // may be used for small objects and literals (NSNumber, NSString).
        // It's an internal implementation detail that replaces heap
        // allocation with direct encoding within the pointer itself.
        // This may result in UNALIGNED POINTERS!
        const ptr: c.id = blk: {
            @setRuntimeSafety(false);
            break :blk @ptrCast(@alignCast(id));
        };

        return .{ .value = ptr };
    }

    /// Returns `true` if `self` is an Objective-C tagged pointer (e.g. small `NSNumber`,
    /// `NSString`, or `NSDate` encoded directly in the pointer bits), or `false` if `nil`
    /// or heap-allocated.
    pub inline fn isTaggedPointer(self: Object) bool {
        if (self.value == null) return false;
        const bits = @intFromPtr(self.value);
        return switch (builtin.target.cpu.arch) {
            .aarch64 => (bits & (@as(usize, 1) << 63)) != 0,
            .x86_64 => (bits & 1) != 0,
            else => (bits & (@alignOf(usize) - 1)) != 0,
        };
    }

    /// Allocates an uninitialized instance of `cls` via the fast `objc_alloc` runtime entry point.
    pub inline fn alloc(cls: objc.Class) ?Object {
        const raw = objc_alloc(cls.value);
        return if (raw == null) null else fromId(raw);
    }

    /// Allocates and initializes an instance of `cls` (`[[cls alloc] init]`) via `objc_alloc_init`.
    pub inline fn allocInit(cls: objc.Class) ?Object {
        const raw = objc_alloc_init(cls.value);
        return if (raw == null) null else fromId(raw);
    }

    /// Returns the class of an object.
    pub inline fn getClass(self: Object) ?objc.Class {
        return objc.Class{
            .value = c.object_getClass(self.value) orelse return null,
        };
    }

    /// Sets the class of an object (`object_setClass`) and returns its previous class.
    pub fn setClass(self: Object, cls: objc.Class) ?objc.Class {
        if (self.value == null) return null;
        std.debug.assert(!self.isTaggedPointer());
        return objc.Class{
            .value = c.object_setClass(self.value, cls.value) orelse return null,
        };
    }

    /// Returns the class name of a given object.
    pub fn getClassName(self: Object) [:0]const u8 {
        return std.mem.span(c.object_getClassName(self.value));
    }

    /// Returns a pointer to any extra bytes allocated with this instance (e.g. via `class_createInstance`).
    pub fn getIndexedIvars(self: Object) ?*anyopaque {
        if (self.value == null) return null;
        std.debug.assert(!self.isTaggedPointer());
        return c.object_getIndexedIvars(self.value);
    }

    /// Sets a property on `self`, honoring custom `S<setter>` property attributes without
    /// heap allocation, latching the first resolved `(Class, SEL)` pair in a lock-free
    /// 1-class fast path, and resolving dynamically on polymorphic receivers.
    /// Safely no-ops when `self` is `nil`.
    pub fn setProperty(self: Object, comptime n: [:0]const u8, v: anytype) void {
        if (comptime n.len == 0) @compileError("property name cannot be empty");
        if (self.value == null) return;
        const cls = self.getClass() orelse return;

        const PropCache = struct {
            var state: u8 = 0; // 0 = empty, 1 = filling, 2 = latched
            var cached_cls: c.Class = null;
            var cached_sel: c.SEL = null;

            noinline fn resolveCold(target_cls: objc.Class) objc.Sel {
                @branchHint(.unlikely);
                var buf: [256]u8 = undefined;
                const setter_sel: objc.Sel = setter: {
                    if (target_cls.getProperty(n)) |prop| {
                        if (prop.getAttributes()) |attrs| {
                            switch (findCustomSelectorAttr(attrs, 'S', &buf)) {
                                .stack => |val| break :setter objc.sel(val),
                                .overflow => {
                                    if (prop.copyAttributeValue("S")) |heap_val| {
                                        defer objc.free(heap_val);
                                        break :setter objc.sel(heap_val);
                                    }
                                },
                                .none => {},
                            }
                        }
                    }
                    break :setter objc.Sel.cached(comptime defaultSetterName(n));
                };
                if (@cmpxchgStrong(u8, &state, 0, 1, .monotonic, .monotonic) == null) {
                    cached_cls = target_cls.value;
                    cached_sel = setter_sel.value;
                    @atomicStore(u8, &state, 2, .release);
                }
                return setter_sel;
            }
        };

        if (@atomicLoad(u8, &PropCache.state, .acquire) == 2 and PropCache.cached_cls == cls.value) {
            self.msgSend(void, objc.Sel{ .value = PropCache.cached_sel }, .{v});
            return;
        }

        self.msgSend(void, PropCache.resolveCold(cls), .{v});
    }

    /// Reads a property on `self`, honoring custom `G<getter>` property attributes without
    /// heap allocation, latching the first resolved `(Class, SEL)` pair in a lock-free
    /// 1-class fast path, and resolving dynamically on polymorphic receivers.
    /// Safely returns Objective-C's zero/null `nil`-messaging result when `self` is `nil`.
    pub fn getProperty(self: Object, comptime T: type, comptime n: [:0]const u8) T {
        if (comptime n.len == 0) @compileError("property name cannot be empty");
        if (self.value == null) {
            return self.msgSend(T, objc.Sel.cached(n), .{});
        }
        const cls = self.getClass() orelse return self.msgSend(T, objc.Sel.cached(n), .{});

        const PropCache = struct {
            var state: u8 = 0; // 0 = empty, 1 = filling, 2 = latched
            var cached_cls: c.Class = null;
            var cached_sel: c.SEL = null;

            noinline fn resolveCold(target_cls: objc.Class) objc.Sel {
                @branchHint(.unlikely);
                var buf: [256]u8 = undefined;
                const getter_sel: objc.Sel = getter: {
                    if (target_cls.getProperty(n)) |prop| {
                        if (prop.getAttributes()) |attrs| {
                            switch (findCustomSelectorAttr(attrs, 'G', &buf)) {
                                .stack => |val| break :getter objc.sel(val),
                                .overflow => {
                                    if (prop.copyAttributeValue("G")) |heap_val| {
                                        defer objc.free(heap_val);
                                        break :getter objc.sel(heap_val);
                                    }
                                },
                                .none => {},
                            }
                        }
                    }
                    break :getter objc.Sel.cached(n);
                };
                if (@cmpxchgStrong(u8, &state, 0, 1, .monotonic, .monotonic) == null) {
                    cached_cls = target_cls.value;
                    cached_sel = getter_sel.value;
                    @atomicStore(u8, &state, 2, .release);
                }
                return getter_sel;
            }
        };

        if (@atomicLoad(u8, &PropCache.state, .acquire) == 2 and PropCache.cached_cls == cls.value) {
            return self.msgSend(T, objc.Sel{ .value = PropCache.cached_sel }, .{});
        }

        return self.msgSend(T, PropCache.resolveCold(cls), .{});
    }

    pub fn copy(self: Object, size: usize) Object {
        return fromId(c.object_copy(self.value, size));
    }

    pub fn dispose(self: Object) void {
        _ = c.object_dispose(self.value);
    }

    pub fn isClass(self: Object) bool {
        return boolResult(c.object_isClass(self.value));
    }

    /// Reads an Objective-C object instance variable (`object_getIvar`).
    /// Returns `null` if the ivar is `nil` or `self` is `nil`.
    pub fn getIvar(self: Object, ivar: Ivar) ?Object {
        const raw = c.object_getIvar(self.value, ivar.value);
        return if (raw == null) null else fromId(raw);
    }

    /// Sets an Objective-C object instance variable (`object_setIvar`).
    /// Unknown memory management defaults to `unsafe_unretained`.
    pub fn setIvar(self: Object, ivar: Ivar, value: ?Object) void {
        c.object_setIvar(self.value, ivar.value, if (value) |v| v.value else null);
    }

    /// Sets an Objective-C object instance variable (`object_setIvarWithStrongDefault`).
    /// Unknown memory management defaults to `strong`.
    pub fn setIvarWithStrongDefault(self: Object, ivar: Ivar, value: ?Object) void {
        c.object_setIvarWithStrongDefault(self.value, ivar.value, if (value) |v| v.value else null);
    }

    pub fn getInstanceVariable(self: Object, name: [:0]const u8) Object {
        const ivar = c.object_getInstanceVariable(self.value, name.ptr, null) orelse return .{ .value = null };
        return fromId(c.object_getIvar(self.value, ivar));
    }

    pub fn setInstanceVariable(self: Object, name: [:0]const u8, val: ?Object) void {
        if (@hasDecl(c, "object_setInstanceVariable")) {
            _ = c.object_setInstanceVariable(
                self.value,
                name.ptr,
                if (val) |v| @ptrCast(v.value) else null,
            );
        } else {
            const ivar = c.object_getInstanceVariable(self.value, name.ptr, null) orelse return;
            c.object_setIvar(self.value, ivar, if (val) |v| v.value else null);
        }
    }

    /// Sets an Objective-C object instance variable by name, defaulting unknown memory management to `strong`.
    pub fn setInstanceVariableWithStrongDefault(self: Object, name: [:0]const u8, value: ?Object) void {
        if (@hasDecl(c, "object_setInstanceVariableWithStrongDefault")) {
            _ = c.object_setInstanceVariableWithStrongDefault(
                self.value,
                name.ptr,
                if (value) |v| @ptrCast(v.value) else null,
            );
        } else {
            const cls = c.object_getClass(self.value) orelse return;
            const ivar = c.class_getInstanceVariable(cls, name.ptr) orelse return;
            c.object_setIvarWithStrongDefault(self.value, ivar, if (value) |v| v.value else null);
        }
    }

    /// Returns a direct unaligned (`*align(1) T`) pointer to a non-object instance variable
    /// (`*MyZigState`, `usize`, `f64`, `extern struct`, etc.) computed from `ivar.getOffset()`.
    /// Prefer `getIvarPtrAligned` or `IvarSlot(T)` when the ivar has natural `@alignOf(T)` alignment.
    ///
    /// Objective-C object ivars (`Object` / `?Object` / `c.id`) must use `getIvar` / `setIvar` instead.
    pub inline fn getIvarPtr(self: Object, comptime T: type, ivar: Ivar) *align(1) T {
        comptime ivar_pkg.validateDirectIvarType(T);
        std.debug.assert(self.value != null);
        std.debug.assert(!self.isTaggedPointer());
        std.debug.assert(ivar.value != null);
        const offset = ivar.getOffset();
        std.debug.assert(offset >= 0);
        const addr = @intFromPtr(self.value) +% @as(usize, @bitCast(offset));
        return @ptrFromInt(addr);
    }

    /// Returns a naturally aligned `*T` pointer to a non-object instance variable at byte `offset`
    /// from `self`, asserting non-null, non-tagged `self` and natural alignment of `T` in safe modes.
    pub inline fn getIvarPtrAtOffset(self: Object, comptime T: type, offset: isize) *T {
        comptime ivar_pkg.validateDirectIvarType(T);
        std.debug.assert(self.value != null);
        std.debug.assert(!self.isTaggedPointer());
        std.debug.assert(offset >= 0);
        const addr = @intFromPtr(self.value) +% @as(usize, @bitCast(offset));
        if (comptime @alignOf(T) > 1) {
            std.debug.assert((addr & (@alignOf(T) - 1)) == 0);
        }
        return @ptrFromInt(addr);
    }

    /// Returns a naturally aligned `*T` pointer to a non-object instance variable `ivar`,
    /// asserting non-null, non-tagged `self` and natural alignment of `T` in safe modes.
    pub inline fn getIvarPtrAligned(self: Object, comptime T: type, ivar: Ivar) *T {
        comptime ivar_pkg.validateDirectIvarType(T);
        std.debug.assert(ivar.value != null);
        return self.getIvarPtrAtOffset(T, ivar.getOffset());
    }

    /// Reads an instance variable of type `T`, routing `Object`/`?Object`/`c.id` through `object_getIvar`
    /// and non-object Zig types through `getIvarPtr`.
    pub fn getIvarValue(self: Object, comptime T: type, ivar: Ivar) T {
        if (T == ?Object) return self.getIvar(ivar);
        if (T == Object) return self.getIvar(ivar) orelse .{ .value = null };
        if (T == c.id) return c.object_getIvar(self.value, ivar.value);
        return self.getIvarPtr(T, ivar).*;
    }

    /// Writes an instance variable of type `T`, routing `Object`/`?Object`/`c.id` through `object_setIvar`
    /// and non-object Zig types through `getIvarPtr`.
    pub fn setIvarValue(self: Object, comptime T: type, ivar: Ivar, val: T) void {
        if (T == ?Object) {
            self.setIvar(ivar, val);
            return;
        }
        if (T == Object) {
            self.setIvar(ivar, val);
            return;
        }
        if (T == c.id) {
            c.object_setIvar(self.value, ivar.value, val);
            return;
        }
        self.getIvarPtr(T, ivar).* = val;
    }

    /// Looks up the instance variable `name` on `self`'s class and reads its typed value.
    /// Returns `null` if `self` is `nil`, a tagged pointer, the ivar is not found, or `T == Object` and the ivar holds `nil`.
    pub fn getTypedIvar(self: Object, comptime T: type, name: [:0]const u8) ?T {
        if (T != Object and T != c.id) {
            comptime ivar_pkg.validateDirectIvarType(T);
        }
        if (self.value == null or self.isTaggedPointer()) return null;
        const cls = c.object_getClass(self.value) orelse return null;
        const raw_ivar = c.class_getInstanceVariable(cls, name.ptr) orelse return null;
        const ivar: Ivar = .{ .value = raw_ivar };
        if (T == Object) return self.getIvar(ivar);
        return self.getIvarValue(T, ivar);
    }

    /// Looks up the instance variable `name` on `self`'s class and writes `val`.
    /// Returns `false` if `self` is `nil`, a tagged pointer, or no ivar named `name` exists on `self`'s class.
    pub fn setTypedIvar(self: Object, comptime T: type, name: [:0]const u8, val: T) bool {
        if (T != Object and T != c.id) {
            comptime ivar_pkg.validateDirectIvarType(T);
        }
        if (self.value == null or self.isTaggedPointer()) return false;
        const cls = c.object_getClass(self.value) orelse return false;
        const raw_ivar = c.class_getInstanceVariable(cls, name.ptr) orelse return false;
        self.setIvarValue(T, .{ .value = raw_ivar }, val);
        return true;
    }

    /// Associates `value` with `self` under pointer identity `key` using `policy` (`objc_setAssociatedObject`).
    /// Pass `null` for `value` to clear an existing association for `key`.
    pub fn setAssociatedObject(
        self: Object,
        key: *const anyopaque,
        value: ?Object,
        policy: OuterAssociationPolicy,
    ) void {
        c.objc_setAssociatedObject(
            self.value,
            key,
            if (value) |v| v.value else null,
            @backingInt(policy),
        );
    }

    /// Returns the object associated with `self` for pointer identity `key` (`objc_getAssociatedObject`),
    /// or `null` if none is set.
    pub fn getAssociatedObject(self: Object, key: *const anyopaque) ?Object {
        const raw = c.objc_getAssociatedObject(self.value, key);
        return if (raw == null) null else fromId(raw);
    }

    /// Removes all associated objects from `self` (`objc_removeAssociatedObjects`).
    pub fn removeAssociatedObjects(self: Object) void {
        c.objc_removeAssociatedObjects(self.value);
    }

    /// Acquires the recursive `@synchronized` monitor for `self` (`objc_sync_enter`),
    /// returning a `SyncGuard` whose `unlock()` releases the monitor (`objc_sync_exit`).
    pub fn synchronize(self: Object) sync.SyncError!sync.SyncGuard {
        return sync.synchronize(self);
    }

    pub inline fn retain(self: Object) Object {
        return fromId(objc_retain(self.value));
    }

    pub inline fn release(self: Object) void {
        objc_release(self.value);
    }

    /// Adds `self` to the current `AutoreleasePool` (`objc_autorelease`).
    pub inline fn autorelease(self: Object) Object {
        return fromId(objc_autorelease(self.value));
    }

    /// Retains `self` and adds it to the current `AutoreleasePool` (`objc_retainAutorelease`).
    pub inline fn retainAutorelease(self: Object) Object {
        return fromId(objc_retainAutorelease(self.value));
    }

    /// Claims/retains a value returned from an autoreleasing Objective-C call (`objc_retainAutoreleasedReturnValue`).
    pub inline fn retainAutoreleasedReturnValue(self: Object) Object {
        return fromId(objc_retainAutoreleasedReturnValue(self.value));
    }

    /// Retains `self` and prepares it for ARC autoreleased return handoff (`objc_retainAutoreleaseReturnValue`).
    pub inline fn retainAutoreleaseReturnValue(self: Object) Object {
        return fromId(objc_retainAutoreleaseReturnValue(self.value));
    }

    /// Claims an autoreleased return value without retaining (`objc_unsafeClaimAutoreleasedReturnValue`).
    pub inline fn unsafeClaimAutoreleasedReturnValue(self: Object) Object {
        return fromId(objc_unsafeClaimAutoreleasedReturnValue(self.value));
    }

    /// Atomically retains `new_val`, stores it into `slot`, and releases the previous value (`objc_storeStrong`).
    pub inline fn storeStrong(slot: *?Object, new_val: ?Object) void {
        var raw: c.id = if (slot.*) |prev| prev.value else null;
        const next_raw: c.id = if (new_val) |v| v.value else null;
        objc_storeStrong(&raw, next_raw);
        slot.* = if (raw == null) null else fromId(raw);
    }

    /// Return an iterator for this object. The object must implement the
    /// `NSFastEnumeration` protocol.
    pub inline fn iterate(self: Object) Iterator {
        return Iterator.init(self);
    }
};

pub const alloc = Object.alloc;
pub const allocInit = Object.allocInit;
pub const storeStrong = Object.storeStrong;

extern "c" fn objc_retain(objc.c.id) objc.c.id;
extern "c" fn objc_release(objc.c.id) void;
extern "c" fn objc_autorelease(objc.c.id) objc.c.id;
extern "c" fn objc_retainAutorelease(objc.c.id) objc.c.id;
extern "c" fn objc_retainAutoreleasedReturnValue(objc.c.id) objc.c.id;
extern "c" fn objc_retainAutoreleaseReturnValue(objc.c.id) objc.c.id;
extern "c" fn objc_unsafeClaimAutoreleasedReturnValue(objc.c.id) objc.c.id;
extern "c" fn objc_storeStrong(location: *objc.c.id, obj: objc.c.id) void;
extern "c" fn objc_alloc(objc.c.Class) objc.c.id;
extern "c" fn objc_alloc_init(objc.c.Class) objc.c.id;

fn retainCount(obj: Object) c_ulong {
    return obj.msgSend(c_ulong, objc.Sel.registerName("retainCount"), .{});
}

test {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    // Should work with our wrappers
    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    try testing.expect(obj.value != null);
    try testing.expectEqualStrings("NSObject", obj.getClassName());
    obj.msgSend(void, objc.sel("dealloc"), .{});
}

test "retain object" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const obj = NSObject.msgSend(objc.Object, objc.Sel.registerName("alloc"), .{});
    _ = obj.msgSend(objc.Object, objc.Sel.registerName("init"), .{});
    try testing.expectEqual(@as(c_ulong, 1), retainCount(obj));

    _ = obj.retain();
    try testing.expectEqual(@as(c_ulong, 2), retainCount(obj));

    obj.release();
    try testing.expectEqual(@as(c_ulong, 1), retainCount(obj));

    obj.msgSend(void, objc.sel("dealloc"), .{});
}

test "tagged pointer" {
    const testing = std.testing;

    // We can't force Objective-C to provide us with an unaligned tagged
    // pointer, so we try several times using different classes. We use
    // different classes instead of values, since pointers from the same
    // class will have the same alignment during a single execution (aarch64).
    const obj = blk: {
        var Class = objc.getClass("NSNumber").?;
        var sel = objc.Sel.registerName("numberWithChar:");
        var obj = Class.msgSend(objc.Object, sel, .{@as(u8, @intCast(5))});

        // We're only interested in an unaligned pointer.
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        Class = objc.getClass("NSString").?;
        sel = objc.Sel.registerName("stringWithUTF8String:");
        obj = Class.msgSend(objc.Object, sel, .{"foo"});
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        Class = objc.getClass("NSDate").?;
        sel = objc.Sel.registerName("date");
        obj = Class.msgSend(objc.Object, sel, .{});
        if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;

        const colors = [_][:0]const u8{
            "clearColor",    "blackColor",  "blueColor",  "brownColor",     "cyanColor",
            "darkGrayColor", "grayColor",   "greenColor", "lightGrayColor", "magentaColor",
            "orangeColor",   "purpleColor", "redColor",   "whiteColor",     "yellowColor",
        };

        Class = objc.getClass("NSColor").?;
        for (colors) |color| {
            sel = objc.Sel.registerName(color);
            obj = Class.msgSend(objc.Object, sel, .{});
            if (!std.mem.isAligned(@intFromPtr(obj.value), @alignOf(usize))) break :blk obj;
        }

        // In the unlikely event that we don't find an unaligned tagged pointer.
        std.log.warn("skipped 'tagged pointer' test because we couldn't find an unaligned tagged pointer", .{});
        return error.SkipZigTest;
    };

    // A tagged object is not allocated on the heap and cannot be retained.
    try testing.expect(retainCount(obj) != 1);

    // `Object.fromId` must work even when the pointer is unaligned.
    const obj_ptr = @intFromPtr(obj.value);
    try testing.expect(!std.mem.isAligned(obj_ptr, @alignOf(usize)));
    try testing.expect(std.meta.eql(obj, Object.fromId(obj.value)));
}

test "msgSend with objc wrapper args" {
    // Verifies that objc.Object, objc.Class, and objc.Sel are correctly
    // unwrapped to c.id / c.SEL when passed as msgSend arguments.
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const obj = NSObject.msgSend(objc.Object, "alloc", .{});
    _ = obj.msgSend(objc.Object, "init", .{});
    defer obj.msgSend(void, "dealloc", .{});

    // Pass objc.Class as an argument: -[NSObject isKindOfClass:]
    const is_nsobject = obj.msgSend(bool, "isKindOfClass:", .{NSObject});
    try testing.expect(is_nsobject);

    // Pass objc.Sel as an argument: -[NSObject respondsToSelector:]
    const responds = obj.msgSend(bool, "respondsToSelector:", .{objc.Sel.registerName("init")});
    try testing.expect(responds);
}

test {
    _ = @import("ivar.zig");
    _ = @import("weak.zig");
}

test "typed ivars (Zig pointers, integers, structs) and object ivars" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const MyState = struct {
        counter: usize,
        label: []const u8,
    };
    const Point = extern struct {
        x: f64,
        y: f64,
    };

    const raw_cls = c.objc_allocateClassPair(NSObject.value, "ZigObjcTypedIvarTestClass", 0) orelse return error.AllocateClassFailed;
    defer c.objc_disposeClassPair(raw_cls);

    const state_enc = comptime objc.comptimeEncode(*anyopaque);
    const usize_enc = comptime objc.comptimeEncode(usize);
    const point_enc = comptime objc.comptimeEncode(Point);

    try testing.expect(boolResult(c.class_addIvar(
        raw_cls,
        "state_ptr",
        @sizeOf(*MyState),
        std.math.log2_int(u8, @alignOf(*MyState)),
        &state_enc,
    )));
    try testing.expect(boolResult(c.class_addIvar(
        raw_cls,
        "count",
        @sizeOf(usize),
        std.math.log2_int(u8, @alignOf(usize)),
        &usize_enc,
    )));
    try testing.expect(boolResult(c.class_addIvar(
        raw_cls,
        "point",
        @sizeOf(Point),
        std.math.log2_int(u8, @alignOf(Point)),
        &point_enc,
    )));
    try testing.expect(boolResult(c.class_addIvar(
        raw_cls,
        "child_obj",
        @sizeOf(c.id),
        std.math.log2_int(u8, @alignOf(c.id)),
        "@",
    )));
    try testing.expect(boolResult(c.class_addIvar(
        raw_cls,
        "strong_obj",
        @sizeOf(c.id),
        std.math.log2_int(u8, @alignOf(c.id)),
        "@",
    )));

    c.objc_registerClassPair(raw_cls);
    const cls: objc.Class = .{ .value = raw_cls };

    const inst = Object.allocInit(cls) orelse return error.AllocInitFailed;
    defer inst.release();

    var state: MyState = .{ .counter = 10, .label = "zig-ivar" };

    const state_ivar: Ivar = .{ .value = c.class_getInstanceVariable(raw_cls, "state_ptr").? };
    const count_ivar: Ivar = .{ .value = c.class_getInstanceVariable(raw_cls, "count").? };
    const point_ivar: Ivar = .{ .value = c.class_getInstanceVariable(raw_cls, "point").? };
    const child_ivar: Ivar = .{ .value = c.class_getInstanceVariable(raw_cls, "child_obj").? };
    const strong_ivar: Ivar = .{ .value = c.class_getInstanceVariable(raw_cls, "strong_obj").? };

    // Pointer ivar via setIvarValue / getIvarValue / getIvarPtr / getTypedIvar
    inst.setIvarValue(*MyState, state_ivar, &state);
    const got_state = inst.getIvarValue(*MyState, state_ivar);
    try testing.expectEqual(@as(usize, 10), got_state.counter);
    try testing.expectEqualStrings("zig-ivar", got_state.label);
    got_state.counter = 42;
    try testing.expectEqual(@as(usize, 42), state.counter);
    try testing.expectEqual(&state, inst.getTypedIvar(*MyState, "state_ptr").?);

    // Integer ivar via getIvarPtr and by-name helpers
    inst.getIvarPtr(usize, count_ivar).* = 9001;
    try testing.expectEqual(@as(usize, 9001), inst.getIvarValue(usize, count_ivar));
    try testing.expect(inst.setTypedIvar(usize, "count", 12345));
    try testing.expectEqual(@as(usize, 12345), inst.getTypedIvar(usize, "count").?);

    // Extern struct ivar
    try testing.expect(inst.setTypedIvar(Point, "point", .{ .x = 1.5, .y = -3.25 }));
    const pt = inst.getIvarValue(Point, point_ivar);
    try testing.expectEqual(Point{ .x = 1.5, .y = -3.25 }, pt);

    // Missing ivar returns null / false
    try testing.expect(inst.getTypedIvar(usize, "no_such_ivar") == null);
    try testing.expect(!inst.setTypedIvar(usize, "no_such_ivar", 1));

    // Object ivars: getIvar / setIvar / setIvarWithStrongDefault / setInstanceVariableWithStrongDefault
    try testing.expect(inst.getIvar(child_ivar) == null);
    try testing.expect(inst.getTypedIvar(Object, "child_obj") == null);

    const child = Object.allocInit(NSObject).?;
    defer child.release();

    inst.setIvar(child_ivar, child);
    try testing.expectEqual(child.value, inst.getIvar(child_ivar).?.value);
    try testing.expectEqual(child.value, inst.getTypedIvar(Object, "child_obj").?.value);
    inst.setIvar(child_ivar, null);
    try testing.expect(inst.getIvar(child_ivar) == null);

    // Strong default retains unknown-ownership dynamic ivars
    const strong_target = Object.allocInit(NSObject).?;
    defer strong_target.release();
    try testing.expectEqual(@as(c_ulong, 1), retainCount(strong_target));

    inst.setIvarWithStrongDefault(strong_ivar, strong_target);
    try testing.expectEqual(@as(c_ulong, 2), retainCount(strong_target));
    inst.setIvarWithStrongDefault(strong_ivar, null);
    try testing.expectEqual(@as(c_ulong, 1), retainCount(strong_target));

    inst.setInstanceVariableWithStrongDefault("strong_obj", strong_target);
    try testing.expectEqual(@as(c_ulong, 2), retainCount(strong_target));
    inst.setInstanceVariableWithStrongDefault("strong_obj", null);
    try testing.expectEqual(@as(c_ulong, 1), retainCount(strong_target));
}

test "setClass and getIndexedIvars" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const ClassA = objc.allocateClassPair(NSObject, "ZigObjcSetClassA").?;
    defer objc.disposeClassPair(ClassA);
    try testing.expect(ClassA.addMethod("magicValue", struct {
        fn imp(_: c.id, _: c.SEL) callconv(.c) u64 {
            return 111;
        }
    }.imp));
    objc.registerClassPair(ClassA);

    const ClassB = objc.allocateClassPair(NSObject, "ZigObjcSetClassB").?;
    defer objc.disposeClassPair(ClassB);
    try testing.expect(ClassB.addMethod("magicValue", struct {
        fn imp(_: c.id, _: c.SEL) callconv(.c) u64 {
            return 222;
        }
    }.imp));
    objc.registerClassPair(ClassB);

    const inst = Object.allocInit(ClassA).?;
    defer inst.release();

    try testing.expectEqualStrings("ZigObjcSetClassA", inst.getClassName());
    try testing.expectEqual(@as(u64, 111), inst.msgSend(u64, "magicValue", .{}));

    const prev_cls = inst.setClass(ClassB).?;
    try testing.expectEqual(ClassA.value, prev_cls.value);
    try testing.expectEqualStrings("ZigObjcSetClassB", inst.getClassName());
    try testing.expectEqual(@as(u64, 222), inst.msgSend(u64, "magicValue", .{}));

    // Indexed ivars allocated via class_createInstance with extraBytes
    const extra_bytes = @sizeOf([4]u64);
    const indexed_obj = Object.fromId(c.class_createInstance(NSObject.value, extra_bytes))
        .msgSend(Object, "init", .{});
    defer indexed_obj.release();

    const extra_ptr: *align(1) [4]u64 = @ptrCast(indexed_obj.getIndexedIvars().?);
    try testing.expectEqual([4]u64{ 0, 0, 0, 0 }, extra_ptr.*);
    extra_ptr.* = .{ 10, 20, 30, 40 };

    const reread: *align(1) const [4]u64 = @ptrCast(indexed_obj.getIndexedIvars().?);
    try testing.expectEqual([4]u64{ 10, 20, 30, 40 }, reread.*);
}

test "associated objects" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;
    const NSMutableString = objc.getClass("NSMutableString").?;

    const Keys = struct {
        var retain_key: u8 = 0;
        var copy_key: u8 = 0;
        var dealloc_count: usize = 0;
    };
    Keys.dealloc_count = 0;

    const Tracked = objc.allocateClassPair(NSObject, "ZigObjcAssocTracked").?;
    defer objc.disposeClassPair(Tracked);
    _ = Tracked.replaceMethod("dealloc", struct {
        fn dealloc(target: c.id, _: c.SEL) callconv(.c) void {
            Keys.dealloc_count += 1;
            Object.fromId(target).msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
    }.dealloc);
    objc.registerClassPair(Tracked);

    const host = Object.allocInit(NSObject).?;
    defer host.release();

    try testing.expect(host.getAssociatedObject(&Keys.retain_key) == null);

    // Retain policy keeps associated object alive after releasing local reference.
    // Note: atomic `.retain` puts values returned by `objc_getAssociatedObject` into
    // the active autorelease pool, so scope the pool around the lookups.
    {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        const val = Object.allocInit(Tracked).?;
        host.setAssociatedObject(&Keys.retain_key, val, .retain);
        val.release();

        try testing.expectEqual(@as(usize, 0), Keys.dealloc_count);
        try testing.expect(host.getAssociatedObject(&Keys.retain_key) != null);

        // Copy policy snapshots mutable string
        const mut_str = NSMutableString.msgSend(Object, "stringWithUTF8String:", .{"before"});
        host.setAssociatedObject(&Keys.copy_key, mut_str, .copy_nonatomic);
        const NSString = objc.getClass("NSString").?;
        mut_str.msgSend(void, "appendString:", .{NSString.msgSend(Object, "stringWithUTF8String:", .{"_after"})});

        const copied = host.getAssociatedObject(&Keys.copy_key).?;
        try testing.expectEqualStrings("before", std.mem.span(copied.msgSend([*:0]const u8, "UTF8String", .{})));

        // Clear single association with null
        host.setAssociatedObject(&Keys.copy_key, null, .assign);
        try testing.expect(host.getAssociatedObject(&Keys.copy_key) == null);
    }
    try testing.expectEqual(@as(usize, 0), Keys.dealloc_count);

    // Remove all remaining associations and verify Tracked deallocated
    host.removeAssociatedObjects();
    try testing.expect(host.getAssociatedObject(&Keys.retain_key) == null);
    try testing.expectEqual(@as(usize, 1), Keys.dealloc_count);
}

test "alloc, allocInit, autorelease, ARC helpers, and storeStrong" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const Stats = struct {
        var init_count: usize = 0;
        var dealloc_count: usize = 0;
    };
    Stats.init_count = 0;
    Stats.dealloc_count = 0;

    const Tracked = objc.allocateClassPair(NSObject, "ZigObjcLifecycleTracked").?;
    defer objc.disposeClassPair(Tracked);
    _ = Tracked.replaceMethod("init", struct {
        fn init(target: c.id, _: c.SEL) callconv(.c) c.id {
            Stats.init_count += 1;
            return Object.fromId(target).msgSendSuper(objc.getClass("NSObject").?, Object, "init", .{}).value;
        }
    }.init);
    _ = Tracked.replaceMethod("dealloc", struct {
        fn dealloc(target: c.id, _: c.SEL) callconv(.c) void {
            Stats.dealloc_count += 1;
            Object.fromId(target).msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
    }.dealloc);
    objc.registerClassPair(Tracked);

    // alloc vs allocInit
    {
        const raw_alloc = Object.alloc(Tracked).?;
        try testing.expectEqual(@as(usize, 0), Stats.init_count);
        const initialized = raw_alloc.msgSend(Object, "init", .{});
        try testing.expectEqual(@as(usize, 1), Stats.init_count);
        initialized.release();
        try testing.expectEqual(@as(usize, 1), Stats.dealloc_count);
    }

    // autorelease inside AutoreleasePool
    {
        var pool = objc.AutoreleasePool.init();
        const auto_obj = Object.allocInit(Tracked).?;
        try testing.expectEqual(@as(usize, 2), Stats.init_count);
        _ = auto_obj.autorelease();
        try testing.expectEqual(@as(usize, 1), Stats.dealloc_count);
        pool.deinit();
        try testing.expectEqual(@as(usize, 2), Stats.dealloc_count);
    }

    // retainAutorelease and return-value ARC helpers inside AutoreleasePool
    {
        const obj = Object.allocInit(Tracked).?;
        {
            var pool = objc.AutoreleasePool.init();
            defer pool.deinit();

            _ = obj.retainAutorelease();
            try testing.expect(retainCount(obj) >= 2);

            const rv1 = obj.retainAutoreleaseReturnValue();
            const claimed = rv1.retainAutoreleasedReturnValue();
            claimed.release();

            const rv2 = obj.retainAutoreleaseReturnValue();
            _ = rv2.unsafeClaimAutoreleasedReturnValue();
        }
        try testing.expectEqual(@as(c_ulong, 1), retainCount(obj));
        try testing.expectEqual(@as(usize, 2), Stats.dealloc_count);
        obj.release();
        try testing.expectEqual(@as(usize, 3), Stats.dealloc_count);
    }

    // storeStrong lifecycle: nil -> obj_a -> self -> obj_b -> nil
    var slot: ?Object = null;
    {
        const obj_a = Object.allocInit(Tracked).?;
        Object.storeStrong(&slot, obj_a);
        try testing.expectEqual(obj_a.value, slot.?.value);
        obj_a.release();
    }
    try testing.expectEqual(@as(usize, 3), Stats.dealloc_count);

    // Self-assignment keeps object alive
    Object.storeStrong(&slot, slot);
    try testing.expectEqual(@as(usize, 3), Stats.dealloc_count);

    {
        const obj_b = Object.allocInit(Tracked).?;
        Object.storeStrong(&slot, obj_b);
        // Overwriting slot released obj_a
        try testing.expectEqual(@as(usize, 4), Stats.dealloc_count);
        try testing.expectEqual(obj_b.value, slot.?.value);
        obj_b.release();
    }
    try testing.expectEqual(@as(usize, 4), Stats.dealloc_count);

    Object.storeStrong(&slot, null);
    try testing.expect(slot == null);
    try testing.expectEqual(@as(usize, 5), Stats.dealloc_count);
}

test "Object copy, dispose, isClass, setInstanceVariable, and synchronize" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const inst = Object.allocInit(NSObject).?;
    defer inst.release();

    // isClass distinguishes instances, classes, metaclasses, and nil
    try testing.expect(!inst.isClass());
    try testing.expect(!(Object{ .value = null }).isClass());
    try testing.expect(Object.fromId(NSObject.value).isClass());
    try testing.expect(Object.fromId(objc.getMetaClass("NSObject").?.value).isClass());

    // object_copy + object_dispose
    const copied = inst.copy(0);
    try testing.expect(copied.value != null);
    try testing.expect(copied.value != inst.value);
    try testing.expectEqualStrings("NSObject", copied.getClassName());
    copied.dispose();

    // setInstanceVariable + getInstanceVariable
    const Holder = objc.allocateClassPair(NSObject, "ZigObjcInstVarHolder").?;
    try testing.expect(Holder.addIvar(Object, "slot"));
    objc.registerClassPair(Holder);
    defer objc.disposeClassPair(Holder);

    const holder = Object.allocInit(Holder).?;
    defer holder.release();
    holder.setInstanceVariable("slot", inst);
    try testing.expectEqual(inst.value, holder.getInstanceVariable("slot").value);
    holder.setInstanceVariable("slot", null);
    try testing.expect(holder.getInstanceVariable("slot").value == null);

    // Object.synchronize recursive monitor delegate
    var outer_guard = try inst.synchronize();
    defer outer_guard.unlock();
    var inner_guard = try inst.synchronize();
    inner_guard.unlock();
}

test "isTaggedPointer, nil guards, and getIvarPtrAligned" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSObject = objc.getClass("NSObject").?;
    const NSNumber = objc.getClass("NSNumber").?;

    const nil_obj: Object = .{ .value = null };
    try testing.expect(!nil_obj.isTaggedPointer());
    try testing.expect(nil_obj.setClass(NSObject) == null);
    try testing.expect(nil_obj.getIndexedIvars() == null);

    const heap_obj = Object.allocInit(NSObject).?;
    defer heap_obj.release();
    try testing.expect(!heap_obj.isTaggedPointer());

    const tagged_num = NSNumber.msgSend(Object, "numberWithInt:", .{@as(c_int, 42)});
    try testing.expect(tagged_num.isTaggedPointer());
    try testing.expect(tagged_num.getTypedIvar(usize, "isa") == null);
    try testing.expect(!tagged_num.setTypedIvar(usize, "isa", 0));

    const Vec2 = extern struct {
        x: f64,
        y: f64,
    };

    const AlignedCls = objc.allocateClassPair(NSObject, "ZigObjcAlignedIvarTest").?;
    defer objc.disposeClassPair(AlignedCls);
    try testing.expect(AlignedCls.addIvar(Vec2, "vec"));
    objc.registerClassPair(AlignedCls);

    const vec_ivar = AlignedCls.getInstanceVariable("vec").?;
    const aligned_inst = Object.allocInit(AlignedCls).?;
    defer aligned_inst.release();

    const vec_ptr: *Vec2 = aligned_inst.getIvarPtrAligned(Vec2, vec_ivar);
    try testing.expectEqual(*Vec2, @TypeOf(aligned_inst.getIvarPtrAligned(Vec2, vec_ivar)));
    vec_ptr.* = .{ .x = 4.5, .y = -8.25 };

    const via_offset = aligned_inst.getIvarPtrAtOffset(Vec2, vec_ivar.getOffset());
    try testing.expectEqual(Vec2{ .x = 4.5, .y = -8.25 }, via_offset.*);
}

test "getProperty and setProperty: nil safety, default cached selectors, and zero-malloc custom G/S attributes" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const Rect = extern struct {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    };

    // 1. Nil receiver safety (no panic; zero/null return for scalars, ?Object, Object, and stret structs)
    const nil_obj: Object = .{ .value = null };
    nil_obj.setProperty("count", @as(u64, 99));
    try testing.expectEqual(@as(u64, 0), nil_obj.getProperty(u64, "count"));
    try testing.expect(nil_obj.getProperty(?Object, "description") == null);
    try testing.expect(nil_obj.getProperty(Object, "description").value == null);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 0 }, nil_obj.getProperty(Rect, "frame"));

    // 2. Dynamic class with default property, 1-char property, and custom G/S property
    const NSObject = objc.getClass("NSObject").?;
    const PropCls = objc.allocateClassPair(NSObject, "ZigObjcZeroAllocPropTest").?;
    defer objc.disposeClassPair(PropCls);

    try testing.expect(PropCls.addIvar(u64, "_score"));
    try testing.expect(PropCls.addIvar(i32, "_x"));
    try testing.expect(PropCls.addIvar(bool, "_ready"));

    const default_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "Q"),
        objc.Property.attribute("N", ""),
        objc.Property.attribute("V", "_score"),
    };
    try testing.expect(PropCls.addProperty("score", &default_attrs));

    // Custom G/S with a type attribute containing embedded commas inside `{...}` to verify scanner robustness
    const custom_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "{Pair<int,Gfake>=ii}"),
        objc.Property.attribute("N", ""),
        objc.Property.attribute("G", "fetchReadyFlag"),
        objc.Property.attribute("S", "applyReadyFlag:"),
        objc.Property.attribute("V", "_ready"),
    };
    try testing.expect(PropCls.addProperty("ready", &custom_attrs));

    // Pathological > 255-byte custom getter selector to exercise the .overflow fallback path
    const long_getter_name: [:0]const u8 = "zigObjcCustomGetter_" ++ @as([245]u8, @splat('a')) ++ "";
    comptime std.debug.assert(long_getter_name.len == 265);
    const long_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "Q"),
        objc.Property.attribute("R", ""),
        objc.Property.attribute("G", long_getter_name),
    };
    try testing.expect(PropCls.addProperty("longProp", &long_attrs));

    try testing.expect(PropCls.addMethod("score", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) u64 {
            return Object.fromId(target).getTypedIvar(u64, "_score") orelse 0;
        }
    }.imp));
    try testing.expect(PropCls.addMethod("setScore:", struct {
        fn imp(target: c.id, _: c.SEL, v: u64) callconv(.c) void {
            _ = Object.fromId(target).setTypedIvar(u64, "_score", v);
        }
    }.imp));

    // Undeclared 1-char property ("x" -> "setX:")
    try testing.expect(PropCls.addMethod("x", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) i32 {
            return Object.fromId(target).getTypedIvar(i32, "_x") orelse 0;
        }
    }.imp));
    try testing.expect(PropCls.addMethod("setX:", struct {
        fn imp(target: c.id, _: c.SEL, v: i32) callconv(.c) void {
            _ = Object.fromId(target).setTypedIvar(i32, "_x", v);
        }
    }.imp));

    // Custom getter/setter IMPs
    try testing.expect(PropCls.addMethod("fetchReadyFlag", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) c.BOOL {
            const flag = Object.fromId(target).getTypedIvar(bool, "_ready") orelse false;
            return cpkg.boolParam(flag);
        }
    }.imp));
    try testing.expect(PropCls.addMethod("applyReadyFlag:", struct {
        fn imp(target: c.id, _: c.SEL, v: c.BOOL) callconv(.c) void {
            _ = Object.fromId(target).setTypedIvar(bool, "_ready", boolResult(v));
        }
    }.imp));
    try testing.expect(PropCls.addMethod(long_getter_name, struct {
        fn imp(_: c.id, _: c.SEL) callconv(.c) u64 {
            return 0xCAFE_BABE;
        }
    }.imp));

    objc.registerClassPair(PropCls);

    const inst = Object.allocInit(PropCls).?;
    defer inst.release();

    // Default declared property ("score" / "setScore:")
    inst.setProperty("score", @as(u64, 777));
    try testing.expectEqual(@as(u64, 777), inst.getProperty(u64, "score"));

    // Undeclared 1-char property ("x" / "setX:")
    inst.setProperty("x", @as(i32, -42));
    try testing.expectEqual(@as(i32, -42), inst.getProperty(i32, "x"));

    // Custom G/S property ("fetchReadyFlag" / "applyReadyFlag:")
    try testing.expect(!inst.getProperty(bool, "ready"));
    inst.setProperty("ready", true);
    try testing.expect(inst.getProperty(bool, "ready"));
    inst.setProperty("ready", false);
    try testing.expect(!inst.getProperty(bool, "ready"));

    // > 255-byte custom getter overflow fallback
    try testing.expectEqual(@as(u64, 0xCAFE_BABE), inst.getProperty(u64, "longProp"));

    // 3. Bracket/quote-aware scanner on compound struct/union/vector encodings + nil sret safety
    var scan_buf: [256]u8 = undefined;
    switch (findCustomSelectorAttr("T{Pair=\"a,Gbad\"i,\"b\"i},GcustomGet,V_pair", 'G', &scan_buf)) {
        .stack => |s| try testing.expectEqualStrings("customGet", s),
        else => return error.ExpectedCustomGetter,
    }
    switch (findCustomSelectorAttr("T{Bits<(8>>1),Gfake>=i},N,GrealGet,V_bits", 'G', &scan_buf)) {
        .stack => |s| try testing.expectEqualStrings("realGet", s),
        else => return error.ExpectedCustomGetter,
    }
    switch (findCustomSelectorAttr("T(Uni=\"x\"i,\"y\"d),ScustomSet:,V_u", 'S', &scan_buf)) {
        .stack => |s| try testing.expectEqualStrings("customSet:", s),
        else => return error.ExpectedCustomSetter,
    }
    switch (findCustomSelectorAttr("T![16,16f],GvecGet,V_vec", 'G', &scan_buf)) {
        .stack => |s| try testing.expectEqualStrings("vecGet", s),
        else => return error.ExpectedCustomGetter,
    }

    const BigInts = extern struct { a: u64, b: u64, c: u64, d: u64 };
    try testing.expectEqual(BigInts{ .a = 0, .b = 0, .c = 0, .d = 0 }, nil_obj.getProperty(BigInts, "bigInts"));

    // 4. Polymorphic 1-class PropCache latch hit + dynamic fallback on second class
    const PolyA = objc.allocateClassPair(NSObject, "ZigObjcPolyPropA").?;
    defer objc.disposeClassPair(PolyA);
    try testing.expect(PolyA.addIvar(i64, "_val"));
    try testing.expect(PolyA.addMethod("polyVal", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) i64 {
            return Object.fromId(target).getTypedIvar(i64, "_val") orelse 0;
        }
    }.imp));
    try testing.expect(PolyA.addMethod("setPolyVal:", struct {
        fn imp(target: c.id, _: c.SEL, v: i64) callconv(.c) void {
            _ = Object.fromId(target).setTypedIvar(i64, "_val", v);
        }
    }.imp));
    objc.registerClassPair(PolyA);

    const PolyB = objc.allocateClassPair(NSObject, "ZigObjcPolyPropB").?;
    defer objc.disposeClassPair(PolyB);
    try testing.expect(PolyB.addIvar(i64, "_val"));
    const poly_b_attrs = [_]objc.Property.Attribute{
        objc.Property.attribute("T", "q"),
        objc.Property.attribute("N", ""),
        objc.Property.attribute("G", "fetchPolyB"),
        objc.Property.attribute("S", "assignPolyB:"),
        objc.Property.attribute("V", "_val"),
    };
    try testing.expect(PolyB.addProperty("polyVal", &poly_b_attrs));
    try testing.expect(PolyB.addMethod("fetchPolyB", struct {
        fn imp(target: c.id, _: c.SEL) callconv(.c) i64 {
            return (Object.fromId(target).getTypedIvar(i64, "_val") orelse 0) + 1000;
        }
    }.imp));
    try testing.expect(PolyB.addMethod("assignPolyB:", struct {
        fn imp(target: c.id, _: c.SEL, v: i64) callconv(.c) void {
            _ = Object.fromId(target).setTypedIvar(i64, "_val", v * 2);
        }
    }.imp));
    objc.registerClassPair(PolyB);

    const poly_helpers = struct {
        fn writeProp(o: Object, v: i64) void {
            o.setProperty("polyVal", v);
        }
        fn readProp(o: Object) i64 {
            return o.getProperty(i64, "polyVal");
        }
    };

    const inst_a = Object.allocInit(PolyA).?;
    defer inst_a.release();
    const inst_b = Object.allocInit(PolyB).?;
    defer inst_b.release();

    // First call latches PolyA (`polyVal` / `setPolyVal:`), subsequent PolyB calls at the
    // exact same callsite fall back dynamically to `fetchPolyB` / `assignPolyB:`.
    poly_helpers.writeProp(inst_a, 21);
    try testing.expectEqual(@as(i64, 21), poly_helpers.readProp(inst_a));
    poly_helpers.writeProp(inst_b, 21);
    try testing.expectEqual(@as(i64, 1042), poly_helpers.readProp(inst_b));
    try testing.expectEqual(@as(i64, 21), poly_helpers.readProp(inst_a));
}
