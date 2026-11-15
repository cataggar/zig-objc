const std = @import("std");
const objc = @import("main.zig");
const c = @import("c.zig").c;
const assert = std.debug.assert;
const testing = std.testing;

/// how much space do we need to encode this type?
fn comptimeN(comptime T: type) usize {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Figure out how much space we need
        return std.fmt.count("{f}", .{encoding});
    }
}

/// Encode a type into a comptime string.
pub fn comptimeEncode(comptime T: type) [comptimeN(T):0]u8 {
    comptime {
        const encoding = objc.Encoding.init(T);

        // Build our final signature
        var buf: [comptimeN(T) + 1]u8 = undefined;
        const result = std.fmt.bufPrint(buf[0 .. buf.len - 1], "{f}", .{encoding}) catch unreachable;
        buf[result.len] = 0;

        return buf[0..result.len :0].*;
    }
}

/// Encoding union which parses type information and turns it into Obj-C
/// runtime Type Encodings.
///
/// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
pub const Encoding = union(enum) {
    char,
    int,
    short,
    long,
    longlong,
    int128,
    uchar,
    uint,
    ushort,
    ulong,
    ulonglong,
    uint128,
    float,
    double,
    longdouble,
    bool,
    void,
    char_string,
    object,
    block,
    class,
    selector,
    array: struct { arr_type: type, len: usize },
    structure: struct { struct_type: type, show_type_spec: bool },
    @"union": struct { union_type: type, show_type_spec: bool },
    bitfield: u32,
    pointer: struct { ptr_type: type, size: std.builtin.Type.Pointer.Size },
    function: std.builtin.Type.Fn,
    fn_pointer,
    vector: struct { elem_type: type, size: usize, alignment: usize },
    unknown,

    pub fn init(comptime T: type) Encoding {
        return switch (T) {
            i8, c_char => .char,
            i16, c_short => .short,
            i32, c_int => .int,
            c_long => .long,
            i64, c_longlong => .longlong,
            isize => if (@sizeOf(isize) == 8) .longlong else .int,
            i128 => .int128,
            u8 => .uchar,
            u16, c_ushort => .ushort,
            u32, c_uint => .uint,
            c_ulong => .ulong,
            u64, c_ulonglong => .ulonglong,
            usize => if (@sizeOf(usize) == 8) .ulonglong else .uint,
            u128 => .uint128,
            f32 => .float,
            f64 => .double,
            f80, c_longdouble => .longdouble,
            bool => .bool,
            void, anyopaque => .void,
            [*c]u8, [*c]const u8, [*:0]u8, [*:0]const u8 => .char_string,
            c.SEL, objc.Sel, ?objc.Sel => .selector,
            c.Class, objc.Class, ?objc.Class => .class,
            c.id,
            objc.Object,
            ?objc.Object,
            objc.Protocol,
            ?objc.Protocol,
            *c.Protocol,
            *const c.Protocol,
            ?*c.Protocol,
            ?*const c.Protocol,
            => .object,
            objc.Property, ?objc.Property => .init(c.objc_property_t),
            objc.Ivar, ?objc.Ivar => .init(c.Ivar),
            objc.Method, ?objc.Method => .init(c.Method),
            else => switch (@typeInfo(T)) {
                .@"opaque" => .void,
                .@"enum" => |m| .init(m.tag_type),
                .array => |arr| .{ .array = .{ .len = arr.len, .arr_type = arr.child } },
                .vector => |vec| .{ .vector = .{
                    .elem_type = vec.child,
                    .size = @sizeOf(T),
                    .alignment = @alignOf(T),
                } },
                .@"struct" => |m| if (@hasDecl(T, "is_objc_block"))
                    .block
                else switch (m.layout) {
                    .@"packed" => .init(m.backing_integer.?),
                    else => .{ .structure = .{ .struct_type = T, .show_type_spec = true } },
                },
                .@"union" => .{ .@"union" = .{
                    .union_type = T,
                    .show_type_spec = true,
                } },
                .optional => |m| switch (@typeInfo(m.child)) {
                    .@"struct" => if (@hasDecl(m.child, "is_objc_block"))
                        .block
                    else
                        @compileError("unsupported non-pointer optional type: " ++ @typeName(T)),
                    .pointer => .init(m.child),
                    else => @compileError("unsupported non-pointer optional type: " ++ @typeName(T)),
                },
                .pointer => |ptr| switch (ptr.size) {
                    .one, .c => if (@typeInfo(ptr.child) == .@"fn")
                        .fn_pointer
                    else if (isBlockContextStruct(ptr.child))
                        .block
                    else
                        .{ .pointer = .{ .ptr_type = T, .size = ptr.size } },
                    .many => .{ .pointer = .{ .ptr_type = T, .size = ptr.size } },
                    .slice => @compileError("Pointer size not supported for encoding"),
                },
                .@"fn" => |fn_info| .{ .function = fn_info },
                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }

    pub fn format(
        comptime self: Encoding,
        writer: anytype,
    ) !void {
        switch (self) {
            .char => try writer.writeAll("c"),
            .int => try writer.writeAll("i"),
            .short => try writer.writeAll("s"),
            .long => try writer.writeAll("l"),
            .longlong => try writer.writeAll("q"),
            .int128 => try writer.writeAll("t"),
            .uchar => try writer.writeAll("C"),
            .uint => try writer.writeAll("I"),
            .ushort => try writer.writeAll("S"),
            .ulong => try writer.writeAll("L"),
            .ulonglong => try writer.writeAll("Q"),
            .uint128 => try writer.writeAll("T"),
            .float => try writer.writeAll("f"),
            .double => try writer.writeAll("d"),
            .longdouble => try writer.writeAll("D"),
            .bool => try writer.writeAll("B"),
            .void => try writer.writeAll("v"),
            .char_string => try writer.writeAll("*"),
            .object => try writer.writeAll("@"),
            .block => try writer.writeAll("@?"),
            .class => try writer.writeAll("#"),
            .selector => try writer.writeAll(":"),
            .fn_pointer => try writer.writeAll("^?"),
            .array => |a| {
                try writer.print("[{}", .{a.len});
                const encode_type = init(a.arr_type);
                try encode_type.format(writer);
                try writer.writeAll("]");
            },
            .vector => |v| {
                try writer.print("![{},{}", .{ v.size, v.alignment });
                const elem_enc = init(v.elem_type);
                try elem_enc.format(writer);
                try writer.writeAll("]");
            },
            .structure => |s| {
                const struct_info = @typeInfo(s.struct_type);
                assert(struct_info.@"struct".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Struct in an encoding.
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(s.struct_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("{{{s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the struct (determined by levels of pointer indirection)
                if (s.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (struct_info.@"struct".field_types) |field_type| {
                        const field_encode = init(field_type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll("}");
            },
            .@"union" => |u| {
                const union_info = @typeInfo(u.union_type);
                assert(union_info.@"union".layout == .@"extern");

                // Strips the fully qualified type name to leave just the
                // type name. Used in naming the Union in an encoding
                var type_name_iter = std.mem.splitBackwardsScalar(u8, @typeName(u.union_type), '.');
                const type_name = type_name_iter.first();
                try writer.print("({s}", .{type_name});

                // if the encoding should show the internal type specification
                // of the Union (determined by levels of pointer indirection)
                if (u.show_type_spec) {
                    try writer.writeAll("=");
                    inline for (union_info.@"union".field_types) |field_type| {
                        const field_encode = init(field_type);
                        try field_encode.format(writer);
                    }
                }

                try writer.writeAll(")");
            },
            .bitfield => |b| try writer.print("b{}", .{b}),
            .pointer => |p| {
                switch (p.size) {
                    .one, .many, .c => {
                        const pointer_info = indirectionCountAndType(p.ptr_type);
                        for (0..pointer_info.indirection_levels) |_| {
                            try writer.writeAll("^");
                        }

                        comptime var encoding = init(pointer_info.child);

                        // Non-extern Zig structs/unions have no C field layout, so behind a
                        // pointer (`*MyZigState`) they encode as opaque `^v` (`void *`).
                        switch (encoding) {
                            .structure => |s| if (@typeInfo(s.struct_type).@"struct".layout != .@"extern") {
                                encoding = .void;
                            },
                            .@"union" => |u| if (@typeInfo(u.union_type).@"union".layout != .@"extern") {
                                encoding = .void;
                            },
                            else => {},
                        }

                        // if the indirection levels are greater than 1, for
                        // certain types that means getting rid of its
                        // internal type specification
                        //
                        // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html#//apple_ref/doc/uid/TP40008048-CH100
                        if (pointer_info.indirection_levels > 1) {
                            switch (encoding) {
                                .structure => |*s| s.show_type_spec = false,
                                .@"union" => |*u| u.show_type_spec = false,
                                else => {},
                            }
                        }

                        try encoding.format(writer);
                    },
                    .slice => @compileError("Pointer size not supported for encoding"),
                }
            },
            .function => |fn_info| {
                assert(std.meta.eql(fn_info.attrs.@"callconv", std.builtin.CallingConvention.c));

                // Return type is first in a method encoding
                const ret_type_enc = init(fn_info.return_type.?);
                try ret_type_enc.format(writer);
                inline for (fn_info.param_types) |param_type| {
                    const param_enc = init(param_type.?);
                    try param_enc.format(writer);
                }
            },
            .unknown => try writer.writeAll("?"),
        }
    }
};

fn isBlockContextStruct(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "is_objc_block_context")) return true;
    const info = @typeInfo(T).@"struct";
    if (info.field_names.len < 5) return false;
    return std.mem.eql(u8, info.field_names[0], "isa") and
        std.mem.eql(u8, info.field_names[1], "flags") and
        std.mem.eql(u8, info.field_names[2], "reserved") and
        std.mem.eql(u8, info.field_names[3], "invoke") and
        std.mem.eql(u8, info.field_names[4], "descriptor");
}

fn isDirectEncodedType(comptime T: type) bool {
    return switch (T) {
        c.id,
        objc.Object,
        ?objc.Object,
        c.Class,
        objc.Class,
        ?objc.Class,
        c.SEL,
        objc.Sel,
        ?objc.Sel,
        objc.Protocol,
        ?objc.Protocol,
        *c.Protocol,
        *const c.Protocol,
        ?*c.Protocol,
        ?*const c.Protocol,
        [*c]u8,
        [*c]const u8,
        [*:0]u8,
        [*:0]const u8,
        => true,
        else => switch (@typeInfo(T)) {
            .@"struct" => @hasDecl(T, "is_objc_block"),
            .optional => |opt| isDirectEncodedType(opt.child),
            .pointer => |ptr| switch (ptr.size) {
                .one, .c => @typeInfo(ptr.child) == .@"fn" or isBlockContextStruct(ptr.child),
                else => false,
            },
            else => false,
        },
    };
}

/// Computes pointer indirection depth until reaching either a non-pointer type
/// or a pointer type with its own dedicated Objective-C encoding (`@`, `#`, `:`, `*`, `@?`, `^?`).
fn indirectionCountAndType(comptime T: type) struct {
    child: type,
    indirection_levels: comptime_int,
} {
    var WalkType = T;
    var count: usize = 0;
    while (!isDirectEncodedType(WalkType)) {
        switch (@typeInfo(WalkType)) {
            .pointer => |ptr| {
                if (ptr.size == .slice) @compileError("Pointer size not supported for encoding");
                count += 1;
                WalkType = ptr.child;
            },
            .optional => |opt| {
                if (@typeInfo(opt.child) != .pointer) break;
                WalkType = opt.child;
            },
            else => break,
        }
    }

    return .{ .child = WalkType, .indirection_levels = count };
}

// ============================================================================
// Runtime Objective-C Type-Encoding Parser / Decoder
// ============================================================================

pub const ParseError = error{
    EmptyEncoding,
    UnexpectedEndOfInput,
    InvalidTypeEncoding,
    InvalidNumber,
    UnclosedDelimiter,
    TrailingCharacters,
};

/// Objective-C runtime type qualifiers (`<objc/runtime.h>`).
pub const Qualifiers = packed struct {
    @"const": bool = false, // 'r' (_C_CONST)
    in: bool = false, // 'n' (_C_IN)
    inout: bool = false, // 'N' (_C_INOUT)
    out: bool = false, // 'o' (_C_OUT)
    bycopy: bool = false, // 'O' (_C_BYCOPY)
    byref: bool = false, // 'R' (_C_BYREF)
    oneway: bool = false, // 'V' (_C_ONEWAY)
    atomic: bool = false, // 'A' (_C_ATOMIC)
    complex: bool = false, // 'j' (_C_COMPLEX)

    pub fn hasAny(self: Qualifiers) bool {
        const Int = @typeInfo(Qualifiers).@"struct".backing_integer.?;
        return @as(Int, @bitCast(self)) != 0;
    }

    pub fn parse(enc: []const u8) struct { qualifiers: Qualifiers, rest: []const u8 } {
        var quals: Qualifiers = .{};
        var idx: usize = 0;
        while (idx < enc.len) : (idx += 1) {
            switch (enc[idx]) {
                'r' => quals.@"const" = true,
                'n' => quals.in = true,
                'N' => quals.inout = true,
                'o' => quals.out = true,
                'O' => quals.bycopy = true,
                'R' => quals.byref = true,
                'V' => quals.oneway = true,
                'A' => quals.atomic = true,
                'j' => quals.complex = true,
                else => break,
            }
        }
        return .{ .qualifiers = quals, .rest = enc[idx..] };
    }
};

/// A zero-allocation parsed Objective-C runtime type descriptor.
pub const ParsedType = struct {
    qualifiers: Qualifiers = .{},
    kind: Kind,
    /// Exact slice of the input corresponding to this type (including qualifiers).
    raw: []const u8,

    pub const Array = struct {
        len: usize,
        elem_encoding: []const u8,

        pub fn elemType(self: Array) ParseError!ParsedType {
            return parseType(self.elem_encoding);
        }
    };

    pub const Vector = struct {
        size: usize,
        alignment: usize,
        elem_encoding: []const u8,

        pub fn elemType(self: Vector) ParseError!ParsedType {
            return parseType(self.elem_encoding);
        }
    };

    pub const Field = struct {
        name: ?[]const u8,
        ty: ParsedType,
    };

    pub const FieldIterator = struct {
        rest: []const u8,

        pub fn next(self: *FieldIterator) ParseError!?Field {
            if (self.rest.len == 0) return null;

            var cur = self.rest;
            var field_name: ?[]const u8 = null;
            if (cur[0] == '"') {
                const close = std.mem.indexOfScalarPos(u8, cur, 1, '"') orelse
                    return error.UnclosedDelimiter;
                const name_slice = cur[1..close];
                field_name = if (name_slice.len == 0) null else name_slice;
                cur = cur[close + 1 ..];
            }

            const parsed_field = try parseTypePrefix(cur);
            self.rest = parsed_field.rest;
            return .{
                .name = field_name,
                .ty = parsed_field.parsed,
            };
        }
    };

    pub const Aggregate = struct {
        /// Tag name, or `null` when anonymous (`?` or empty).
        name: ?[]const u8,
        /// Encoded field sequence following `=`, or `null` when opaque (`{Foo}`).
        fields_encoding: ?[]const u8,

        pub fn fieldIterator(self: Aggregate) ?FieldIterator {
            const fields = self.fields_encoding orelse return null;
            return .{ .rest = fields };
        }
    };

    pub const Kind = union(enum) {
        char, // 'c'
        int, // 'i'
        short, // 's'
        long, // 'l'
        longlong, // 'q'
        int128, // 't'
        uchar, // 'C'
        uint, // 'I'
        ushort, // 'S'
        ulong, // 'L'
        ulonglong, // 'Q'
        uint128, // 'T'
        float, // 'f'
        double, // 'd'
        longdouble, // 'D'
        bool, // 'B'
        void, // 'v'
        char_string, // '*'
        atom, // '%'
        object: ?[]const u8, // '@' -> null, '@"NSString"' -> "NSString"
        block: ?[]const u8, // '@?' -> null, '@?<...>' -> "..."
        class, // '#'
        selector, // ':'
        array: Array, // '[Ntype]'
        structure: Aggregate, // '{name=fields...}'
        @"union": Aggregate, // '(name=fields...)'
        bitfield: u32, // 'bN'
        pointer: []const u8, // '^type'
        fn_pointer, // '^?'
        vector: Vector, // '![size,align<elem>]'
        unknown, // '?'
    };

    /// Parses the pointee type when `self.kind == .pointer`, or returns `null` otherwise.
    pub fn pointeeType(self: ParsedType) ParseError!?ParsedType {
        return switch (self.kind) {
            .pointer => |inner| try parseType(inner),
            else => null,
        };
    }
};

/// Parses a single complete Objective-C runtime type encoding string.
/// Returns `error.TrailingCharacters` if `enc` contains unconsumed trailing bytes.
pub fn parseType(enc: []const u8) ParseError!ParsedType {
    const res = try parseTypePrefix(enc);
    if (res.rest.len != 0) return error.TrailingCharacters;
    return res.parsed;
}

/// Parses a single Objective-C type descriptor from the front of `enc`, returning
/// both the parsed descriptor and the remaining unconsumed slice.
pub fn parseTypePrefix(enc: []const u8) ParseError!struct { parsed: ParsedType, rest: []const u8 } {
    if (enc.len == 0) return error.EmptyEncoding;

    const qual_res = Qualifiers.parse(enc);
    const quals = qual_res.qualifiers;
    var idx: usize = enc.len - qual_res.rest.len;
    if (idx >= enc.len) return error.UnexpectedEndOfInput;

    const kind: ParsedType.Kind = switch (enc[idx]) {
        'c' => blk: {
            idx += 1;
            break :blk .char;
        },
        'i' => blk: {
            idx += 1;
            break :blk .int;
        },
        's' => blk: {
            idx += 1;
            break :blk .short;
        },
        'l' => blk: {
            idx += 1;
            break :blk .long;
        },
        'q' => blk: {
            idx += 1;
            break :blk .longlong;
        },
        't' => blk: {
            idx += 1;
            break :blk .int128;
        },
        'C' => blk: {
            idx += 1;
            break :blk .uchar;
        },
        'I' => blk: {
            idx += 1;
            break :blk .uint;
        },
        'S' => blk: {
            idx += 1;
            break :blk .ushort;
        },
        'L' => blk: {
            idx += 1;
            break :blk .ulong;
        },
        'Q' => blk: {
            idx += 1;
            break :blk .ulonglong;
        },
        'T' => blk: {
            idx += 1;
            break :blk .uint128;
        },
        'f' => blk: {
            idx += 1;
            break :blk .float;
        },
        'd' => blk: {
            idx += 1;
            break :blk .double;
        },
        'D' => blk: {
            idx += 1;
            break :blk .longdouble;
        },
        'B' => blk: {
            idx += 1;
            break :blk .bool;
        },
        'v' => blk: {
            idx += 1;
            break :blk .void;
        },
        '*' => blk: {
            idx += 1;
            break :blk .char_string;
        },
        '%' => blk: {
            idx += 1;
            break :blk .atom;
        },
        '#' => blk: {
            idx += 1;
            break :blk .class;
        },
        ':' => blk: {
            idx += 1;
            break :blk .selector;
        },
        '?' => blk: {
            idx += 1;
            break :blk .unknown;
        },
        '@' => blk: {
            idx += 1;
            if (idx < enc.len and enc[idx] == '?') {
                idx += 1;
                if (idx < enc.len and enc[idx] == '<') {
                    const sig_start = idx + 1;
                    var depth: usize = 1;
                    idx += 1;
                    while (idx < enc.len and depth > 0) : (idx += 1) {
                        if (enc[idx] == '"') {
                            const close_q = std.mem.indexOfScalarPos(u8, enc, idx + 1, '"') orelse
                                return error.UnclosedDelimiter;
                            idx = close_q;
                        } else if (enc[idx] == '<') {
                            depth += 1;
                        } else if (enc[idx] == '>') {
                            depth -= 1;
                        }
                    }
                    if (depth != 0) return error.UnclosedDelimiter;
                    break :blk .{ .block = enc[sig_start .. idx - 1] };
                } else if (idx < enc.len and enc[idx] == '"') {
                    const close_q = std.mem.indexOfScalarPos(u8, enc, idx + 1, '"') orelse
                        return error.UnclosedDelimiter;
                    const sig = enc[idx + 1 .. close_q];
                    idx = close_q + 1;
                    break :blk .{ .block = sig };
                }
                break :blk .{ .block = null };
            } else if (idx < enc.len and enc[idx] == '"') {
                const close_q = std.mem.indexOfScalarPos(u8, enc, idx + 1, '"') orelse
                    return error.UnclosedDelimiter;
                const class_name = enc[idx + 1 .. close_q];
                idx = close_q + 1;
                break :blk .{ .object = class_name };
            }
            break :blk .{ .object = null };
        },
        'b' => blk: {
            idx += 1;
            const num = try parseUintPrefix(u32, enc[idx..]);
            idx += num.consumed;
            break :blk .{ .bitfield = num.value };
        },
        '^' => blk: {
            idx += 1;
            if (idx >= enc.len) return error.UnexpectedEndOfInput;
            if (enc[idx] == '?') {
                idx += 1;
                break :blk .fn_pointer;
            }
            const sub = try parseTypePrefix(enc[idx..]);
            idx += sub.parsed.raw.len;
            break :blk .{ .pointer = sub.parsed.raw };
        },
        '[' => blk: {
            idx += 1;
            const len_res = try parseUintPrefix(usize, enc[idx..]);
            idx += len_res.consumed;
            if (idx >= enc.len) return error.UnclosedDelimiter;
            const elem_res = try parseTypePrefix(enc[idx..]);
            idx += elem_res.parsed.raw.len;
            if (idx >= enc.len or enc[idx] != ']') return error.UnclosedDelimiter;
            idx += 1;
            break :blk .{ .array = .{
                .len = len_res.value,
                .elem_encoding = elem_res.parsed.raw,
            } };
        },
        '{', '(' => blk: {
            const open_ch = enc[idx];
            const close_ch: u8 = if (open_ch == '{') '}' else ')';
            idx += 1;

            const name_start = idx;
            var angle_depth: usize = 0;
            while (idx < enc.len) : (idx += 1) {
                const ch = enc[idx];
                if (ch == '<') {
                    angle_depth += 1;
                } else if (ch == '>' and angle_depth > 0) {
                    angle_depth -= 1;
                } else if (angle_depth == 0 and (ch == '=' or ch == close_ch)) {
                    break;
                } else if (angle_depth == 0 and ch == open_ch) {
                    return error.InvalidTypeEncoding;
                }
            }
            if (idx >= enc.len) return error.UnclosedDelimiter;

            const raw_name = enc[name_start..idx];
            const tag_name: ?[]const u8 = if (raw_name.len == 0 or std.mem.eql(u8, raw_name, "?"))
                null
            else
                raw_name;

            if (enc[idx] == close_ch) {
                idx += 1;
                const agg: ParsedType.Aggregate = .{
                    .name = tag_name,
                    .fields_encoding = null,
                };
                break :blk if (open_ch == '{') .{ .structure = agg } else .{ .@"union" = agg };
            }

            // Consume '=' and validate all member fields until matching close_ch.
            assert(enc[idx] == '=');
            idx += 1;
            const fields_start = idx;
            while (idx < enc.len and enc[idx] != close_ch) {
                if (enc[idx] == '"') {
                    const close_q = std.mem.indexOfScalarPos(u8, enc, idx + 1, '"') orelse
                        return error.UnclosedDelimiter;
                    idx = close_q + 1;
                }
                if (idx >= enc.len or enc[idx] == close_ch) return error.UnexpectedEndOfInput;
                const field_res = try parseTypePrefix(enc[idx..]);
                idx += field_res.parsed.raw.len;
            }
            if (idx >= enc.len or enc[idx] != close_ch) return error.UnclosedDelimiter;
            const fields_slice = enc[fields_start..idx];
            idx += 1;

            const agg: ParsedType.Aggregate = .{
                .name = tag_name,
                .fields_encoding = fields_slice,
            };
            break :blk if (open_ch == '{') .{ .structure = agg } else .{ .@"union" = agg };
        },
        '!' => blk: {
            idx += 1;
            if (idx >= enc.len or enc[idx] != '[') return error.InvalidTypeEncoding;
            idx += 1;

            const size_res = try parseUintPrefix(usize, enc[idx..]);
            idx += size_res.consumed;
            if (idx >= enc.len or enc[idx] != ',') return error.InvalidTypeEncoding;
            idx += 1;

            const align_res = try parseUintPrefix(usize, enc[idx..]);
            idx += align_res.consumed;
            if (idx < enc.len and enc[idx] == ',') idx += 1;

            if (idx >= enc.len) return error.UnclosedDelimiter;
            const elem_res = try parseTypePrefix(enc[idx..]);
            idx += elem_res.parsed.raw.len;
            if (idx >= enc.len or enc[idx] != ']') return error.UnclosedDelimiter;
            idx += 1;

            break :blk .{ .vector = .{
                .size = size_res.value,
                .alignment = align_res.value,
                .elem_encoding = elem_res.parsed.raw,
            } };
        },
        else => return error.InvalidTypeEncoding,
    };

    return .{
        .parsed = .{
            .qualifiers = quals,
            .kind = kind,
            .raw = enc[0..idx],
        },
        .rest = enc[idx..],
    };
}

fn parseUintPrefix(comptime T: type, slice: []const u8) ParseError!struct { value: T, consumed: usize } {
    var end: usize = 0;
    while (end < slice.len and std.ascii.isDigit(slice[end])) : (end += 1) {}
    if (end == 0) return error.InvalidNumber;
    const val = std.fmt.parseInt(T, slice[0..end], 10) catch return error.InvalidNumber;
    return .{ .value = val, .consumed = end };
}

fn parseOptionalFrameSize(slice: []const u8) ParseError!struct { size: ?usize, rest: []const u8 } {
    if (slice.len == 0 or !std.ascii.isDigit(slice[0])) {
        return .{ .size = null, .rest = slice };
    }
    const res = try parseUintPrefix(usize, slice);
    return .{ .size = res.value, .rest = slice[res.consumed..] };
}

fn parseOptionalOffset(slice: []const u8) ParseError!struct { offset: ?isize, is_register: bool, rest: []const u8 } {
    if (slice.len == 0) return .{ .offset = null, .is_register = false, .rest = slice };

    var idx: usize = 0;
    var is_register = false;
    var negative = false;

    if (slice[idx] == '+') {
        is_register = true;
        idx += 1;
    }
    if (idx < slice.len and slice[idx] == '-') {
        negative = true;
        idx += 1;
    }

    if (idx >= slice.len or !std.ascii.isDigit(slice[idx])) {
        if (is_register or negative) return error.InvalidNumber;
        return .{ .offset = null, .is_register = false, .rest = slice };
    }

    const mag = try parseUintPrefix(usize, slice[idx..]);
    idx += mag.consumed;

    const signed_mag = std.math.cast(isize, mag.value) orelse return error.InvalidNumber;
    const offset: isize = if (negative) -signed_mag else signed_mag;
    return .{
        .offset = offset,
        .is_register = is_register,
        .rest = slice[idx..],
    };
}

/// Iterates over an Objective-C method or block type signature (such as `"v24@0:8@16"`,
/// `"@\"NSString\"16@0:8"`, or `"v@:c"`), yielding the parsed return type, optional
/// stack/register frame size, and each parameter's type descriptor and byte/register offset.
pub const MethodTypeIterator = struct {
    return_type: ParsedType,
    frame_size: ?usize,
    rest: []const u8,

    pub const Param = struct {
        ty: ParsedType,
        offset: ?isize,
        is_register: bool = false,
    };

    pub fn init(signature: []const u8) ParseError!MethodTypeIterator {
        const ret = try parseTypePrefix(signature);
        const frame = try parseOptionalFrameSize(ret.rest);
        return .{
            .return_type = ret.parsed,
            .frame_size = frame.size,
            .rest = frame.rest,
        };
    }

    pub fn next(self: *MethodTypeIterator) ParseError!?Param {
        if (self.rest.len == 0) return null;
        const part = try parseTypePrefix(self.rest);
        const off = try parseOptionalOffset(part.rest);
        self.rest = off.rest;
        return .{
            .ty = part.parsed,
            .offset = off.offset,
            .is_register = off.is_register,
        };
    }
};

fn encodingMatchesType(comptime T: type, expected_encoding: []const u8) !void {
    var buf: [200]u8 = undefined;
    const enc = Encoding.init(T);
    const enc_string = try std.fmt.bufPrint(&buf, "{f}", .{enc});
    try testing.expectEqualStrings(expected_encoding, enc_string);
}

test "i8 to Encoding.char encoding" {
    try encodingMatchesType(i8, "c");
}

test "c_char to Encoding.char encoding" {
    try encodingMatchesType(c_char, "c");
}

test "c_short to Encoding.short encoding" {
    try encodingMatchesType(c_short, "s");
}

test "c_int to Encoding.int encoding" {
    try encodingMatchesType(c_int, "i");
}

test "c_long to Encoding.long encoding" {
    try encodingMatchesType(c_long, "l");
}

test "c_longlong to Encoding.longlong encoding" {
    try encodingMatchesType(c_longlong, "q");
}

test "u8 to Encoding.uchar encoding" {
    try encodingMatchesType(u8, "C");
}

test "c_ushort to Encoding.ushort encoding" {
    try encodingMatchesType(c_ushort, "S");
}

test "c_uint to Encoding.uint encoding" {
    try encodingMatchesType(c_uint, "I");
}

test "c_ulong to Encoding.ulong encoding" {
    try encodingMatchesType(c_ulong, "L");
}

test "c_ulonglong to Encoding.ulonglong encoding" {
    try encodingMatchesType(c_ulonglong, "Q");
}

test "f32 to Encoding.float encoding" {
    try encodingMatchesType(f32, "f");
}

test "f64 to Encoding.double encoding" {
    try encodingMatchesType(f64, "d");
}

test "[4]i8 to Encoding.array encoding" {
    try encodingMatchesType([4]i8, "[4c]");
}

test "*u8 to Encoding.pointer encoding" {
    try encodingMatchesType(*u8, "^C");
}

test "**u8 to Encoding.pointer encoding" {
    try encodingMatchesType(**u8, "^^C");
}

test "?*u8 to Encoding.pointer encoding" {
    try encodingMatchesType(?*u8, "^C");
}

test "Enum(c_uint) to Encoding.uint encoding" {
    const TestEnum = enum(c_uint) { a };
    try encodingMatchesType(TestEnum, "I");
}

test "TestPackedStruct to Encoding.uint encoding" {
    const TestPackedStruct = packed struct(u32) {
        _: u32,
    };
    try encodingMatchesType(TestPackedStruct, "I");
}

test "*TestStruct to Encoding.pointer encoding" {
    const TestStruct = extern struct {
        float: f32,
        char: u8,
    };
    try encodingMatchesType(*TestStruct, "^{TestStruct=fC}");
}

test "**TestStruct to Encoding.pointer encoding" {
    const TestStruct = extern struct {
        float: f32,
        char: u8,
    };
    try encodingMatchesType(**TestStruct, "^^{TestStruct}");
}

test "*TestStruct with 2 level indirection NestedStruct to Encoding.pointer encoding" {
    const NestedStruct = extern struct {
        char: i8,
    };
    const TestStruct = extern struct {
        float: f32,
        char: u8,
        nested: **NestedStruct,
    };
    try encodingMatchesType(*TestStruct, "^{TestStruct=fC^^{NestedStruct}}");
}

test "*TestOpaque to Encoding.pointer encoding" {
    const TestOpaque = opaque {};
    try encodingMatchesType(*TestOpaque, "^v");
}

test "?*TestOpaque to Encoding.pointer encoding" {
    const TestOpaque = opaque {};
    try encodingMatchesType(?*TestOpaque, "^v");
}

test "Property, Ivar, and Method wrapper encodings" {
    try encodingMatchesType(objc.Property, "^v");
    try encodingMatchesType(?objc.Property, "^v");
    try encodingMatchesType(objc.Ivar, "^v");
    try encodingMatchesType(?objc.Ivar, "^v");
    try encodingMatchesType(objc.Method, "^v");
    try encodingMatchesType(?objc.Method, "^v");

    const ZigAutoState = struct {
        count: usize,
        label: []const u8,
    };
    try encodingMatchesType(*ZigAutoState, "^v");
    try encodingMatchesType(?*ZigAutoState, "^v");
}

test "Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(TestUnion, "(TestUnion=isl)");
}

test "*Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(*TestUnion, "^(TestUnion=isl)");
}

test "**Union to Encoding.union encoding" {
    const TestUnion = extern union {
        int: c_int,
        short: c_short,
        long: c_long,
    };
    try encodingMatchesType(**TestUnion, "^^(TestUnion)");
}

test "Fn to Encoding.function encoding" {
    const test_fn = struct {
        fn add(_: c.id, _: c.SEL, _: i8) callconv(.c) void {}
    };

    try encodingMatchesType(@TypeOf(test_fn.add), "v@:c");
}

test "comptime encodings for NSInteger, 128-bit ints, long double, fn pointers, blocks, optionals, and vectors" {
    try encodingMatchesType(isize, if (@sizeOf(isize) == 8) "q" else "i");
    try encodingMatchesType(usize, if (@sizeOf(usize) == 8) "Q" else "I");
    try encodingMatchesType(objc.NSInteger, if (@sizeOf(isize) == 8) "q" else "i");
    try encodingMatchesType(objc.NSUInteger, if (@sizeOf(usize) == 8) "Q" else "I");
    try encodingMatchesType(i16, "s");
    try encodingMatchesType(u16, "S");
    try encodingMatchesType(i128, "t");
    try encodingMatchesType(u128, "T");
    try encodingMatchesType(c_longdouble, "D");

    // Function pointers (`^?`) and pointer-to-fn-pointer (`^^?`)
    const FnPtr = *const fn (c_int, f64) callconv(.c) void;
    try encodingMatchesType(FnPtr, "^?");
    try encodingMatchesType(?FnPtr, "^?");
    try encodingMatchesType(c.IMP, "^?");
    try encodingMatchesType(*FnPtr, "^^?");

    // Block context pointers (`@?`) via both field shape (`objc.Block`) and marker decl
    const SampleBlock = objc.Block(struct { x: i32 }, .{i32}, i32);
    try encodingMatchesType(*SampleBlock.Context, "@?");
    try encodingMatchesType(*const SampleBlock.Context, "@?");
    try encodingMatchesType(?*SampleBlock.Context, "@?");
    try encodingMatchesType(?*const SampleBlock.Context, "@?");
    try encodingMatchesType(**SampleBlock.Context, "^@?");

    const MarkedBlockCtx = extern struct {
        pub const is_objc_block_context = true;
        ptr: ?*anyopaque,
    };
    try encodingMatchesType(*MarkedBlockCtx, "@?");
    try encodingMatchesType(?*MarkedBlockCtx, "@?");

    // Optional and non-optional Objective-C wrappers
    try encodingMatchesType(objc.Object, "@");
    try encodingMatchesType(?objc.Object, "@");
    try encodingMatchesType(*objc.Object, "^@");
    try encodingMatchesType(*?objc.Object, "^@");
    try encodingMatchesType(objc.Class, "#");
    try encodingMatchesType(?objc.Class, "#");
    try encodingMatchesType(objc.Protocol, "@");
    try encodingMatchesType(?objc.Protocol, "@");
    try encodingMatchesType(*c.Protocol, "@");
    try encodingMatchesType(?*c.Protocol, "@");
    try encodingMatchesType(objc.Sel, ":");
    try encodingMatchesType(?objc.Sel, ":");
    try encodingMatchesType([*:0]const u8, "*");
    try encodingMatchesType(?[*:0]const u8, "*");

    // SIMD @Vector
    try encodingMatchesType(@Vector(4, f32), "![16,16f]");
    try encodingMatchesType(@Vector(2, f64), "![16,16d]");
}

test "runtime type-encoding parser: qualifiers, primitives, objects, blocks, aggregates, pointers, vectors" {
    // Qualifiers
    const q = try parseType("rnNoORVAj*");
    try testing.expect(q.qualifiers.hasAny());
    try testing.expect(q.qualifiers.@"const");
    try testing.expect(q.qualifiers.in);
    try testing.expect(q.qualifiers.inout);
    try testing.expect(q.qualifiers.out);
    try testing.expect(q.qualifiers.bycopy);
    try testing.expect(q.qualifiers.byref);
    try testing.expect(q.qualifiers.oneway);
    try testing.expect(q.qualifiers.atomic);
    try testing.expect(q.qualifiers.complex);
    try testing.expectEqual(ParsedType.Kind.char_string, q.kind);

    // Primitives
    try testing.expectEqual(ParsedType.Kind.int128, (try parseType("t")).kind);
    try testing.expectEqual(ParsedType.Kind.uint128, (try parseType("T")).kind);
    try testing.expectEqual(ParsedType.Kind.longdouble, (try parseType("D")).kind);
    try testing.expectEqual(ParsedType.Kind.bool, (try parseType("B")).kind);
    try testing.expectEqual(ParsedType.Kind.void, (try parseType("v")).kind);
    try testing.expectEqual(ParsedType.Kind.class, (try parseType("#")).kind);
    try testing.expectEqual(ParsedType.Kind.selector, (try parseType(":")).kind);
    try testing.expectEqual(ParsedType.Kind.unknown, (try parseType("?")).kind);
    try testing.expectEqual(@as(u32, 8), (try parseType("b8")).kind.bitfield);

    // Objects & blocks
    const plain_obj = try parseType("@");
    try testing.expect(plain_obj.kind.object == null);

    const named_obj = try parseType("@\"NSString\"");
    try testing.expectEqualStrings("NSString", named_obj.kind.object.?);

    const plain_blk = try parseType("@?");
    try testing.expect(plain_blk.kind.block == null);

    const ext_blk = try parseType("@?<v@?@\"NSString\">");
    try testing.expectEqualStrings("v@?@\"NSString\"", ext_blk.kind.block.?);

    // Pointers & fn pointers
    try testing.expectEqual(ParsedType.Kind.fn_pointer, (try parseType("^?")).kind);
    const dbl_fn_ptr = try parseType("^^?");
    try testing.expectEqual(ParsedType.Kind.fn_pointer, (try dbl_fn_ptr.pointeeType()).?.kind);

    const const_void_ptr = try parseType("r^v");
    try testing.expect(const_void_ptr.qualifiers.@"const");
    try testing.expectEqual(ParsedType.Kind.void, (try const_void_ptr.pointeeType()).?.kind);

    // Array
    const arr = try parseType("[8S]");
    try testing.expectEqual(@as(usize, 8), arr.kind.array.len);
    try testing.expectEqual(ParsedType.Kind.ushort, (try arr.kind.array.elemType()).kind);

    // Struct with named fields & nested structs (AppKit ivar format)
    const rect = try parseType("{CGRect=\"origin\"{CGPoint=\"x\"d\"y\"d}\"size\"{CGSize=\"width\"d\"height\"d}}");
    try testing.expectEqualStrings("CGRect", rect.kind.structure.name.?);
    var fields = rect.kind.structure.fieldIterator().?;
    const f1 = (try fields.next()).?;
    try testing.expectEqualStrings("origin", f1.name.?);
    try testing.expectEqualStrings("CGPoint", f1.ty.kind.structure.name.?);
    const f2 = (try fields.next()).?;
    try testing.expectEqualStrings("size", f2.name.?);
    try testing.expectEqualStrings("CGSize", f2.ty.kind.structure.name.?);
    try testing.expect((try fields.next()) == null);

    // Opaque struct & anonymous struct with unnamed bitfield
    const opaque_struct = try parseType("{TestStruct}");
    try testing.expectEqualStrings("TestStruct", opaque_struct.kind.structure.name.?);
    try testing.expect(opaque_struct.kind.structure.fields_encoding == null);

    const anon_struct = try parseType("{?=\"a\"b1\"\"b5}");
    try testing.expect(anon_struct.kind.structure.name == null);
    var bf_it = anon_struct.kind.structure.fieldIterator().?;
    const bf1 = (try bf_it.next()).?;
    try testing.expectEqualStrings("a", bf1.name.?);
    try testing.expectEqual(@as(u32, 1), bf1.ty.kind.bitfield);
    const bf2 = (try bf_it.next()).?;
    try testing.expect(bf2.name == null);
    try testing.expectEqual(@as(u32, 5), bf2.ty.kind.bitfield);
    try testing.expect((try bf_it.next()) == null);

    // Union
    const uni = try parseType("(TestUnion=isl)");
    try testing.expectEqualStrings("TestUnion", uni.kind.@"union".name.?);

    // Vector
    const vec = try parseType("![16,16f]");
    try testing.expectEqual(@as(usize, 16), vec.kind.vector.size);
    try testing.expectEqual(@as(usize, 16), vec.kind.vector.alignment);
    try testing.expectEqual(ParsedType.Kind.float, (try vec.kind.vector.elemType()).kind);

    // Error cases
    try testing.expectError(error.EmptyEncoding, parseType(""));
    try testing.expectError(error.TrailingCharacters, parseType("ii"));
    try testing.expectError(error.UnclosedDelimiter, parseType("{CGPoint=dd"));
    try testing.expectError(error.UnclosedDelimiter, parseType("@\"NSString"));
    try testing.expectError(error.InvalidNumber, parseType("b"));
}

test "MethodTypeIterator decodes synthetic and live runtime method signatures" {
    // Signature with frame size and offsets
    {
        var it = try MethodTypeIterator.init("v24@0:8@16");
        try testing.expectEqual(ParsedType.Kind.void, it.return_type.kind);
        try testing.expectEqual(@as(?usize, 24), it.frame_size);

        const p0 = (try it.next()).?;
        try testing.expect(p0.ty.kind.object == null);
        try testing.expectEqual(@as(?isize, 0), p0.offset);

        const p1 = (try it.next()).?;
        try testing.expectEqual(ParsedType.Kind.selector, p1.ty.kind);
        try testing.expectEqual(@as(?isize, 8), p1.offset);

        const p2 = (try it.next()).?;
        try testing.expect(p2.ty.kind.object == null);
        try testing.expectEqual(@as(?isize, 16), p2.offset);

        try testing.expect((try it.next()) == null);
    }

    // Named return object + register/negative offsets
    {
        var it = try MethodTypeIterator.init("@\"NSString\"16@+0:-8");
        try testing.expectEqualStrings("NSString", it.return_type.kind.object.?);
        try testing.expectEqual(@as(?usize, 16), it.frame_size);

        const p0 = (try it.next()).?;
        try testing.expect(p0.is_register);
        try testing.expectEqual(@as(?isize, 0), p0.offset);

        const p1 = (try it.next()).?;
        try testing.expect(!p1.is_register);
        try testing.expectEqual(@as(?isize, -8), p1.offset);

        try testing.expect((try it.next()) == null);
    }

    // Offset-less comptimeEncode method signature
    {
        var it = try MethodTypeIterator.init("v@:q");
        try testing.expectEqual(ParsedType.Kind.void, it.return_type.kind);
        try testing.expect(it.frame_size == null);
        try testing.expect((try it.next()).?.offset == null);
        try testing.expectEqual(ParsedType.Kind.selector, (try it.next()).?.ty.kind);
        try testing.expectEqual(ParsedType.Kind.longlong, (try it.next()).?.ty.kind);
        try testing.expect((try it.next()) == null);
    }

    // Real runtime method encodings fetched from NSObject and NSString
    const NSObject = objc.getClass("NSObject").?;
    const hash_method = c.class_getInstanceMethod(NSObject.value, objc.sel("hash").value) orelse
        return error.MethodNotFound;
    const hash_enc = std.mem.span(c.method_getTypeEncoding(hash_method) orelse return error.MissingEncoding);
    var hash_it = try MethodTypeIterator.init(hash_enc);
    try testing.expectEqual(ParsedType.Kind.ulonglong, hash_it.return_type.kind);
    try testing.expect(hash_it.frame_size != null);
    try testing.expect((try hash_it.next()).?.ty.kind == .object);
    try testing.expectEqual(ParsedType.Kind.selector, (try hash_it.next()).?.ty.kind);
    try testing.expect((try hash_it.next()) == null);

    const NSString = objc.getClass("NSString").?;
    const utf8_method = c.class_getInstanceMethod(NSString.value, objc.sel("UTF8String").value) orelse
        return error.MethodNotFound;
    const utf8_enc = std.mem.span(c.method_getTypeEncoding(utf8_method) orelse return error.MissingEncoding);
    var utf8_it = try MethodTypeIterator.init(utf8_enc);
    try testing.expect(utf8_it.return_type.qualifiers.@"const");
    try testing.expectEqual(ParsedType.Kind.char_string, utf8_it.return_type.kind);
    try testing.expect((try utf8_it.next()) != null);
    try testing.expect((try utf8_it.next()) != null);
    try testing.expect((try utf8_it.next()) == null);
}
