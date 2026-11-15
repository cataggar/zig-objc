const std = @import("std");
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

extern "c" fn objc_initWeak(location: *c.id, val: c.id) c.id;
extern "c" fn objc_destroyWeak(location: *c.id) void;
extern "c" fn objc_loadWeakRetained(location: *c.id) c.id;
extern "c" fn objc_copyWeak(dst: *c.id, src: *c.id) void;
extern "c" fn objc_moveWeak(dst: *c.id, src: *c.id) void;

/// Initializes a fresh weak pointer slot at `location` to reference `obj`.
/// `location` must not already hold a registered non-null weak reference;
/// use `storeWeak` to reassign an already-initialized weak slot, and
/// `destroyWeak` before `location`'s storage ends its lifetime.
pub inline fn initWeak(location: *c.id, obj: ?objc.Object) ?objc.Object {
    const raw = objc_initWeak(location, if (obj) |o| o.value else null);
    return if (raw == null) null else objc.Object.fromId(raw);
}

/// Unregisters `location` from the Objective-C weak reference side table and clears `*location`.
pub inline fn destroyWeak(location: *c.id) void {
    objc_destroyWeak(location);
    location.* = null;
}

/// Loads the weakly referenced object at `location` as a `+1` retained `Object`,
/// or returns `null` if the slot is `nil` or the referent is deallocating/deallocated.
/// The caller owns the returned reference and must call `release()`.
pub inline fn loadWeakRetained(location: *c.id) ?objc.Object {
    const raw = objc_loadWeakRetained(location);
    return if (raw == null) null else objc.Object.fromId(raw);
}

/// Loads and autoreleases the weakly referenced object at `location` (`objc_loadWeak`),
/// or returns `null` if the slot is `nil` or the referent is deallocating/deallocated.
pub inline fn loadWeak(location: *c.id) ?objc.Object {
    const raw = c.objc_loadWeak(location);
    return if (raw == null) null else objc.Object.fromId(raw);
}

/// Updates an initialized weak pointer slot at `location` to reference `obj` (`objc_storeWeak`),
/// returning the stored object (or `null` if `obj` is `null` or deallocating).
pub inline fn storeWeak(location: *c.id, obj: ?objc.Object) ?objc.Object {
    const raw = c.objc_storeWeak(location, if (obj) |o| o.value else null);
    return if (raw == null) null else objc.Object.fromId(raw);
}

/// Copies a weak reference from `src` into an uninitialized weak slot `dst` (`objc_copyWeak`).
pub inline fn copyWeak(dst: *c.id, src: *c.id) void {
    objc_copyWeak(dst, src);
}

/// Moves a weak reference from `src` into an uninitialized weak slot `dst` (`objc_moveWeak`),
/// unregistering `src` and leaving `src.*` set to `null`.
pub inline fn moveWeak(dst: *c.id, src: *c.id) void {
    objc_moveWeak(dst, src);
}

/// Zeroing weak reference to an Objective-C `Object`.
///
/// IMPORTANT: The Objective-C runtime records the exact memory address `&self.slot`
/// in its weak side table so it can atomically zero `self.slot` when the referent
/// deallocates. Therefore:
/// - **NEVER** move an active `Weak` by bitwise struct copy/assignment (`var b = a;`).
/// - Place `Weak` in stable memory (a local variable or heap-allocated struct),
///   use `copyFrom` or `moveFrom` to transfer across addresses, and always call `deinit`
///   before the storage is freed or goes out of scope.
pub const Weak = WeakType(objc.Object);

/// Generic zeroing weak reference wrapper for any `c.id`-backed Objective-C wrapper type `T`
/// (such as `objc.Object`, or a user-defined typed wrapper exposing `value: c.id` and `fromId`).
///
/// Like `Weak`, `&self.slot` is registered in the Objective-C weak side table:
/// do NOT move an active `WeakType(T)` by value; use `moveFrom` / `copyFrom` and always `deinit`.
pub fn WeakType(comptime T: type) type {
    return struct {
        slot: c.id = null,

        /// Comptime marker identifying `WeakType(T)` so `Block` capture validation can
        /// reject accidental bitwise capture (`memcpy`) of weak side-table slots.
        pub const zig_objc_is_weak = true;

        const Self = @This();

        inline fn unwrap(obj: ?T) c.id {
            const val = obj orelse return null;
            if (T == objc.Object) return val.value;
            if (@hasDecl(T, "toId")) return val.toId();
            return val.value;
        }

        inline fn wrap(raw: c.id) T {
            if (T == objc.Object) return objc.Object.fromId(raw);
            if (@hasDecl(T, "fromId")) return T.fromId(raw);
            return .{ .value = raw };
        }

        /// Initializes an unregistered weak slot (`var w: Weak = .{}; w.init(obj);`) via `objc_initWeak`.
        /// To reassign a `Weak` that may already hold a reference, use `store`.
        pub inline fn init(self: *Self, obj: ?T) void {
            _ = objc_initWeak(&self.slot, unwrap(obj));
        }

        /// Initializes an unregistered weak slot in-place via `objc_initWeak` and returns
        /// the stored object (or `null` if `obj` is `null` or already deallocating).
        pub inline fn initValue(self: *Self, obj: ?T) ?T {
            const raw = objc_initWeak(&self.slot, unwrap(obj));
            return if (raw == null) null else wrap(raw);
        }

        /// Unregisters `&self.slot` from the Objective-C weak side table (`objc_destroyWeak`)
        /// and resets `self.slot` to `null`. Safe to call multiple times.
        pub inline fn deinit(self: *Self) void {
            objc_destroyWeak(&self.slot);
            self.slot = null;
        }

        /// Atomically loads and retains (`+1`) the referent (`objc_loadWeakRetained`),
        /// returning `null` if `nil` or already deallocating/deallocated.
        /// Caller must release the returned object when non-null.
        pub inline fn loadRetained(self: *Self) ?T {
            const raw = objc_loadWeakRetained(&self.slot);
            return if (raw == null) null else wrap(raw);
        }

        /// Alias for `loadRetained` (`+1` retained load).
        pub const load = loadRetained;

        /// Atomically loads and autoreleases the referent (`objc_loadWeak`),
        /// returning `null` if `nil` or already deallocating/deallocated.
        pub inline fn loadAutoreleased(self: *Self) ?T {
            const raw = c.objc_loadWeak(&self.slot);
            return if (raw == null) null else wrap(raw);
        }

        /// Stores `obj` (or `null` to clear) into `&self.slot` (`objc_storeWeak`),
        /// properly updating side-table registrations if `self` already held a reference.
        pub inline fn store(self: *Self, obj: ?T) ?T {
            const raw = c.objc_storeWeak(&self.slot, unwrap(obj));
            return if (raw == null) null else wrap(raw);
        }

        /// Copies the weak reference from `src` into `dst` (`objc_copyWeak`).
        /// If `dst` already holds an active weak reference, it is unregistered first.
        pub inline fn copyFrom(dst: *Self, src: *Self) void {
            if (dst == src) return;
            if (dst.slot != null) objc_destroyWeak(&dst.slot);
            objc_copyWeak(&dst.slot, &src.slot);
        }

        /// Moves the weak reference from `src` into `dst` (`objc_moveWeak`),
        /// leaving `src` cleared (`null`). If `dst` already holds an active weak reference,
        /// it is unregistered first.
        pub inline fn moveFrom(dst: *Self, src: *Self) void {
            if (dst == src) return;
            if (dst.slot != null) objc_destroyWeak(&dst.slot);
            objc_moveWeak(&dst.slot, &src.slot);
        }
    };
}

test "Weak zeroing lifecycle on NSObject deallocation" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    var weak: Weak = .{};
    defer weak.deinit();

    try testing.expect(weak.loadRetained() == null);

    const obj = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    weak.init(obj);

    // Loading via loadRetained returns a +1 reference that keeps the object alive.
    {
        const loaded = weak.loadRetained() orelse return error.ExpectedLiveObject;
        defer loaded.release();
        try testing.expectEqual(obj.value, loaded.value);
        try testing.expectEqual(@as(c_ulong, 2), obj.msgSend(c_ulong, "retainCount", .{}));
    }
    try testing.expectEqual(@as(c_ulong, 1), obj.msgSend(c_ulong, "retainCount", .{}));

    // Releasing the last strong reference deallocates `obj` and zeroes `weak.slot`.
    obj.release();
    try testing.expect(weak.loadRetained() == null);
    try testing.expect(weak.slot == null);
}

test "Weak copyFrom, moveFrom, store, loadAutoreleased, and deinit" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const State = struct {
        var dealloc_count: usize = 0;
    };
    State.dealloc_count = 0;

    const Tracked = objc.allocateClassPair(NSObject, "ZigObjcWeakTrackedObject").?;
    defer objc.disposeClassPair(Tracked);

    _ = Tracked.replaceMethod("dealloc", struct {
        fn dealloc(target: c.id, _: c.SEL) callconv(.c) void {
            State.dealloc_count += 1;
            const self = objc.Object.fromId(target);
            self.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
    }.dealloc);
    objc.registerClassPair(Tracked);

    const obj1 = Tracked.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    const obj2 = Tracked.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    var w1: Weak = .{};
    defer w1.deinit();
    w1.init(obj1);

    // loadAutoreleased inside an AutoreleasePool
    {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const auto_loaded = w1.loadAutoreleased() orelse return error.ExpectedLiveObject;
        try testing.expectEqual(obj1.value, auto_loaded.value);
    }

    // copyFrom into fresh w2 and then overwrite active w2 via store and copyFrom
    var w2: Weak = .{};
    defer w2.deinit();
    w2.copyFrom(&w1);
    {
        const l2 = w2.loadRetained() orelse return error.ExpectedLiveObject;
        defer l2.release();
        try testing.expectEqual(obj1.value, l2.value);
    }

    _ = w2.store(obj2);
    {
        const l2 = w2.loadRetained() orelse return error.ExpectedLiveObject;
        defer l2.release();
        try testing.expectEqual(obj2.value, l2.value);
    }

    // Overwrite active w2 (currently holding obj2) with copyFrom(&w1)
    w2.copyFrom(&w1);
    {
        const l2 = w2.loadRetained() orelse return error.ExpectedLiveObject;
        defer l2.release();
        try testing.expectEqual(obj1.value, l2.value);
    }

    // moveFrom transfers registration from w2 to w3 and clears w2
    var w3: Weak = .{};
    defer w3.deinit();
    w3.init(obj2);
    w3.moveFrom(&w2);
    try testing.expect(w2.loadRetained() == null);
    {
        const l3 = w3.loadRetained() orelse return error.ExpectedLiveObject;
        defer l3.release();
        try testing.expectEqual(obj1.value, l3.value);
    }

    // store(null) explicitly clears w1 while w3 still tracks obj1
    try testing.expect(w1.store(null) == null);
    try testing.expect(w1.loadRetained() == null);
    {
        const still_live = w3.loadRetained() orelse return error.ExpectedLiveObject;
        still_live.release();
    }

    // Release obj2 and obj1; verify dealloc_count == 2 and w3 auto-zeroed
    obj2.release();
    try testing.expectEqual(@as(usize, 1), State.dealloc_count);
    obj1.release();
    try testing.expectEqual(@as(usize, 2), State.dealloc_count);
    try testing.expect(w3.loadRetained() == null);

    // Explicit double deinit is safe
    w3.deinit();
    w3.deinit();
}

test "standalone weak functions and WeakType custom wrapper" {
    const testing = std.testing;
    const NSObject = objc.getClass("NSObject").?;

    const obj = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    var slot1: c.id = null;
    defer destroyWeak(&slot1);
    try testing.expectEqual(obj.value, initWeak(&slot1, obj).?.value);

    var slot2: c.id = null;
    defer destroyWeak(&slot2);
    copyWeak(&slot2, &slot1);

    var slot3: c.id = null;
    defer destroyWeak(&slot3);
    moveWeak(&slot3, &slot2);
    try testing.expect(slot2 == null);

    {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        try testing.expectEqual(obj.value, loadWeak(&slot3).?.value);
    }

    {
        const retained = loadWeakRetained(&slot3).?;
        defer retained.release();
        try testing.expectEqual(obj.value, retained.value);
    }

    try testing.expect(storeWeak(&slot1, null) == null);
    try testing.expect(loadWeakRetained(&slot1) == null);

    // Custom typed wrapper with WeakType
    const CustomWrapper = struct {
        value: c.id,
        pub fn fromId(raw: c.id) @This() {
            return .{ .value = raw };
        }
    };
    var custom_weak: WeakType(CustomWrapper) = .{};
    defer custom_weak.deinit();
    custom_weak.init(.{ .value = obj.value });
    {
        const cw = custom_weak.loadRetained().?;
        objc.Object.fromId(cw.value).release();
    }

    obj.release();
    try testing.expect(loadWeakRetained(&slot3) == null);
    try testing.expect(custom_weak.loadRetained() == null);
}

test "Weak with tagged-pointer NSNumber loads cleanly and deinits safely" {
    const testing = std.testing;

    try testing.expect(Weak.zig_objc_is_weak);

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSNumber = objc.getClass("NSNumber") orelse return error.ClassNotFound;
    const tagged_num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 7)});

    var weak_num: Weak = .{};
    defer weak_num.deinit();

    const initialized = weak_num.initValue(tagged_num) orelse return error.ExpectedTaggedObject;
    try testing.expectEqual(@as(c_int, 7), initialized.msgSend(c_int, "intValue", .{}));

    {
        const loaded = weak_num.load() orelse return error.ExpectedTaggedObject;
        defer loaded.release();
        try testing.expectEqual(@as(c_int, 7), loaded.msgSend(c_int, "intValue", .{}));
    }

    {
        const auto_loaded = weak_num.loadAutoreleased() orelse return error.ExpectedTaggedObject;
        try testing.expectEqual(@as(c_int, 7), auto_loaded.msgSend(c_int, "intValue", .{}));
    }

    var copied_num: Weak = .{};
    defer copied_num.deinit();
    copied_num.copyFrom(&weak_num);
    {
        const loaded_copy = copied_num.loadRetained() orelse return error.ExpectedTaggedObject;
        defer loaded_copy.release();
        try testing.expectEqual(@as(c_int, 7), loaded_copy.msgSend(c_int, "intValue", .{}));
    }

    weak_num.deinit();
    try testing.expect(weak_num.load() == null);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Weak);
}
