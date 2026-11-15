const std = @import("std");

const autorelease = @import("autorelease.zig");
const block = @import("block.zig");
const cpkg = @import("c.zig");
const class = @import("class.zig");
const encoding = @import("encoding.zig");
const iterator = @import("iterator.zig");
const msg_send = @import("msg_send.zig");
const object = @import("object.zig");
const property = @import("property.zig");
const protocol = @import("protocol.zig");
const selpkg = @import("sel.zig");

pub const c = cpkg.c;
pub const NSInteger = cpkg.NSInteger;
pub const NSUInteger = cpkg.NSUInteger;
pub const AutoreleasePool = autorelease.AutoreleasePool;
pub const Block = block.Block;
pub const Class = class.Class;
pub const getClass = class.getClass;
pub const getMetaClass = class.getMetaClass;
pub const allocateClassPair = class.allocateClassPair;
pub const registerClassPair = class.registerClassPair;
pub const disposeClassPair = class.disposeClassPair;
pub const Encoding = encoding.Encoding;
pub const comptimeEncode = encoding.comptimeEncode;
pub const Qualifiers = encoding.Qualifiers;
pub const ParsedType = encoding.ParsedType;
pub const ParseError = encoding.ParseError;
pub const parseType = encoding.parseType;
pub const parseTypePrefix = encoding.parseTypePrefix;
pub const MethodTypeIterator = encoding.MethodTypeIterator;
pub const Iterator = iterator.Iterator;
pub const msgForward = msg_send.msgForward;
pub const msgForwardStret = msg_send.msgForwardStret;
pub const setForwardHandler = msg_send.setForwardHandler;
pub const Object = object.Object;
pub const Property = property.Property;
pub const Protocol = protocol.Protocol;
pub const getProtocol = protocol.getProtocol;
pub const sel = selpkg.sel;
pub const Sel = selpkg.Sel;

/// Frees heap memory returned by Objective-C runtime `copy*` functions using
/// `std.c.free`. Safely ignores `null` optionals and empty non-sentinel slices
/// (`&.{}`), while freeing sentinel-terminated C strings even when `len == 0`.
pub fn free(ptr: anytype) void {
    const T = @TypeOf(ptr);
    switch (@typeInfo(T)) {
        .null => return,
        .optional => {
            if (ptr) |unwrapped| free(unwrapped);
            return;
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => {
                if (ptr_info.sentinel_ptr == null and ptr.len == 0) return;
                std.c.free(@ptrCast(@constCast(ptr.ptr)));
            },
            .one => {
                switch (@typeInfo(ptr_info.child)) {
                    .@"opaque" => {},
                    .array => |arr_info| {
                        if (arr_info.sentinel_ptr == null and arr_info.len == 0) return;
                    },
                    else => {
                        if (@sizeOf(ptr_info.child) == 0) return;
                    },
                }
                std.c.free(@ptrCast(@constCast(ptr)));
            },
            .many => {
                std.c.free(@ptrCast(@constCast(ptr)));
            },
            .c => {
                if (ptr == null) return;
                std.c.free(@ptrCast(@constCast(ptr)));
            },
        },
        else => @compileError("objc.free expected pointer, slice, or optional thereof, got " ++ @typeName(T)),
    }
}

test "free handles malloc buffers, sentinel strings, null optionals, and empty slices" {
    const testing = std.testing;

    // Non-empty non-sentinel slice allocated via malloc
    const raw_buf = std.c.malloc(32) orelse return error.OutOfMemory;
    const byte_slice: []u8 = @as([*]u8, @ptrCast(raw_buf))[0..32];
    @memset(byte_slice, 0xAB);
    free(byte_slice);

    const raw_const = std.c.malloc(16) orelse return error.OutOfMemory;
    const const_slice: []const u8 = @as([*]const u8, @ptrCast(raw_const))[0..16];
    free(const_slice);

    // Single, many, and C pointers allocated via malloc
    const single_ptr: *u64 = @ptrCast(@alignCast(std.c.malloc(@sizeOf(u64)) orelse return error.OutOfMemory));
    single_ptr.* = 42;
    free(single_ptr);

    const many_ptr: [*]u8 = @ptrCast(std.c.malloc(8) orelse return error.OutOfMemory);
    free(many_ptr);

    const c_ptr: [*c]u8 = @ptrCast(std.c.malloc(8) orelse return error.OutOfMemory);
    free(c_ptr);
    const null_c_ptr: [*c]const u8 = null;
    free(null_c_ptr);

    // Sentinel-terminated C string slices, including zero-length malloc'd ""
    const empty_cstr_buf: [*]u8 = @ptrCast(std.c.malloc(1) orelse return error.OutOfMemory);
    empty_cstr_buf[0] = 0;
    const empty_cstr: [:0]u8 = empty_cstr_buf[0..0 :0];
    try testing.expectEqual(@as(usize, 0), empty_cstr.len);
    free(empty_cstr);

    const hello_buf: [*]u8 = @ptrCast(std.c.malloc(6) orelse return error.OutOfMemory);
    @memcpy(hello_buf[0..5], "hello");
    hello_buf[5] = 0;
    const hello_cstr: [:0]const u8 = hello_buf[0..5 :0];
    free(hello_cstr);

    const many_z_buf: [*]u8 = @ptrCast(std.c.malloc(4) orelse return error.OutOfMemory);
    @memcpy(many_z_buf[0..3], "abc");
    many_z_buf[3] = 0;
    const many_z: [*:0]u8 = many_z_buf[0..3 :0].ptr;
    free(many_z);

    // Null optionals of all pointer/slice kinds
    free(@as(?[]u8, null));
    free(@as(?[:0]u8, null));
    free(@as(?[*:0]const u8, null));
    free(@as(?*u32, null));
    free(null);

    // Non-null optional and opaque pointers wrapping malloc buffers
    const opt_ptr: ?*u8 = @ptrCast(std.c.malloc(1) orelse return error.OutOfMemory);
    free(opt_ptr);
    const opaque_ptr: *anyopaque = std.c.malloc(4) orelse return error.OutOfMemory;
    free(opaque_ptr);

    // Empty non-sentinel slices (`&.{}`) must be safe no-ops
    const empty_mut: []u8 = &.{};
    free(empty_mut);
    const empty_const: []const Property = &.{};
    free(empty_const);
    free(&.{});
}

test {
    std.testing.refAllDecls(@This());
}
