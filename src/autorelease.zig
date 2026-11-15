const std = @import("std");

pub const AutoreleasePool = opaque {
    /// Create a new autorelease pool. To clean it up, call deinit.
    pub inline fn init() *AutoreleasePool {
        return @ptrCast(objc_autoreleasePoolPush().?);
    }

    pub inline fn deinit(self: *AutoreleasePool) void {
        objc_autoreleasePoolPop(self);
    }
};

// Clang `@autoreleasepool` Objective-C runtime ABI symbols exported by `libobjc.A.dylib`.
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;

test "AutoreleasePool push and pop" {
    const objc = @import("main.zig");
    const NSObject = objc.getClass("NSObject").?;

    const outer = AutoreleasePool.init();
    defer outer.deinit();

    {
        const inner = AutoreleasePool.init();
        defer inner.deinit();

        const obj = objc.allocInit(NSObject).?;
        _ = obj.autorelease();
        try std.testing.expectEqual(@as(objc.NSUInteger, 1), obj.msgSend(objc.NSUInteger, "retainCount", .{}));
    }
}
