const std = @import("std");
const abi = @import("abi.zig");
const cpkg = @import("c.zig");
const c = cpkg.c;
const boolResult = cpkg.boolResult;
const objc = @import("main.zig");

/// Ivar represents an instance variable in an Objective-C class definition.
pub const Ivar = extern struct {
    value: c.Ivar,

    /// Returns the name of an instance variable, or `null` if unavailable.
    pub inline fn getName(self: Ivar) ?[:0]const u8 {
        const ptr: [*:0]const u8 = c.ivar_getName(self.value) orelse return null;
        return std.mem.span(ptr);
    }

    /// Returns the Objective-C type encoding of an instance variable, or `null` if unavailable.
    pub inline fn getTypeEncoding(self: Ivar) ?[:0]const u8 {
        const ptr: [*:0]const u8 = c.ivar_getTypeEncoding(self.value) orelse return null;
        return std.mem.span(ptr);
    }

    /// Returns the byte offset of an instance variable from the start of an object instance.
    ///
    /// For Objective-C object instance variables (`id` / `Object`), prefer
    /// `Object.getIvar` and `Object.setIvar` rather than accessing memory at this offset directly.
    pub inline fn getOffset(self: Ivar) isize {
        return @intCast(c.ivar_getOffset(self.value));
    }

    comptime {
        std.debug.assert(@sizeOf(@This()) == @sizeOf(c.Ivar));
        std.debug.assert(@alignOf(@This()) == @alignOf(c.Ivar));
    }
};

pub fn validateDirectIvarType(comptime T: type) void {
    if (T == objc.Object or T == ?objc.Object or T == c.id) {
        @compileError("Objective-C object ivars must use Object.getIvar / Object.setIvar / Object.setIvarWithStrongDefault instead of direct byte-offset pointers");
    }
    switch (@typeInfo(T)) {
        .optional => |opt| {
            if (abi.WrapperUnderlying(opt.child) != null or abi.isBlockRefType(opt.child) or
                @typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice)
            {
                @compileError("ivar type " ++ @typeName(T) ++ " is a 16-byte Zig optional struct, not an 8-byte Objective-C handle; use the non-optional wrapper (e.g. objc.Class, objc.Sel, BlockRef) or ?*MyZigState instead");
            }
            validateDirectIvarNestedElement(@typeInfo(opt.child).pointer.child, &.{});
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("direct ivar access does not support Zig slices (" ++ @typeName(T) ++ "); store a pointer (*MyZigState) instead");
            }
            validateDirectIvarNestedElement(ptr.child, &.{ptr.child});
        },
        .array => validateDirectIvarNestedElement(T, &.{}),
        .@"struct" => |s| {
            if (s.layout == .auto) {
                @compileError("direct ivar access requires an extern/packed struct or pointer (*" ++ @typeName(T) ++ "), got auto-layout struct " ++ @typeName(T));
            }
            if (s.layout == .@"extern") {
                for (s.field_types) |FieldType| {
                    validateDirectIvarNestedElement(FieldType, &.{T});
                }
            }
        },
        .@"union" => |u| {
            if (u.layout == .auto) {
                @compileError("direct ivar access requires an extern/packed union or pointer (*" ++ @typeName(T) ++ "), got auto-layout union " ++ @typeName(T));
            }
            if (u.layout == .@"extern") {
                for (u.field_types) |FieldType| {
                    validateDirectIvarNestedElement(FieldType, &.{T});
                }
            }
        },
        else => {},
    }
}

fn validateDirectIvarNestedElement(comptime T: type, comptime seen: []const type) void {
    switch (@typeInfo(T)) {
        .optional => |opt| {
            if (abi.WrapperUnderlying(opt.child) != null or abi.isBlockRefType(opt.child) or
                @typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice)
            {
                @compileError("ivar element " ++ @typeName(T) ++ " is a 16-byte Zig optional struct, not an 8-byte Objective-C pointer");
            }
            validateDirectIvarNestedElement(@typeInfo(opt.child).pointer.child, seen);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("ivar element cannot be Zig slice " ++ @typeName(T));
            }
            for (seen) |prev| {
                if (prev == ptr.child) return;
            }
            validateDirectIvarNestedElement(ptr.child, seen ++ &[_]type{ptr.child});
        },
        .array => |arr| {
            if (@typeInfo(arr.child) == .@"struct" and @typeInfo(arr.child).@"struct".layout == .auto) {
                @compileError("ivar array element requires extern/packed struct, got auto-layout struct " ++ @typeName(arr.child));
            }
            if (@typeInfo(arr.child) == .@"union" and @typeInfo(arr.child).@"union".layout == .auto) {
                @compileError("ivar array element requires extern/packed union, got auto-layout union " ++ @typeName(arr.child));
            }
            validateDirectIvarNestedElement(arr.child, seen);
        },
        .@"struct" => |s| {
            if (s.layout == .@"extern") {
                for (s.field_types) |FieldType| {
                    validateDirectIvarNestedElement(FieldType, seen);
                }
            }
        },
        .@"union" => |u| {
            if (u.layout == .@"extern") {
                for (u.field_types) |FieldType| {
                    validateDirectIvarNestedElement(FieldType, seen);
                }
            }
        },
        else => {},
    }
}

/// Cached byte-offset handle for zero-overhead access to a non-object Zig instance
/// variable (`*MyZigState`, scalars, `extern struct`s) across instances of the same class.
pub fn IvarSlot(comptime T: type) type {
    comptime validateDirectIvarType(T);
    return struct {
        const Self = @This();
        const unresolved_offset: isize = std.math.minInt(isize);

        offset: isize = unresolved_offset,

        /// Initializes a resolved slot directly from an `Ivar`.
        pub inline fn fromIvar(ivar: Ivar) Self {
            std.debug.assert(ivar.value != null);
            return .{ .offset = ivar.getOffset() };
        }

        /// Initializes a resolved slot by looking up `ivar_name` on `cls` once.
        pub fn fromClass(cls: objc.Class, ivar_name: [:0]const u8) ?Self {
            const ivar = cls.getInstanceVariable(ivar_name) orelse return null;
            return fromIvar(ivar);
        }

        noinline fn resolveSlow(offset_slot: *isize, obj: objc.Object, ivar_name: [:0]const u8) ?isize {
            @branchHint(.unlikely);
            const cls = c.object_getClass(obj.value) orelse return null;
            const raw_ivar = c.class_getInstanceVariable(cls, ivar_name.ptr) orelse return null;
            const off: isize = @intCast(c.ivar_getOffset(raw_ivar));
            @atomicStore(isize, offset_slot, off, .monotonic);
            return off;
        }

        /// Resolves lazily once (lock-free `.monotonic` atomic) on first access against `obj`,
        /// then reuses the cached `isize` byte offset on every subsequent call (~0.3 ns).
        pub inline fn getPtr(self: *Self, obj: objc.Object, ivar_name: [:0]const u8) ?*T {
            if (obj.value == null or obj.isTaggedPointer()) return null;
            var off = @atomicLoad(isize, &self.offset, .monotonic);
            if (off == unresolved_offset) {
                off = resolveSlow(&self.offset, obj, ivar_name) orelse return null;
            }
            return obj.getIvarPtrAtOffset(T, off);
        }

        pub inline fn get(self: *Self, obj: objc.Object, ivar_name: [:0]const u8) ?T {
            const p = self.getPtr(obj, ivar_name) orelse return null;
            return p.*;
        }

        pub inline fn set(self: *Self, obj: objc.Object, ivar_name: [:0]const u8, val: T) bool {
            const p = self.getPtr(obj, ivar_name) orelse return false;
            p.* = val;
            return true;
        }

        /// Returns a direct aligned `*T` pointer using an eagerly resolved offset (`fromClass` / `fromIvar`).
        pub inline fn ptr(self: Self, obj: objc.Object) *T {
            std.debug.assert(self.offset != unresolved_offset);
            return obj.getIvarPtrAtOffset(T, self.offset);
        }

        /// Reads `T` from `obj` using an eagerly resolved slot (`fromClass` / `fromIvar`).
        pub inline fn load(self: Self, obj: objc.Object) T {
            return self.ptr(obj).*;
        }

        /// Writes `val` into `obj` using an eagerly resolved slot (`fromClass` / `fromIvar`).
        pub inline fn store(self: Self, obj: objc.Object, val: T) void {
            self.ptr(obj).* = val;
        }
    };
}

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

test "IvarSlot eager and lazy access across multiple instances" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const FrameMetrics = extern struct {
        frame_index: u64,
        dt: f64,
        flags: u32,
        _pad: u32 = 0,
    };

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, "ZigObjcIvarSlotTestClass") orelse return error.AllocateClassFailed;
    defer objc.disposeClassPair(cls);

    try testing.expect(cls.addIvar(*usize, "counter_ptr"));
    try testing.expect(cls.addIvar(FrameMetrics, "metrics"));
    objc.registerClassPair(cls);

    const inst1 = objc.allocInit(cls) orelse return error.AllocInitFailed;
    defer inst1.release();
    const inst2 = objc.allocInit(cls) orelse return error.AllocInitFailed;
    defer inst2.release();

    // Missing ivar returns null from fromClass
    try testing.expect(IvarSlot(*usize).fromClass(cls, "nonexistent") == null);

    // Eager resolution via fromClass and fromIvar (const zero-branch accessors)
    const ptr_slot = IvarSlot(*usize).fromClass(cls, "counter_ptr") orelse return error.SlotResolveFailed;
    const metrics_ivar = cls.getInstanceVariable("metrics") orelse return error.IvarNotFound;
    const eager_metrics_slot = IvarSlot(FrameMetrics).fromIvar(metrics_ivar);

    var c1: usize = 100;
    var c2: usize = 200;
    ptr_slot.store(inst1, &c1);
    ptr_slot.store(inst2, &c2);

    ptr_slot.load(inst1).* += 23;
    ptr_slot.ptr(inst2).*.* += 45;
    try testing.expectEqual(@as(usize, 123), c1);
    try testing.expectEqual(@as(usize, 245), c2);
    try testing.expectEqual(&c1, ptr_slot.load(inst1));
    try testing.expectEqual(&c2, ptr_slot.load(inst2));

    eager_metrics_slot.store(inst1, .{ .frame_index = 1, .dt = 0.008333, .flags = 7 });
    eager_metrics_slot.store(inst2, .{ .frame_index = 2, .dt = 0.016667, .flags = 3 });
    try testing.expectEqual(FrameMetrics{ .frame_index = 1, .dt = 0.008333, .flags = 7 }, eager_metrics_slot.load(inst1));
    try testing.expectEqual(FrameMetrics{ .frame_index = 2, .dt = 0.016667, .flags = 3 }, eager_metrics_slot.load(inst2));

    // Lazy atomic resolution via get / set / getPtr across instances + nil/tagged safety
    var lazy_ptr_slot: IvarSlot(*usize) = .{};
    var lazy_metrics_slot: IvarSlot(FrameMetrics) = .{};
    var missing_slot: IvarSlot(usize) = .{};

    const nil_obj: objc.Object = .{ .value = null };
    try testing.expect(lazy_ptr_slot.get(nil_obj, "counter_ptr") == null);
    try testing.expect(!lazy_ptr_slot.set(nil_obj, "counter_ptr", &c1));

    try testing.expect(missing_slot.get(inst1, "no_such_field") == null);
    try testing.expect(!missing_slot.set(inst1, "no_such_field", 1));

    try testing.expectEqual(&c1, lazy_ptr_slot.get(inst1, "counter_ptr").?);
    try testing.expectEqual(&c2, lazy_ptr_slot.get(inst2, "counter_ptr").?);

    var c3: usize = 999;
    try testing.expect(lazy_ptr_slot.set(inst1, "counter_ptr", &c3));
    try testing.expectEqual(&c3, lazy_ptr_slot.get(inst1, "counter_ptr").?);
    try testing.expectEqual(&c2, lazy_ptr_slot.get(inst2, "counter_ptr").?);

    // Nil and tagged-pointer receivers must still safely return null/false AFTER slot is resolved
    try testing.expect(lazy_ptr_slot.get(nil_obj, "counter_ptr") == null);
    try testing.expect(!lazy_ptr_slot.set(nil_obj, "counter_ptr", &c1));

    const NSNumber = objc.getClass("NSNumber").?;
    const tagged_num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 7)});
    try testing.expect(lazy_ptr_slot.get(tagged_num, "counter_ptr") == null);
    try testing.expect(!lazy_ptr_slot.set(tagged_num, "counter_ptr", &c1));

    try testing.expect(lazy_metrics_slot.set(inst1, "metrics", .{ .frame_index = 120, .dt = 0.008, .flags = 9 }));
    lazy_metrics_slot.getPtr(inst1, "metrics").?.frame_index = 121;
    try testing.expectEqual(@as(u64, 121), lazy_metrics_slot.get(inst1, "metrics").?.frame_index);
    try testing.expectEqual(@as(u64, 2), lazy_metrics_slot.get(inst2, "metrics").?.frame_index);
}
