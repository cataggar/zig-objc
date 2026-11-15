const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const BenchState = struct {
    counter: usize = 42,
    value: c_int = 7,
    custom_value: c_int = 11,
};

const BenchSlots = struct {
    var state_slot: objc.IvarSlot(*BenchState) = .{};
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.UPTIME_RAW, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn writeStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(std.c.STDOUT_FILENO, @ptrCast(bytes[written..].ptr), bytes.len - written);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    writeStdout(out);
}

fn formatRate(buf: *[32]u8, ops_per_sec: f64) []const u8 {
    if (ops_per_sec >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}G/s", .{ops_per_sec / 1_000_000_000.0}) catch unreachable;
    } else if (ops_per_sec >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}M/s", .{ops_per_sec / 1_000_000.0}) catch unreachable;
    } else if (ops_per_sec >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2}K/s", .{ops_per_sec / 1_000.0}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d:.0}/s", .{ops_per_sec}) catch unreachable;
}

fn printRow(name: []const u8, ns_per_op: f64, note: []const u8) void {
    const ops_per_sec = if (ns_per_op > 0.0) 1_000_000_000.0 / ns_per_op else 0.0;
    var rate_buf: [32]u8 = undefined;
    const rate = formatRate(&rate_buf, ops_per_sec);
    printFmt("| {s:<44} | {d:>9.2} | {s:>11} | {s:<18} |\n", .{ name, ns_per_op, rate, note });
}

fn printPairedRow(name: []const u8, ns_per_op: f64, baseline_ns: f64) void {
    var note_buf: [32]u8 = undefined;
    const ratio = if (ns_per_op > 0.0) baseline_ns / ns_per_op else 0.0;
    const note = if (ratio >= 1.0)
        std.fmt.bufPrint(&note_buf, "{d:.2}x faster", .{ratio}) catch unreachable
    else
        std.fmt.bufPrint(&note_buf, "{d:.2}x vs base", .{ratio}) catch unreachable;
    printRow(name, ns_per_op, note);
}

/// Runs warmup iterations, auto-calibrates iteration count for a ~12ms sample window,
/// and returns the minimum `ns/op` across 3 timed samples (~38ms per benchmark).
fn measure(ctx: anytype, comptime body: fn (@TypeOf(ctx), usize) void) f64 {
    // Warmup caches, Objective-C method dispatch tables, and lazy atomics.
    body(ctx, 512);

    const probe_iters: usize = 2_048;
    const t0 = nowNs();
    body(ctx, probe_iters);
    const probe_ns = @max(@as(u64, 1), nowNs() -| t0);

    const sample_budget_ns: u64 = 12_000_000; // 12 ms per sample x 3 samples = ~36 ms
    const estimated = (@as(u128, probe_iters) * sample_budget_ns) / probe_ns;
    const sample_iters: usize = @intCast(std.math.clamp(estimated, 2_048, 25_000_000));

    var best_ns_per_op: f64 = std.math.inf(f64);
    for (0..3) |_| {
        const start = nowNs();
        body(ctx, sample_iters);
        const elapsed = @max(@as(u64, 1), nowNs() -| start);
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(sample_iters));
        if (ns_per_op < best_ns_per_op) best_ns_per_op = ns_per_op;
    }
    return best_ns_per_op;
}

fn tryTargetAdd(a: i64, b: i64) i64 {
    return a + b;
}

pub fn main() void {
    const outer_pool = objc.AutoreleasePool.init();
    defer outer_pool.deinit();

    const NSObject = objc.getClassCached("NSObject").?;
    const NSString = objc.getClassCached("NSString").?;
    const NSNumber = objc.getClassCached("NSNumber").?;
    const NSValue = objc.getClassCached("NSValue").?;
    const NSArray = objc.getClassCached("NSArray").?;
    const NSMutableArray = objc.getClassCached("NSMutableArray").?;
    const NSMutableDictionary = objc.getClassCached("NSMutableDictionary").?;

    // Set up heap NSString (> 16 bytes so it uses heap object dispatch rather than tagged pointer)
    var heap_str = NSString.msgSend(
        objc.Object,
        objc.S("stringWithUTF8String:"),
        .{"hello from zig-objc microbenchmark suite!"},
    );
    std.mem.doNotOptimizeAway(&heap_str);

    // Set up 32-byte NSRect NSValue
    const sample_rect: NSRect = .{
        .origin = .{ .x = 12.5, .y = 34.0 },
        .size = .{ .width = 640.0, .height = 480.0 },
    };
    var rect_val = NSValue.msgSend(objc.Object, objc.S("valueWithRect:"), .{sample_rect});
    std.mem.doNotOptimizeAway(&rect_val);
    const verify_rect = rect_val.msgSend(NSRect, objc.S("rectValue"), .{});
    std.debug.assert(verify_rect.size.width == 640.0 and verify_rect.size.height == 480.0);

    // Set up NSDictionary for hit & nil-miss ?Object lookups
    var dict = NSMutableDictionary.msgSend(objc.Object, objc.S("dictionaryWithCapacity:"), .{@as(c_ulong, 8)});
    var hit_key = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"existing_key"});
    var miss_key = NSString.msgSend(objc.Object, objc.S("stringWithUTF8String:"), .{"missing_key"});
    const hit_val = NSNumber.msgSend(objc.Object, objc.S("numberWithInt:"), .{@as(c_int, 1234)});
    dict.msgSend(void, objc.S("setObject:forKey:"), .{ hit_val, hit_key });
    std.mem.doNotOptimizeAway(&dict);
    std.mem.doNotOptimizeAway(&hit_key);
    std.mem.doNotOptimizeAway(&miss_key);

    // Set up dynamic BenchObject with *BenchState ivar + default & custom-G/S properties
    const BenchClass = objc.allocateClassPair(NSObject, "ZigObjcBenchObject").?;
    defer objc.disposeClassPair(BenchClass);

    _ = BenchClass.addIvar(*BenchState, "zig_state");
    _ = BenchClass.addProperty("value", &.{
        .{ .name = "T", .value = "i" },
        .{ .name = "N", .value = "" },
        .{ .name = "V", .value = "_value" },
    });
    _ = BenchClass.addProperty("customValue", &.{
        .{ .name = "T", .value = "i" },
        .{ .name = "G", .value = "fetchCustomValue" },
        .{ .name = "S", .value = "assignCustomValue:" },
        .{ .name = "N", .value = "" },
        .{ .name = "V", .value = "_customValue" },
    });

    _ = BenchClass.addMethod("value", struct {
        fn imp(self_obj: objc.Object, _: objc.Sel) callconv(.c) c_int {
            return BenchSlots.state_slot.load(self_obj).value;
        }
    }.imp);
    _ = BenchClass.addMethod("setValue:", struct {
        fn imp(self_obj: objc.Object, _: objc.Sel, v: c_int) callconv(.c) void {
            BenchSlots.state_slot.load(self_obj).value = v;
        }
    }.imp);
    _ = BenchClass.addMethod("fetchCustomValue", struct {
        fn imp(self_obj: objc.Object, _: objc.Sel) callconv(.c) c_int {
            return BenchSlots.state_slot.load(self_obj).custom_value;
        }
    }.imp);
    _ = BenchClass.addMethod("assignCustomValue:", struct {
        fn imp(self_obj: objc.Object, _: objc.Sel, v: c_int) callconv(.c) void {
            BenchSlots.state_slot.load(self_obj).custom_value = v;
        }
    }.imp);
    objc.registerClassPair(BenchClass);

    const eager_slot = objc.IvarSlot(*BenchState).fromClass(BenchClass, "zig_state").?;
    BenchSlots.state_slot = eager_slot;
    var lazy_slot: objc.IvarSlot(*BenchState) = .{};

    var bench_state: BenchState = .{};
    var bench_obj = objc.allocInit(BenchClass).?;
    defer bench_obj.release();
    eager_slot.store(bench_obj, &bench_state);
    std.mem.doNotOptimizeAway(&bench_obj);

    // Set up empty NSArray and 64-element NSArray for fast enumeration
    var empty_arr = NSArray.msgSend(objc.Object, objc.S("array"), .{});
    const mut_arr_64 = NSMutableArray.msgSend(objc.Object, objc.S("arrayWithCapacity:"), .{@as(c_ulong, 64)});
    for (0..64) |idx| {
        const n = NSNumber.msgSend(objc.Object, objc.S("numberWithInt:"), .{@as(c_int, @intCast(idx))});
        mut_arr_64.msgSend(void, objc.S("addObject:"), .{n});
    }
    var arr_64 = NSArray.msgSend(objc.Object, objc.S("arrayWithArray:"), .{mut_arr_64});
    std.mem.doNotOptimizeAway(&empty_arr);
    std.mem.doNotOptimizeAway(&arr_64);

    // Set up Block and BlockRef
    const AddBlock = objc.Block(struct { bias: i64 }, .{ i64, i64 }, i64);
    var stack_block = AddBlock.init(.{ .bias = 10 }, &(struct {
        fn invoke(ctx: *const AddBlock.Context, a: i64, b: i64) callconv(.c) i64 {
            return ctx.bias + a + b;
        }
    }).invoke);
    std.mem.doNotOptimizeAway(&stack_block);
    var block_ref = AddBlock.asBlockRef(&stack_block);
    std.mem.doNotOptimizeAway(&block_ref);

    const suite_start = nowNs();

    printFmt(
        "\nzig-objc microbenchmarks ({s}-{s}, optimize={s})\n",
        .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.mode) },
    );
    printFmt("+----------------------------------------------+-----------+-------------+--------------------+\n", .{});
    printFmt("| Benchmark                                    |     ns/op |     ops/sec | Speedup / Notes    |\n", .{});
    printFmt("+----------------------------------------------+-----------+-------------+--------------------+\n", .{});

    // 1. sel("length") vs S("length")
    const sel_uncached_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(objc.sel("length"));
            }
        }
    }.run);
    printRow("sel(\"length\") [uncached]", sel_uncached_ns, "baseline");

    const sel_cached_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(objc.S("length"));
            }
        }
    }.run);
    printPairedRow("S(\"length\") [Sel.cached]", sel_cached_ns, sel_uncached_ns);

    // 2. getClass("NSString") vs getClassCached("NSString")
    const cls_uncached_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(objc.getClass("NSString"));
            }
        }
    }.run);
    printRow("getClass(\"NSString\") [uncached]", cls_uncached_ns, "baseline");

    const cls_cached_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(objc.getClassCached("NSString"));
            }
        }
    }.run);
    printPairedRow("getClassCached(\"NSString\")", cls_cached_ns, cls_uncached_ns);

    // 3. msgSend(usize, "length") vs msgSend(usize, S("length"))
    const msg_raw_ns = measure(heap_str, struct {
        fn run(s: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(s.msgSend(usize, "length", .{}));
            }
        }
    }.run);
    printRow("msgSend(usize, \"length\") [raw str]", msg_raw_ns, "baseline");

    const msg_cached_ns = measure(heap_str, struct {
        fn run(s: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(s.msgSend(usize, objc.S("length"), .{}));
            }
        }
    }.run);
    printPairedRow("msgSend(usize, S(\"length\")) [cached]", msg_cached_ns, msg_raw_ns);

    // 4. msgSend(NSRect, S("rectValue")) (32-byte struct return)
    const msg_rect_ns = measure(rect_val, struct {
        fn run(v: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(v.msgSend(NSRect, objc.S("rectValue"), .{}));
            }
        }
    }.run);
    printRow("msgSend(NSRect, S(\"rectValue\")) [32B]", msg_rect_ns, "32B struct return");

    // 5. msgSend(?Object, S("objectForKey:")) (hit & nil miss)
    const DictCtx = struct { d: objc.Object, k: objc.Object };
    const dict_hit_ns = measure(DictCtx{ .d = dict, .k = hit_key }, struct {
        fn run(c: DictCtx, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(c.d.msgSend(?objc.Object, objc.S("objectForKey:"), .{c.k}));
            }
        }
    }.run);
    printRow("msgSend(?Object, S(\"objectForKey:\")) [hit]", dict_hit_ns, "non-null ?Object");

    const dict_miss_ns = measure(DictCtx{ .d = dict, .k = miss_key }, struct {
        fn run(c: DictCtx, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(c.d.msgSend(?objc.Object, objc.S("objectForKey:"), .{c.k}));
            }
        }
    }.run);
    printRow("msgSend(?Object, S(\"objectForKey:\")) [nil]", dict_miss_ns, "nil -> null");

    // 6. Object.getProperty & Object.setProperty (cached default + custom G/S attribute path)
    const get_prop_default_ns = measure(bench_obj, struct {
        fn run(o: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(o.getProperty(c_int, "value"));
            }
        }
    }.run);
    printRow("Object.getProperty [cached default]", get_prop_default_ns, "zero-malloc");

    const get_prop_custom_ns = measure(bench_obj, struct {
        fn run(o: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(o.getProperty(c_int, "customValue"));
            }
        }
    }.run);
    printPairedRow("Object.getProperty [custom G attr]", get_prop_custom_ns, get_prop_default_ns);

    const set_prop_default_ns = measure(bench_obj, struct {
        fn run(o: objc.Object, iters: usize) void {
            for (0..iters) |idx| {
                o.setProperty("value", @as(c_int, @truncate(@as(isize, @bitCast(idx)))));
            }
            std.mem.doNotOptimizeAway(o);
        }
    }.run);
    printRow("Object.setProperty [cached default]", set_prop_default_ns, "zero-malloc");

    const set_prop_custom_ns = measure(bench_obj, struct {
        fn run(o: objc.Object, iters: usize) void {
            for (0..iters) |idx| {
                o.setProperty("customValue", @as(c_int, @truncate(@as(isize, @bitCast(idx)))));
            }
            std.mem.doNotOptimizeAway(o);
        }
    }.run);
    printPairedRow("Object.setProperty [custom S attr]", set_prop_custom_ns, set_prop_default_ns);

    // 7. Object.getTypedIvar vs IvarSlot.get (lazy) vs IvarSlot.load (eager)
    const ivar_named_ns = measure(bench_obj, struct {
        fn run(o: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(o.getTypedIvar(*BenchState, "zig_state"));
            }
        }
    }.run);
    printRow("Object.getTypedIvar(*State) [by name]", ivar_named_ns, "baseline");

    const LazyIvarCtx = struct { o: objc.Object, slot: *objc.IvarSlot(*BenchState) };
    const ivar_lazy_ns = measure(LazyIvarCtx{ .o = bench_obj, .slot = &lazy_slot }, struct {
        fn run(c: LazyIvarCtx, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(c.slot.get(c.o, "zig_state"));
            }
        }
    }.run);
    printPairedRow("IvarSlot(*State).get [lazy atomic]", ivar_lazy_ns, ivar_named_ns);

    const EagerIvarCtx = struct { o: objc.Object, slot: objc.IvarSlot(*BenchState) };
    const ivar_eager_ns = measure(EagerIvarCtx{ .o = bench_obj, .slot = eager_slot }, struct {
        fn run(c: EagerIvarCtx, iters: usize) void {
            for (0..iters) |_| {
                std.mem.doNotOptimizeAway(c.slot.load(c.o));
            }
        }
    }.run);
    printPairedRow("IvarSlot(*State).load [eager offset]", ivar_eager_ns, ivar_named_ns);

    // 8. Iterator over empty NSArray vs 64-element NSArray (ns/iter and ns/item)
    const iter_empty_ns = measure(empty_arr, struct {
        fn run(arr: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                var it = arr.iterate();
                while (it.next()) |elem| {
                    std.mem.doNotOptimizeAway(elem);
                }
                std.mem.doNotOptimizeAway(&it);
            }
        }
    }.run);
    printRow("Iterator (empty NSArray)", iter_empty_ns, "ns/iter (0 items)");

    const iter_64_ns = measure(arr_64, struct {
        fn run(arr: objc.Object, iters: usize) void {
            for (0..iters) |_| {
                var it = arr.iterate();
                while (it.next()) |elem| {
                    std.mem.doNotOptimizeAway(elem);
                }
            }
        }
    }.run);
    var per_item_buf: [32]u8 = undefined;
    const per_item_note = std.fmt.bufPrint(&per_item_buf, "{d:.2} ns/item", .{iter_64_ns / 64.0}) catch unreachable;
    printRow("Iterator (64-elem NSArray, per iter)", iter_64_ns, per_item_note);
    printRow("Iterator (64-elem NSArray, per item)", iter_64_ns / 64.0, "64 items/iter");

    // 9. Block.invoke & BlockRef.invoke
    const blk_invoke_ns = measure(&stack_block, struct {
        fn run(ctx: *const AddBlock.Context, iters: usize) void {
            for (0..iters) |idx| {
                std.mem.doNotOptimizeAway(AddBlock.invoke(ctx, .{ @as(i64, @intCast(idx)), @as(i64, 5) }));
            }
        }
    }.run);
    printRow("Block.invoke", blk_invoke_ns, "baseline");

    const blk_ref_invoke_ns = measure(block_ref, struct {
        fn run(ref: AddBlock.Ref, iters: usize) void {
            for (0..iters) |idx| {
                std.mem.doNotOptimizeAway(ref.invoke(.{ @as(i64, @intCast(idx)), @as(i64, 5) }));
            }
        }
    }.run);
    printPairedRow("BlockRef.invoke", blk_ref_invoke_ns, blk_invoke_ns);

    // 10. AutoreleasePool init + deinit and non-throwing tryInvoke
    const pool_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |_| {
                const p = objc.AutoreleasePool.init();
                std.mem.doNotOptimizeAway(p);
                p.deinit();
            }
        }
    }.run);
    printRow("AutoreleasePool.init + deinit", pool_ns, "push + pop");

    const try_invoke_ns = measure({}, struct {
        fn run(_: void, iters: usize) void {
            for (0..iters) |idx| {
                const res = objc.tryInvoke(tryTargetAdd, .{ @as(i64, @intCast(idx)), @as(i64, 1) });
                std.mem.doNotOptimizeAway(res);
            }
        }
    }.run);
    printRow("tryInvoke (non-throwing @try/@catch)", try_invoke_ns, "zero-throw frame");

    const total_ms = @as(f64, @floatFromInt(nowNs() -| suite_start)) / 1_000_000.0;
    printFmt("+----------------------------------------------+-----------+-------------+--------------------+\n", .{});
    printFmt("Completed in {d:.2} ms\n", .{total_ms});
}
