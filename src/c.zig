const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("objc-c");

/// Platform-width signed/unsigned integers and bounds matching `<objc/NSObjCRuntime.h>`.
pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const NSIntegerMax = std.math.maxInt(NSInteger);
pub const NSIntegerMin = std.math.minInt(NSInteger);
pub const NSUIntegerMax = std.math.maxInt(NSUInteger);

/// On some targets, Objective-C uses `i8` instead of `bool`.
/// This helper casts a target value type to `bool`.
pub fn boolResult(result: c.BOOL) bool {
    return switch (c.BOOL) {
        bool => result,
        i8 => result != 0,
        else => @compileError("unexpected boolean type"),
    };
}

/// On some targets, Objective-C uses `bool` or `i8`.
/// This helper casts a `bool` value to the target value type.
pub fn boolParam(param: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => param,
        i8 => @intFromBool(param),
        else => @compileError("unexpected boolean type"),
    };
}

/// Resolves an optional weak Objective-C runtime symbol at runtime without
/// emitting a strong undefined Mach-O reference when targeting older Apple OS
/// deployment versions against a newer SDK.
///
/// Returns `null` if the active SDK headers do not declare `name`, or if `dyld`
/// resolves the weak symbol to `null` on an older host OS at runtime.
pub fn weakExtern(comptime Ptr: type, comptime name: [:0]const u8) Ptr {
    if (!@hasDecl(c, name)) return null;
    var sym = @extern(Ptr, .{
        .name = name,
        .linkage = .weak,
    });
    // Force a runtime GOT load so ReleaseFast cannot fold `@extern` to non-null at comptime.
    _ = &sym;
    return sym;
}

/// Reports whether `T` (at byte `base_offset` within an enclosing aggregate)
/// contains any leaf field whose offset is not a multiple of its natural C ABI
/// alignment (`x86_64` SysV AMD64 ABI §3.2.3 Rule 1).
pub fn hasUnalignedFields(comptime T: type, comptime base_offset: usize) bool {
    return comptime switch (@typeInfo(T)) {
        .void => false,
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => blk: {
                const align_bytes = @alignOf(T);
                break :blk align_bytes > 1 and (base_offset % align_bytes) != 0;
            },
            .@"extern" => blk: {
                for (s.field_names, s.field_types) |field_name, FieldType| {
                    if (hasUnalignedFields(FieldType, base_offset + @offsetOf(T, field_name))) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .auto => @compileError("hasUnalignedFields requires an extern or packed struct, got " ++ @typeName(T)),
        },
        .@"union" => |u| switch (u.layout) {
            .@"packed" => blk: {
                const align_bytes = @alignOf(T);
                break :blk align_bytes > 1 and (base_offset % align_bytes) != 0;
            },
            .@"extern" => blk: {
                for (u.field_types) |FieldType| {
                    if (hasUnalignedFields(FieldType, base_offset)) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            .auto => @compileError("hasUnalignedFields requires an extern or packed union, got " ++ @typeName(T)),
        },
        .array => |arr| blk: {
            if (hasUnalignedFields(arr.child, base_offset)) break :blk true;
            if (arr.len > 1 and hasUnalignedFields(arr.child, base_offset + @sizeOf(arr.child))) {
                break :blk true;
            }
            break :blk false;
        },
        else => blk: {
            const align_bytes = if (T == c_longdouble or T == f80) 16 else @alignOf(T);
            break :blk align_bytes > 1 and (base_offset % align_bytes) != 0;
        },
    };
}

const X86_64Class = enum {
    no_class,
    integer,
    sse,
    sseup,
    x87,
    x87up,
    memory,
};

fn mergeX86_64Class(a: X86_64Class, b: X86_64Class) X86_64Class {
    if (a == b) return a;
    if (a == .no_class) return b;
    if (b == .no_class) return a;
    if (a == .memory or b == .memory) return .memory;
    if (a == .integer or b == .integer) return .integer;
    if (a == .x87 or a == .x87up or b == .x87 or b == .x87up) return .memory;
    return .sse;
}

fn containsX86_64LongDouble(comptime T: type) bool {
    return comptime blk: {
        if (T == c_longdouble or T == f80) break :blk true;
        break :blk switch (@typeInfo(T)) {
            .float => |f| f.bits == 80,
            .@"struct" => |s| inner: {
                if (s.layout == .@"packed") break :inner false;
                for (s.field_types) |FieldType| {
                    if (containsX86_64LongDouble(FieldType)) break :inner true;
                }
                break :inner false;
            },
            .@"union" => |u| inner: {
                if (u.layout == .@"packed") break :inner false;
                for (u.field_types) |FieldType| {
                    if (containsX86_64LongDouble(FieldType)) break :inner true;
                }
                break :inner false;
            },
            .array => |arr| arr.len > 0 and containsX86_64LongDouble(arr.child),
            else => false,
        };
    };
}

fn classifyX86_64Field(
    comptime T: type,
    comptime offset: usize,
    classes: *[2]X86_64Class,
) bool {
    if (T == c_longdouble or T == f80 or (@typeInfo(T) == .float and @typeInfo(T).float.bits == 80)) {
        if (offset != 0) return false;
        classes[0] = mergeX86_64Class(classes[0], .x87);
        classes[1] = mergeX86_64Class(classes[1], .x87up);
        return true;
    }

    switch (@typeInfo(T)) {
        .void => return true,
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => {
                if (@bitSizeOf(T) == 0) return true;
                if (offset + @sizeOf(T) > 16) return false;
                classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .integer);
                if ((offset + @sizeOf(T) - 1) / 8 != offset / 8) {
                    classes[1] = mergeX86_64Class(classes[1], .integer);
                }
                return true;
            },
            .@"extern" => {
                if (@sizeOf(T) == 0) return true;
                var non_empty_fields: usize = 0;
                var has_ld_field = false;
                inline for (s.field_names, s.field_types) |field_name, FieldType| {
                    if (@sizeOf(FieldType) > 0) {
                        non_empty_fields += 1;
                        if (comptime containsX86_64LongDouble(FieldType)) has_ld_field = true;
                    }
                    if (!classifyX86_64Field(FieldType, offset + @offsetOf(T, field_name), classes)) {
                        return false;
                    }
                }
                // On x86_64, `long double` is 16 bytes, so combining it with any other
                // non-empty struct field always exceeds the 16-byte register threshold.
                if (has_ld_field and non_empty_fields > 1) return false;
                return true;
            },
            .auto => @compileError("x86_64 ABI classification requires extern or packed struct, got " ++ @typeName(T)),
        },
        .@"union" => |u| switch (u.layout) {
            .@"packed" => {
                if (@bitSizeOf(T) == 0) return true;
                if (offset + @sizeOf(T) > 16) return false;
                classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .integer);
                if ((offset + @sizeOf(T) - 1) / 8 != offset / 8) {
                    classes[1] = mergeX86_64Class(classes[1], .integer);
                }
                return true;
            },
            .@"extern" => {
                if (@sizeOf(T) == 0) return true;
                inline for (u.field_types) |FieldType| {
                    if (!classifyX86_64Field(FieldType, offset, classes)) {
                        return false;
                    }
                }
                return true;
            },
            .auto => @compileError("x86_64 ABI classification requires extern or packed union, got " ++ @typeName(T)),
        },
        .array => |arr| {
            if (arr.len == 0 or @sizeOf(arr.child) == 0) return true;
            if (offset + @sizeOf(T) > 16) return false;
            inline for (0..arr.len) |idx| {
                if (!classifyX86_64Field(arr.child, offset + idx * @sizeOf(arr.child), classes)) {
                    return false;
                }
            }
            return true;
        },
        .float => |f| {
            if (offset + @sizeOf(T) > 16) return false;
            if (f.bits == 128) {
                if (offset != 0) return false;
                classes[0] = mergeX86_64Class(classes[0], .sse);
                classes[1] = mergeX86_64Class(classes[1], .sseup);
            } else {
                classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .sse);
            }
            return true;
        },
        .vector => {
            if (@sizeOf(T) == 0) return true;
            if (offset + @sizeOf(T) > 16) return false;
            classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .sse);
            if (@sizeOf(T) > 8) {
                classes[1] = mergeX86_64Class(classes[1], .sseup);
            }
            return true;
        },
        else => {
            if (@sizeOf(T) == 0) return true;
            if (offset + @sizeOf(T) > 16) return false;
            classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .integer);
            if ((offset + @sizeOf(T) - 1) / 8 != offset / 8) {
                classes[1] = mergeX86_64Class(classes[1], .integer);
            }
            return true;
        },
    }
}

fn classifyX86_64Aggregate(comptime T: type) X86_64Class {
    return comptime blk: {
        if (@sizeOf(T) > 16) break :blk .memory;
        if (hasUnalignedFields(T, 0)) break :blk .memory;
        if (@sizeOf(T) == 0) break :blk .no_class;

        var classes: [2]X86_64Class = .{ .no_class, .no_class };
        if (!classifyX86_64Field(T, 0, &classes)) break :blk .memory;

        // SysV AMD64 ABI §3.2.3 post-merger cleanup (Rule 5):
        if (classes[0] == .memory or classes[1] == .memory) break :blk .memory;
        if (classes[0] == .x87up) break :blk .memory;
        if (classes[1] == .x87up and classes[0] != .x87) break :blk .memory;
        if (classes[0] == .x87 and classes[1] == .x87up) break :blk .x87;
        break :blk classes[0];
    };
}

/// Reports whether C-ABI return type `T` has SysV AMD64 ABI class `MEMORY` on
/// `x86_64` and therefore requires `objc_msgSend_stret`, `objc_msgSendSuper_stret`,
/// `method_invoke_stret`, and `BLOCK_USE_STRET`.
///
/// Independent of the current compilation host architecture so unit tests on
/// `aarch64` can directly verify `x86_64` aggregate classification.
pub fn x86_64AggregateUsesStret(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => false,
            .@"extern" => classifyX86_64Aggregate(T) == .memory,
            .auto => @compileError("x86_64AggregateUsesStret requires an extern or packed struct, got " ++ @typeName(T)),
        },
        .@"union" => |u| switch (u.layout) {
            .@"packed" => false,
            .@"extern" => classifyX86_64Aggregate(T) == .memory,
            .auto => @compileError("x86_64AggregateUsesStret requires an extern or packed union, got " ++ @typeName(T)),
        },
        else => false,
    };
}

/// Reports whether C-ABI return type `T` uses `stret` hidden-pointer return on
/// the active compilation target.
pub fn usesStret(comptime T: type) bool {
    return comptime (builtin.target.cpu.arch == .x86_64 and x86_64AggregateUsesStret(T));
}

/// Reports whether C-ABI return type `T` returns in `%st(0)` (`[X87, X87UP]`)
/// on `x86_64` and therefore requires `objc_msgSend_fpret` (including `f80`,
/// `c_longdouble`, and single-leaf `long double` aggregates at offset 0).
///
/// Independent of the current compilation host architecture so unit tests on
/// `aarch64` can directly verify `x86_64` `fpret` classification.
pub fn x86_64UsesFpret(comptime T: type) bool {
    return comptime blk: {
        if (T == c_longdouble or T == f80) break :blk true;
        break :blk switch (@typeInfo(T)) {
            .float => |f| f.bits == 80,
            .@"struct" => |s| switch (s.layout) {
                .@"packed" => false,
                .@"extern" => classifyX86_64Aggregate(T) == .x87,
                .auto => @compileError("x86_64UsesFpret requires an extern or packed struct, got " ++ @typeName(T)),
            },
            .@"union" => |u| switch (u.layout) {
                .@"packed" => false,
                .@"extern" => classifyX86_64Aggregate(T) == .x87,
                .auto => @compileError("x86_64UsesFpret requires an extern or packed union, got " ++ @typeName(T)),
            },
            else => false,
        };
    };
}

/// Reports whether C-ABI return type `T` uses `%st(0)` `fpret` return on the
/// active compilation target.
pub fn usesFpret(comptime T: type) bool {
    return comptime (builtin.target.cpu.arch == .x86_64 and x86_64UsesFpret(T));
}

test "NSObjCRuntime integer types and limits" {
    const testing = std.testing;
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(NSInteger));
    try testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(NSUInteger));
    try testing.expect(NSIntegerMax > 0);
    try testing.expect(NSIntegerMin < 0);
    try testing.expectEqual(@as(NSUInteger, @bitCast(@as(NSInteger, -1))), NSUIntegerMax);
    try testing.expect(boolResult(boolParam(true)));
    try testing.expect(!boolResult(boolParam(false)));
}

test "x86_64 SysV ABI stret and fpret classification" {
    const testing = std.testing;

    const Empty = extern struct {};
    const Aligned16 = extern struct { a: f64, b: f64 };
    const Large24 = extern struct { a: f64, b: f64, c: f64 };
    const Unaligned9 = extern struct { a: u8, b: i64 align(1) };
    const TailPacked9 = extern struct { a: i64 align(1), b: u8 };
    const NestedUnaligned = extern struct {
        tag: u8,
        inner: extern struct { x: i32 align(1) },
    };
    const ArrayStrideUnaligned = extern struct {
        items: [2]extern struct { x: u32 align(1), y: u8 },
    };
    const Packed64 = packed struct(u64) { lo: u32, hi: u32 };
    const Packed128 = packed struct(u128) { lo: u64, hi: u64 };
    const LongDoubleStruct = extern struct { x: c_longdouble };
    const NestedLongDoubleStruct = extern struct { inner: LongDoubleStruct };
    const LongDoublePlusByte = extern struct { x: c_longdouble, b: u8 };
    const MixedLongDoubleFloatUnion = extern union { ld: c_longdouble, d: f64 };
    const MixedLongDoubleIntUnion = extern union { ld: c_longdouble, u: u64 };

    try testing.expectEqual(@as(usize, 9), @sizeOf(Unaligned9));
    try testing.expectEqual(@as(usize, 9), @sizeOf(TailPacked9));

    // stret classification
    try testing.expect(!x86_64AggregateUsesStret(Empty));
    try testing.expect(!x86_64AggregateUsesStret(Aligned16));
    try testing.expect(x86_64AggregateUsesStret(Large24));
    try testing.expect(x86_64AggregateUsesStret(Unaligned9));
    try testing.expect(!x86_64AggregateUsesStret(TailPacked9));
    try testing.expect(x86_64AggregateUsesStret(NestedUnaligned));
    try testing.expect(x86_64AggregateUsesStret(ArrayStrideUnaligned));
    try testing.expect(!x86_64AggregateUsesStret(Packed64));
    try testing.expect(!x86_64AggregateUsesStret(Packed128));
    try testing.expect(!x86_64AggregateUsesStret(i64));
    try testing.expect(!x86_64AggregateUsesStret(f64));
    try testing.expect(!x86_64AggregateUsesStret(c_longdouble));
    try testing.expect(!x86_64AggregateUsesStret(LongDoubleStruct));
    try testing.expect(!x86_64AggregateUsesStret(NestedLongDoubleStruct));
    try testing.expect(x86_64AggregateUsesStret(LongDoublePlusByte));
    try testing.expect(x86_64AggregateUsesStret(MixedLongDoubleFloatUnion));
    try testing.expect(x86_64AggregateUsesStret(MixedLongDoubleIntUnion));

    // fpret classification
    try testing.expect(!x86_64UsesFpret(f32));
    try testing.expect(!x86_64UsesFpret(f64));
    try testing.expect(x86_64UsesFpret(f80));
    try testing.expect(x86_64UsesFpret(c_longdouble));
    try testing.expect(x86_64UsesFpret(LongDoubleStruct));
    try testing.expect(x86_64UsesFpret(NestedLongDoubleStruct));
    try testing.expect(!x86_64UsesFpret(Aligned16));
    try testing.expect(!x86_64UsesFpret(Unaligned9));
    try testing.expect(!x86_64UsesFpret(LongDoublePlusByte));
    try testing.expect(!x86_64UsesFpret(MixedLongDoubleFloatUnion));
    try testing.expect(!x86_64UsesFpret(MixedLongDoubleIntUnion));

    if (builtin.target.cpu.arch == .aarch64) {
        try testing.expect(!usesStret(Large24));
        try testing.expect(!usesStret(Unaligned9));
        try testing.expect(!usesFpret(c_longdouble));
        try testing.expect(!usesFpret(LongDoubleStruct));
    } else if (builtin.target.cpu.arch == .x86_64) {
        try testing.expect(usesStret(Large24));
        try testing.expect(usesStret(Unaligned9));
        try testing.expect(!usesStret(TailPacked9));
        try testing.expect(usesFpret(c_longdouble));
        try testing.expect(usesFpret(LongDoubleStruct));
    }
}
