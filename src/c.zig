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
pub inline fn boolResult(result: c.BOOL) bool {
    return switch (c.BOOL) {
        bool => result,
        i8 => result != 0,
        else => @compileError("unexpected boolean type"),
    };
}

/// On some targets, Objective-C uses `bool` or `i8`.
/// This helper casts a `bool` value to the target value type.
pub inline fn boolParam(param: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => param,
        i8 => @intFromBool(param),
        else => @compileError("unexpected boolean type"),
    };
}

fn WeakExternReturn(comptime FnOrOptPtr: type) type {
    return switch (@typeInfo(FnOrOptPtr)) {
        .optional => |opt| if (@typeInfo(opt.child) == .pointer)
            FnOrOptPtr
        else
            @compileError("weakExtern expected a pointer or optional pointer type, got " ++ @typeName(FnOrOptPtr)),
        .pointer => ?FnOrOptPtr,
        else => @compileError("weakExtern expected a pointer or optional pointer type, got " ++ @typeName(FnOrOptPtr)),
    };
}

/// Resolves an optional weak Objective-C runtime symbol at runtime without
/// emitting a strong undefined Mach-O reference when targeting older Apple OS
/// deployment versions against a newer SDK.
///
/// Caches the resolved pointer in a lock-free `.monotonic` atomic static slot per
/// `(Fn, symbol_name)` instantiation using a private sentinel address to distinguish
/// "unresolved" from "resolved to `null`".
pub inline fn weakExtern(comptime Fn: type, comptime symbol_name: []const u8) WeakExternReturn(Fn) {
    const OptFn = WeakExternReturn(Fn);
    if (!@hasDecl(c, symbol_name)) return null;

    const Cache = struct {
        var unresolved_sentinel: u8 = 0;
        var slot: ?*const anyopaque = @ptrCast(&unresolved_sentinel);

        noinline fn resolve() OptFn {
            @branchHint(.unlikely);
            var sym = @extern(OptFn, .{
                .name = symbol_name,
                .linkage = .weak,
            });
            // Force a runtime GOT load so ReleaseFast cannot fold `@extern` to non-null at comptime.
            _ = &sym;
            @atomicStore(
                ?*const anyopaque,
                &slot,
                if (sym) |f| @ptrCast(f) else null,
                .monotonic,
            );
            return sym;
        }
    };

    const cached = @atomicLoad(?*const anyopaque, &Cache.slot, .monotonic);
    if (cached != @as(?*const anyopaque, @ptrCast(&Cache.unresolved_sentinel))) {
        const NonNullFn = @typeInfo(OptFn).optional.child;
        return if (cached) |p| @as(NonNullFn, @ptrCast(@alignCast(p))) else null;
    }
    return Cache.resolve();
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

fn classifyX86_64Field(
    comptime T: type,
    comptime offset: usize,
    comptime max_bytes: usize,
    classes: *[8]X86_64Class,
) bool {
    if (T == c_longdouble or T == f80 or (@typeInfo(T) == .float and @typeInfo(T).float.bits == 80)) {
        if (offset + 16 > max_bytes) return false;
        classes[offset / 8] = mergeX86_64Class(classes[offset / 8], .x87);
        classes[(offset / 8) + 1] = mergeX86_64Class(classes[(offset / 8) + 1], .x87up);
        return true;
    }

    switch (@typeInfo(T)) {
        .void => return true,
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => {
                if (@bitSizeOf(T) == 0) return true;
                if (offset + @sizeOf(T) > max_bytes) return false;
                const start_eb = offset / 8;
                const end_eb = (offset + @sizeOf(T) - 1) / 8;
                var eb = start_eb;
                while (eb <= end_eb) : (eb += 1) {
                    classes[eb] = mergeX86_64Class(classes[eb], .integer);
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
                        if (FieldType == c_longdouble or FieldType == f80 or (@typeInfo(FieldType) == .float and @typeInfo(FieldType).float.bits == 80)) {
                            has_ld_field = true;
                        }
                    }
                    if (!classifyX86_64Field(FieldType, offset + @offsetOf(T, field_name), max_bytes, classes)) {
                        return false;
                    }
                }
                if (has_ld_field and non_empty_fields > 1) return false;
                return true;
            },
            .auto => @compileError("x86_64 ABI classification requires extern or packed struct, got " ++ @typeName(T)),
        },
        .@"union" => |u| switch (u.layout) {
            .@"packed" => {
                if (@bitSizeOf(T) == 0) return true;
                if (offset + @sizeOf(T) > max_bytes) return false;
                const start_eb = offset / 8;
                const end_eb = (offset + @sizeOf(T) - 1) / 8;
                var eb = start_eb;
                while (eb <= end_eb) : (eb += 1) {
                    classes[eb] = mergeX86_64Class(classes[eb], .integer);
                }
                return true;
            },
            .@"extern" => {
                if (@sizeOf(T) == 0) return true;
                inline for (u.field_types) |FieldType| {
                    if (!classifyX86_64Field(FieldType, offset, max_bytes, classes)) {
                        return false;
                    }
                }
                return true;
            },
            .auto => @compileError("x86_64 ABI classification requires extern or packed union, got " ++ @typeName(T)),
        },
        .array => |arr| {
            if (arr.len == 0 or @sizeOf(arr.child) == 0) return true;
            if (offset + @sizeOf(T) > max_bytes) return false;
            inline for (0..arr.len) |idx| {
                if (!classifyX86_64Field(arr.child, offset + idx * @sizeOf(arr.child), max_bytes, classes)) {
                    return false;
                }
            }
            return true;
        },
        .float => |f| {
            if (offset + @sizeOf(T) > max_bytes) return false;
            const start_eb = offset / 8;
            classes[start_eb] = mergeX86_64Class(classes[start_eb], .sse);
            if (f.bits == 128) {
                classes[start_eb + 1] = mergeX86_64Class(classes[start_eb + 1], .sseup);
            }
            return true;
        },
        .vector => {
            if (@sizeOf(T) == 0) return true;
            if (offset + @sizeOf(T) > max_bytes) return false;
            const start_eb = offset / 8;
            const end_eb = (offset + @sizeOf(T) - 1) / 8;
            classes[start_eb] = mergeX86_64Class(classes[start_eb], .sse);
            var eb = start_eb + 1;
            while (eb <= end_eb) : (eb += 1) {
                classes[eb] = mergeX86_64Class(classes[eb], .sseup);
            }
            return true;
        },
        else => {
            if (@sizeOf(T) == 0) return true;
            if (offset + @sizeOf(T) > max_bytes) return false;
            const start_eb = offset / 8;
            const end_eb = (offset + @sizeOf(T) - 1) / 8;
            var eb = start_eb;
            while (eb <= end_eb) : (eb += 1) {
                classes[eb] = mergeX86_64Class(classes[eb], .integer);
            }
            return true;
        },
    }
}

fn classifyX86_64AggregateWithSimd(
    comptime T: type,
    comptime has_avx: bool,
    comptime has_avx512f: bool,
) X86_64Class {
    return comptime blk: {
        const max_bytes: usize = if (has_avx512f) 64 else if (has_avx) 32 else 16;
        if (@sizeOf(T) > max_bytes) break :blk .memory;
        if (hasUnalignedFields(T, 0)) break :blk .memory;
        if (@sizeOf(T) == 0) break :blk .no_class;

        var num_eightbytes: usize = (@sizeOf(T) + 7) / 8;
        var classes: [8]X86_64Class = @splat(.no_class);
        if (!classifyX86_64Field(T, 0, max_bytes, &classes)) break :blk .memory;
        for (classes, 0..) |cls, idx| {
            if (cls != .no_class and idx + 1 > num_eightbytes) num_eightbytes = idx + 1;
        }

        // SysV AMD64 ABI §3.2.3 post-merger cleanup (Rule 5):
        // (a) If one of the classes is MEMORY, the whole argument is passed in memory.
        // (b) If X87UP is not preceded by X87, SysV ELF passes the whole aggregate in
        //     memory, whereas Darwin x86_64 (`X86_64ABIInfo::postMerge`) reclassifies
        //     standalone X87UP to SSE (returning `{ i64, double }` via `objc_msgSend`).
        for (classes[0..num_eightbytes], 0..) |cls, i| {
            if (cls == .memory) break :blk .memory;
            if (cls == .x87up and (i == 0 or classes[i - 1] != .x87)) {
                if (builtin.target.os.tag.isDarwin()) {
                    classes[i] = .sse;
                } else {
                    break :blk .memory;
                }
            }
        }

        // (c) If the size of the aggregate exceeds two eightbytes and the first
        // eightbyte isn't SSE or any other eightbyte isn't SSEUP, pass in memory.
        if (@sizeOf(T) > 16) {
            if (classes[0] != .sse) break :blk .memory;
            for (classes[1..num_eightbytes]) |cls| {
                if (cls != .sseup) break :blk .memory;
            }
            break :blk .sse;
        }

        // For <= 16B aggregates, only pure [X87, X87UP] returns in %st(0); mixed
        // [X87, SSE/INTEGER] returns in registers (%st(0)+...) or memory? On SysV
        // AMD64, [X87, INTEGER] / [X87, SSE] is valid only when X87 is paired with X87UP
        // because an 80-bit x87 value always spans 10 bytes (two eightbytes).
        if (num_eightbytes == 2 and classes[0] == .x87 and classes[1] == .x87up) break :blk .x87;
        if (classes[0] == .x87 or (num_eightbytes == 2 and classes[1] == .x87)) break :blk .memory;
        break :blk classes[0];
    };
}

fn classifyX86_64Aggregate(comptime T: type) X86_64Class {
    const has_avx = builtin.target.cpu.arch == .x86_64 and
        std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx);
    const has_avx512f = builtin.target.cpu.arch == .x86_64 and
        std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx512f);
    return classifyX86_64AggregateWithSimd(T, has_avx, has_avx512f);
}

/// Variant of `x86_64AggregateUsesStret` parameterized by AVX / AVX-512F target
/// feature availability so tests on any host architecture can verify SIMD rules.
pub fn x86_64AggregateUsesStretWithSimd(
    comptime T: type,
    comptime has_avx: bool,
    comptime has_avx512f: bool,
) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct" => |s| switch (s.layout) {
            .@"packed" => false,
            .@"extern" => classifyX86_64AggregateWithSimd(T, has_avx, has_avx512f) == .memory,
            .auto => @compileError("x86_64AggregateUsesStret requires an extern or packed struct, got " ++ @typeName(T)),
        },
        .@"union" => |u| switch (u.layout) {
            .@"packed" => false,
            .@"extern" => classifyX86_64AggregateWithSimd(T, has_avx, has_avx512f) == .memory,
            .auto => @compileError("x86_64AggregateUsesStret requires an extern or packed union, got " ++ @typeName(T)),
        },
        else => false,
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

const Aarch64HomogeneousInfo = struct {
    base: type,
    count: usize,
};

fn aapcs64HomogeneousInfo(comptime T: type) ?Aarch64HomogeneousInfo {
    return comptime switch (@typeInfo(T)) {
        .float => |f| switch (f.bits) {
            16 => .{ .base = f16, .count = 1 },
            32 => .{ .base = f32, .count = 1 },
            64 => .{ .base = f64, .count = 1 },
            128 => .{ .base = f128, .count = 1 },
            else => null,
        },
        .vector => if (@sizeOf(T) == 8 or @sizeOf(T) == 16)
            .{ .base = T, .count = 1 }
        else
            null,
        .array => |arr| blk: {
            if (arr.len == 0) break :blk .{ .base = void, .count = 0 };
            const sub = aapcs64HomogeneousInfo(arr.child) orelse break :blk null;
            if (sub.count == 0) break :blk .{ .base = void, .count = 0 };
            const total = sub.count * arr.len;
            if (total > 4) break :blk null;
            if (@sizeOf(T) != total * @sizeOf(sub.base)) break :blk null;
            break :blk .{ .base = sub.base, .count = total };
        },
        .@"struct" => |s| blk: {
            if (s.layout != .@"extern") break :blk null;
            if (@sizeOf(T) == 0) break :blk .{ .base = void, .count = 0 };
            if (hasUnalignedFields(T, 0)) break :blk null;

            var base: ?type = null;
            var count: usize = 0;
            for (s.field_types) |FieldType| {
                const sub = aapcs64HomogeneousInfo(FieldType) orelse break :blk null;
                if (sub.count == 0) continue;
                if (base) |existing| {
                    if (existing != sub.base) break :blk null;
                } else {
                    base = sub.base;
                }
                count += sub.count;
                if (count > 4) break :blk null;
            }
            const resolved_base = base orelse break :blk null;
            if (count == 0 or @sizeOf(T) != count * @sizeOf(resolved_base)) break :blk null;
            break :blk .{ .base = resolved_base, .count = count };
        },
        .@"union" => |u| blk: {
            if (u.layout != .@"extern") break :blk null;
            if (@sizeOf(T) == 0) break :blk .{ .base = void, .count = 0 };
            if (hasUnalignedFields(T, 0)) break :blk null;

            var base: ?type = null;
            var max_count: usize = 0;
            for (u.field_types) |FieldType| {
                const sub = aapcs64HomogeneousInfo(FieldType) orelse break :blk null;
                if (sub.count == 0) continue;
                if (base) |existing| {
                    if (existing != sub.base) break :blk null;
                } else {
                    base = sub.base;
                }
                if (sub.count > max_count) max_count = sub.count;
            }
            const resolved_base = base orelse break :blk null;
            if (max_count == 0 or max_count > 4) break :blk null;
            if (@sizeOf(T) != max_count * @sizeOf(resolved_base)) break :blk null;
            break :blk .{ .base = resolved_base, .count = max_count };
        },
        else => null,
    };
}

/// Reports whether `T` is an AAPCS64 Homogeneous Floating-Point Aggregate (HFA:
/// 1..4 elements all of the exact same `f16`, `f32`, or `f64` scalar type) or
/// Homogeneous Short-Vector Aggregate (HVA: 1..4 elements all of the exact same
/// 8-byte or 16-byte short-vector type), returned in `v0`..`v3` on `aarch64`.
///
/// Independent of the current compilation host architecture so unit tests on
/// any target can verify AAPCS64 HFA/HVA classification.
pub fn isAarch64HfaOrHva(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .@"struct", .@"union" => blk: {
            const info = aapcs64HomogeneousInfo(T) orelse break :blk false;
            break :blk info.count >= 1 and info.count <= 4 and info.base != void;
        },
        else => false,
    };
}

/// Reports whether C-ABI return type `Return` is returned indirectly via a
/// caller-allocated hidden buffer (`x8` on `aarch64`, `%rdi` `stret` on `x86_64`).
///
/// Objective-C's `objc_msgSend` (`aarch64`) and `objc_msgSend_stret` (`x86_64`)
/// do NOT zero caller-allocated indirect-return buffers when `receiver == nil`,
/// so `msgSend` / `msgSendVarargs` must zero-return manually on `nil` receivers.
pub fn usesIndirectReturn(comptime Return: type) bool {
    if (Return == void) return false;
    return comptime switch (builtin.target.cpu.arch) {
        .x86_64 => usesStret(Return),
        .aarch64 => switch (@typeInfo(Return)) {
            .vector => @sizeOf(Return) > 16,
            .@"struct", .@"union" => @sizeOf(Return) > 16 and !isAarch64HfaOrHva(Return),
            else => false,
        },
        else => @sizeOf(Return) > 2 * @sizeOf(usize),
    };
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
    try testing.expectEqual(
        !builtin.target.os.tag.isDarwin() and @sizeOf(c_longdouble) > 8,
        x86_64AggregateUsesStret(MixedLongDoubleIntUnion),
    );
    if (builtin.target.cpu.arch == .x86_64) {
        const MixedF80IntUnion = extern union { ld: f80, u: u64 };
        try testing.expectEqual(!builtin.target.os.tag.isDarwin(), x86_64AggregateUsesStret(MixedF80IntUnion));
        try testing.expect(!x86_64UsesFpret(MixedF80IntUnion));
    }

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

    // SIMD vectors and 128-bit float aggregates (Zig forbids @Vector fields inside
    // extern structs/unions; standalone @Vector and 16B f128 structs return in SSE/YMM/ZMM)
    const F128Struct = extern struct { v: f128 };
    const TwoF128Struct = extern struct { lo: f128, hi: f128 };
    try testing.expect(!x86_64AggregateUsesStret(@Vector(8, f32)));
    try testing.expect(!x86_64AggregateUsesStret(@Vector(16, f32)));
    try testing.expect(!x86_64AggregateUsesStretWithSimd(F128Struct, false, false));
    try testing.expect(x86_64AggregateUsesStretWithSimd(TwoF128Struct, false, false));
    try testing.expect(x86_64AggregateUsesStretWithSimd(TwoF128Struct, true, true));

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

test "AAPCS64 HFA/HVA and usesIndirectReturn classification" {
    const testing = std.testing;

    const NSPoint = extern struct { x: f64, y: f64 };
    const NSSize = extern struct { width: f64, height: f64 };
    const NSRect = extern struct { origin: NSPoint, size: NSSize };
    const CGAffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
    const BigInts = extern struct { a: u64, b: u64, c: u64, d: u64 };
    const Float3 = extern struct { arr: [3]f32 };
    const MixedFloat = extern struct { a: f32, b: f64 };
    const PaddedFloat3 = extern struct { a: f32 align(16), b: f32, c: f32 };
    const HfaUnion = extern union { vec: [4]f64, pair: NSPoint };
    const QuadPair = extern struct { lo: f128, hi: f128 };
    const QuadFive = extern struct { vals: [5]f128 };

    try testing.expect(isAarch64HfaOrHva(NSPoint));
    try testing.expect(isAarch64HfaOrHva(NSRect));
    try testing.expect(isAarch64HfaOrHva(Float3));
    try testing.expect(isAarch64HfaOrHva(HfaUnion));
    try testing.expect(isAarch64HfaOrHva(QuadPair));
    try testing.expect(!isAarch64HfaOrHva(QuadFive));
    try testing.expect(!isAarch64HfaOrHva(f64));
    try testing.expect(!isAarch64HfaOrHva(f128));
    try testing.expect(!isAarch64HfaOrHva(@Vector(4, f32)));
    try testing.expect(!isAarch64HfaOrHva(CGAffineTransform));
    try testing.expect(!isAarch64HfaOrHva(BigInts));
    try testing.expect(!isAarch64HfaOrHva(MixedFloat));
    try testing.expect(!isAarch64HfaOrHva(PaddedFloat3));

    try testing.expect(!usesIndirectReturn(void));
    try testing.expect(!usesIndirectReturn(u64));
    try testing.expect(!usesIndirectReturn(NSPoint));
    try testing.expect(usesIndirectReturn(CGAffineTransform));
    try testing.expect(usesIndirectReturn(BigInts));
    try testing.expect(usesIndirectReturn(QuadFive));

    if (builtin.target.cpu.arch == .aarch64) {
        try testing.expect(!usesIndirectReturn(NSRect));
        try testing.expect(!usesIndirectReturn(HfaUnion));
        try testing.expect(!usesIndirectReturn(QuadPair));
        try testing.expect(!usesIndirectReturn(@Vector(4, f32)));
        try testing.expect(usesIndirectReturn(@Vector(8, f32)));
    } else if (builtin.target.cpu.arch == .x86_64) {
        try testing.expect(usesIndirectReturn(NSRect));
        try testing.expect(usesIndirectReturn(HfaUnion));
        try testing.expect(usesIndirectReturn(QuadPair));
        try testing.expect(!usesIndirectReturn(@Vector(4, f32)));
        try testing.expect(!usesIndirectReturn(@Vector(8, f32)));
    }
}

test "weakExtern caches resolved and missing runtime symbols" {
    const testing = std.testing;

    const GetClassFn = *const fn ([*c]const u8) callconv(.c) c.Class;
    const p1 = weakExtern(GetClassFn, "objc_getClass");
    const p2 = weakExtern(?GetClassFn, "objc_getClass");
    const p3 = weakExtern(GetClassFn, "objc_getClass");
    try testing.expect(p1 != null);
    try testing.expectEqual(p1, p2);
    try testing.expectEqual(p1, p3);
    try testing.expect(p1.?("NSObject") != null);

    // Missing SDK declaration returns null without emitting undefined Mach-O reference.
    const missing1 = weakExtern(GetClassFn, "zig_objc_nonexistent_runtime_symbol");
    const missing2 = weakExtern(?GetClassFn, "zig_objc_nonexistent_runtime_symbol");
    try testing.expect(missing1 == null);
    try testing.expect(missing2 == null);
}
