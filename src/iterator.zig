const std = @import("std");
const objc = @import("main.zig");

// From <Foundation/NSEnumerator.h>.
const NSFastEnumerationState = extern struct {
    state: c_ulong = 0,
    itemsPtr: ?[*]objc.c.id = null,
    mutationsPtr: ?*c_ulong = null,
    extra: [5]c_ulong = @splat(0),
};

/// An iterator that uses the fast enumeration protocol[1] to iterate over
/// objects in an Objective-C collection. This can be used with any object
/// that conforms to the `NSFastEnumeration` protocol.
///
/// [1]: https://developer.apple.com/documentation/foundation/nsfastenumeration
pub const Iterator = struct {
    object: objc.Object,
    sel: objc.Sel,
    state: NSFastEnumerationState = .{},
    start_mutation: c_ulong = 0,
    has_started: bool = false,
    exhausted: bool = false,
    // Clang compiles `for…in` loops with a size 16 buffer.
    buffer: [16]objc.c.id = @splat(null),
    batch_index: usize = 0,
    batch_len: usize = 0,
    uses_internal_buffer: bool = false,
    mutations_self_offset: u8 = no_self_offset,

    const no_self_offset: u8 = std.math.maxInt(u8);

    pub inline fn init(object: objc.Object) Iterator {
        return .{
            .object = object,
            .sel = objc.Sel.cached("countByEnumeratingWithState:objects:count:"),
        };
    }

    pub inline fn next(self: *Iterator) ?objc.Object {
        if (self.batch_index >= self.batch_len) {
            if (self.exhausted) return null;

            const count = self.object.msgSend(c_ulong, self.sel, .{
                &self.state,
                &self.buffer,
                self.buffer.len,
            });
            if (count == 0) {
                self.exhausted = true;
                return null;
            }
            const state_addr = @intFromPtr(&self.state);
            if (self.state.mutationsPtr) |mp| {
                const mp_addr = @intFromPtr(mp);
                if (mp_addr >= state_addr and mp_addr < state_addr + @sizeOf(NSFastEnumerationState)) {
                    self.mutations_self_offset = @intCast(mp_addr - state_addr);
                } else {
                    self.mutations_self_offset = no_self_offset;
                }
                if (!self.has_started) {
                    self.start_mutation = mp.*;
                }
            } else {
                self.mutations_self_offset = no_self_offset;
            }
            self.has_started = true;
            const items = self.state.itemsPtr orelse {
                self.exhausted = true;
                return null;
            };
            self.batch_index = 0;
            self.batch_len = @intCast(count);
            self.uses_internal_buffer = (items == @as([*]objc.c.id, @ptrCast(&self.buffer)));
        }

        if (self.state.mutationsPtr) |mp| {
            const cur_mutation = if (self.mutations_self_offset != no_self_offset) blk: {
                const relocated: *const c_ulong = @ptrFromInt(@intFromPtr(&self.state) + self.mutations_self_offset);
                break :blk relocated.*;
            } else mp.*;
            if (cur_mutation != self.start_mutation) {
                objc.c.objc_enumerationMutation(self.object.value);
            }
        }

        const idx = self.batch_index;
        self.batch_index = idx + 1;
        const raw_id = if (self.uses_internal_buffer)
            self.buffer[idx]
        else
            self.state.itemsPtr.?[idx];
        return objc.Object.fromId(raw_id);
    }
};

test "NSArray iteration" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSArray = objc.getClass("NSMutableArray").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const array = NSArray.msgSend(
        objc.Object,
        "arrayWithCapacity:",
        .{@as(c_ulong, 10)},
    );
    for (0..@as(c_int, 10)) |i| {
        const i_number = NSNumber.msgSend(objc.Object, "numberWithInt:", .{i});
        array.msgSend(void, "addObject:", .{i_number});
    }
    var result: c_int = 0;
    var iter = array.iterate();
    while (iter.next()) |elem| {
        result = (result * 10) + elem.getProperty(c_int, "intValue");
    }
    try testing.expectEqual(123456789, result);
}

test "NSDictionary iteration" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const dict = NSMutableDictionary.msgSend(
        objc.Object,
        "dictionaryWithCapacity:",
        .{@as(c_ulong, 100)},
    );
    for (0..@as(c_int, 100)) |i| {
        const i_number = NSNumber.msgSend(objc.Object, "numberWithInt:", .{i});
        dict.msgSend(void, "setValue:forKey:", .{
            i_number,
            i_number.getProperty(objc.Object, "stringValue"),
        });
    }
    var result: c_int = 0;
    var iter = dict.iterate();
    while (iter.next()) |key| {
        const value = dict.msgSend(objc.Object, "valueForKey:", .{key});
        result += value.getProperty(c_int, "intValue");
    }
    try testing.expectEqual(4950, result);
}

test "iterate empty NSArray and nil Object" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSArray = objc.getClass("NSArray").?;
    const NSMutableArray = objc.getClass("NSMutableArray").?;

    const empty = NSArray.msgSend(objc.Object, "array", .{});
    var empty_iter = empty.iterate();
    try testing.expect(empty_iter.next() == null);
    try testing.expect(empty_iter.next() == null);

    const empty_mut = NSMutableArray.msgSend(objc.Object, "arrayWithCapacity:", .{@as(c_ulong, 4)});
    var empty_mut_iter = empty_mut.iterate();
    try testing.expect(empty_mut_iter.next() == null);

    const nil_obj: objc.Object = .{ .value = null };
    var nil_iter = nil_obj.iterate();
    try testing.expect(nil_iter.next() == null);
    try testing.expect(nil_iter.next() == null);
}

test "iterate multi-batch NSMutableArray (> 16 elements)" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSMutableArray = objc.getClass("NSMutableArray").?;
    const NSNumber = objc.getClass("NSNumber").?;

    const total: c_int = 40;
    const array = NSMutableArray.msgSend(
        objc.Object,
        "arrayWithCapacity:",
        .{@as(c_ulong, @intCast(total))},
    );
    for (0..@as(usize, @intCast(total))) |idx| {
        const num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, @intCast(idx))});
        array.msgSend(void, "addObject:", .{num});
    }

    var count: c_int = 0;
    var sum: c_int = 0;
    var iter = array.iterate();
    while (iter.next()) |elem| {
        const val = elem.getProperty(c_int, "intValue");
        try testing.expectEqual(count, val);
        sum += val;
        count += 1;
    }
    try testing.expectEqual(total, count);
    try testing.expectEqual(@as(c_int, 780), sum);
    try testing.expect(iter.next() == null);
}

test "intra-batch mutation during iteration throws NSGenericException" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSMutableArray = objc.getClass("NSMutableArray").?;
    const NSNumber = objc.getClass("NSNumber").?;

    // Install a Foundation-equivalent throwing mutation handler (`image.zig` tests reset
    // the process-wide handler via `setEnumerationMutationHandler(null)`).
    const MutationThrower = struct {
        threadlocal var mutated_obj: objc.c.id = null;

        fn onMutation(obj: objc.c.id) callconv(.c) void {
            mutated_obj = obj;
            const NSString = objc.getClass("NSString").?;
            const NSException = objc.getClass("NSException").?;
            const name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSGenericException"});
            const reason = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"Collection was mutated while being enumerated"});
            const exc = NSException.msgSend(
                objc.Object,
                "exceptionWithName:reason:userInfo:",
                .{ name, reason, @as(?objc.Object, null) },
            );
            objc.throw(exc);
        }
    };
    MutationThrower.mutated_obj = null;
    objc.setEnumerationMutationHandler(&MutationThrower.onMutation);
    defer objc.setEnumerationMutationHandler(null);

    const array = NSMutableArray.msgSend(objc.Object, "arrayWithCapacity:", .{@as(c_ulong, 4)});
    for (0..@as(c_int, 4)) |i| {
        const num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{i});
        array.msgSend(void, "addObject:", .{num});
    }

    const res = objc.exception.tryInvoke(struct {
        fn mutateMidBatch(arr: objc.Object, num_cls: objc.Class) c_int {
            var iter = arr.iterate();
            const first = iter.next().?;
            const first_val = first.msgSend(c_int, "intValue", .{});
            const extra = num_cls.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 99)});
            arr.msgSend(void, "addObject:", .{extra});
            // Must detect mutation before returning element 1 within the same 16-item batch.
            _ = iter.next();
            return first_val;
        }
    }.mutateMidBatch, .{ array, NSNumber });

    switch (res) {
        .ok => return error.ExpectedEnumerationMutationException,
        .exception => |exc_opt| {
            const exc = exc_opt orelse return error.NullException;
            defer exc.release();
            try testing.expectEqual(array.value, MutationThrower.mutated_obj);
            const exc_name = exc.msgSend(objc.Object, "name", .{});
            try testing.expectEqualStrings(
                "NSGenericException",
                std.mem.span(exc_name.msgSend([*:0]const u8, "UTF8String", .{})),
            );
        },
    }
}

test "moving an active NSDictionary Iterator across stack frames remains valid" {
    const testing = std.testing;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSMutableDictionary = objc.getClass("NSMutableDictionary").?;
    const NSNumber = objc.getClass("NSNumber").?;

    const total: c_int = 25;
    const dict = NSMutableDictionary.msgSend(
        objc.Object,
        "dictionaryWithCapacity:",
        .{@as(c_ulong, @intCast(total))},
    );
    var expected_sum: c_int = 0;
    for (1..@as(usize, @intCast(total + 1))) |idx| {
        const val: c_int = @intCast(idx);
        expected_sum += val;
        const num = NSNumber.msgSend(objc.Object, "numberWithInt:", .{val});
        dict.msgSend(void, "setObject:forKey:", .{
            num,
            num.getProperty(objc.Object, "stringValue"),
        });
    }

    const Helpers = struct {
        const Started = struct {
            iter: Iterator,
            first_val: c_int,
        };

        noinline fn startAndConsumeOne(d: objc.Object) Started {
            var it = d.iterate();
            const first_key = it.next().?;
            const first_obj = d.msgSend(objc.Object, "objectForKey:", .{first_key});
            return .{
                .iter = it,
                .first_val = first_obj.getProperty(c_int, "intValue"),
            };
        }

        noinline fn clobberStackFrame() void {
            var poison: [128]usize = @splat(0xDEAD_BEEF_CAFE_BABE);
            std.mem.doNotOptimizeAway(&poison);
        }
    };

    const started = Helpers.startAndConsumeOne(dict);
    Helpers.clobberStackFrame();

    var moved_iter = started.iter;
    try testing.expect(moved_iter.uses_internal_buffer);

    var count: c_int = 1;
    var sum: c_int = started.first_val;
    while (moved_iter.next()) |key| {
        const num = dict.msgSend(objc.Object, "objectForKey:", .{key});
        sum += num.getProperty(c_int, "intValue");
        count += 1;
    }
    try testing.expectEqual(total, count);
    try testing.expectEqual(expected_sum, sum);
}
