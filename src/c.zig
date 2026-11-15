const std = @import("std");

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

/// On some targets, Objective-C uses `i8` instead of `bool`.
/// This helper casts a `bool` value to the target value type.
pub fn boolParam(param: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => param,
        i8 => @intFromBool(param),
        else => @compileError("unexpected boolean type"),
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
