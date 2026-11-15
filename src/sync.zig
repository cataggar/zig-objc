const std = @import("std");
const c = @import("c.zig").c;
const objc = @import("main.zig");

/// Errors returned by Objective-C `@synchronized` runtime primitives
/// (`objc_sync_enter` and `objc_sync_exit` in `<objc/objc-sync.h>`).
pub const SyncError = error{
    /// `objc_sync_exit` was called by a thread that does not currently own
    /// the recursive monitor associated with the object
    /// (`OBJC_SYNC_NOT_OWNING_THREAD_ERROR`).
    NotOwningThread,
    /// An unrecognized status code was returned by the Objective-C runtime.
    Unexpected,
};

inline fn checkStatus(status: c_int) SyncError!void {
    return switch (status) {
        c.OBJC_SYNC_SUCCESS => {},
        c.OBJC_SYNC_NOT_OWNING_THREAD_ERROR => error.NotOwningThread,
        else => error.Unexpected,
    };
}

/// Begins synchronizing on `obj` (`objc_sync_enter`).
/// Allocates a recursive mutex associated with `obj` if needed and blocks
/// until the current thread acquires it. Passing a nil `Object` is a no-op
/// that succeeds.
pub inline fn syncEnter(obj: objc.Object) SyncError!void {
    return checkStatus(c.objc_sync_enter(obj.value));
}

/// Ends synchronizing on `obj` (`objc_sync_exit`).
/// Returns `error.NotOwningThread` if the calling thread does not hold the
/// lock for `obj`. Passing a nil `Object` is a no-op that succeeds.
pub inline fn syncExit(obj: objc.Object) SyncError!void {
    return checkStatus(c.objc_sync_exit(obj.value));
}

/// Scoped guard returned by `synchronize`, equivalent to an Objective-C
/// `@synchronized(obj) { ... }` block when paired with `defer guard.unlock()`.
pub const SyncGuard = struct {
    obj: objc.Object,

    /// Releases the synchronization lock, asserting that the current thread
    /// still owns it. Suitable for `defer guard.unlock()`.
    pub inline fn unlock(self: SyncGuard) void {
        syncExit(self.obj) catch unreachable;
    }

    /// Releases the synchronization lock, returning any runtime `SyncError`.
    pub inline fn tryUnlock(self: SyncGuard) SyncError!void {
        return syncExit(self.obj);
    }
};

/// Acquires the recursive synchronization monitor for `obj` and returns a
/// `SyncGuard` whose `unlock()` releases the monitor.
pub inline fn synchronize(obj: objc.Object) SyncError!SyncGuard {
    try syncEnter(obj);
    return .{ .obj = obj };
}

fn allocObject() objc.Object {
    const NSObject = objc.getClass("NSObject").?;
    return NSObject.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
}

test "synchronize guard basic lock and unlock" {
    const obj = allocObject();
    defer obj.release();

    {
        const guard = try synchronize(obj);
        defer guard.unlock();
    }

    // Also verify explicit fallible tryUnlock
    const guard = try synchronize(obj);
    try guard.tryUnlock();
    try std.testing.expectError(error.NotOwningThread, guard.tryUnlock());

    // Nil object synchronization is a documented runtime no-op that succeeds.
    const nil_obj: objc.Object = .{ .value = null };
    const nil_guard = try synchronize(nil_obj);
    try nil_guard.tryUnlock();
}

test "re-entrant recursive acquisition on same thread" {
    const obj = allocObject();
    defer obj.release();

    try syncEnter(obj);
    try syncEnter(obj);
    {
        const inner = try synchronize(obj);
        defer inner.unlock();
    }
    try syncExit(obj);
    try syncExit(obj);

    // Lock is now completely released by this thread.
    try std.testing.expectError(error.NotOwningThread, syncExit(obj));
}

test "syncExit when not holding lock returns NotOwningThread" {
    const obj = allocObject();
    defer obj.release();

    // Unlocked object on current thread.
    try std.testing.expectError(error.NotOwningThread, syncExit(obj));

    // Locked by current thread, exited from a non-owning thread.
    const guard = try synchronize(obj);
    defer guard.unlock();

    const NonOwner = struct {
        target: objc.Object,
        result: ?SyncError!void = null,

        fn run(self: *@This()) void {
            self.result = syncExit(self.target);
        }
    };

    var probe: NonOwner = .{ .target = obj };
    const thread = try std.Thread.spawn(.{}, NonOwner.run, .{&probe});
    thread.join();

    try std.testing.expectError(error.NotOwningThread, probe.result.?);
}

test "synchronize enforces multi-threaded mutual exclusion" {
    const lock_obj = allocObject();
    defer lock_obj.release();

    const thread_count = 4;
    const iterations_per_thread = 1_000;

    const SharedContext = struct {
        lock_obj: objc.Object,
        ready: std.atomic.Value(usize) = .init(0),
        count: usize = 0,

        fn worker(self: *@This()) SyncError!void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (self.ready.load(.acquire) < thread_count) {
                std.atomic.spinLoopHint();
            }

            for (0..iterations_per_thread) |_| {
                const guard = try synchronize(self.lock_obj);
                defer guard.unlock();
                const next = self.count + 1;
                std.atomic.spinLoopHint();
                self.count = next;
            }
        }
    };

    var ctx: SharedContext = .{ .lock_obj = lock_obj };
    var threads: [thread_count]std.Thread = undefined;

    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, SharedContext.worker, .{&ctx});
    }
    for (threads) |t| {
        t.join();
    }

    try std.testing.expectEqual(@as(usize, thread_count * iterations_per_thread), ctx.count);
}

test {
    std.testing.refAllDecls(@This());
}
