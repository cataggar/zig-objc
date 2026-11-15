const std = @import("std");
const assert = std.debug.assert;
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

/// Opaque Mach-O image header type used by `copyImageHeaders` and `LoadImageFunc`.
pub const MachHeader = if (@hasDecl(c, "mach_header")) c.mach_header else opaque {};

/// Returns the file paths of all loaded Objective-C frameworks and dynamic
/// libraries (`objc_copyImageNames`).
///
/// The caller must free the returned slice with `objc.free`.
pub fn copyImageNames() [][*:0]const u8 {
    var count: c_uint = 0;
    const raw = c.objc_copyImageNames(&count);
    if (raw == null) return &.{};
    if (count == 0) {
        std.c.free(@ptrCast(@constCast(raw)));
        return &.{};
    }
    const ptr: [*][*:0]const u8 = @ptrCast(raw);
    return ptr[0..count];
}

const CopyImageHeadersFn = *const fn (*c_uint) callconv(.c) ?[*]const *const MachHeader;
const SetHookGetImageNameFn = *const fn (HookGetImageName, *HookGetImageName) callconv(.c) void;
const SetHookGetClassFn = *const fn (HookGetClass, *HookGetClass) callconv(.c) void;
const SetHookLazyClassNamerFn = *const fn (HookLazyClassNamer, *HookLazyClassNamer) callconv(.c) void;
const AddLoadImageFuncFn = *const fn (LoadImageFunc) callconv(.c) void;

/// Reports whether `objc_copyImageHeaders` is available in the running Objective-C runtime.
pub fn hasCopyImageHeaders() bool {
    return cpkg.weakExtern(?CopyImageHeadersFn, "objc_copyImageHeaders") != null;
}

/// Returns the Mach-O headers of all loaded images containing Objective-C or
/// Swift code (`objc_copyImageHeaders`).
///
/// The caller must free the returned slice with `objc.free`.
/// Weak-linked so binaries targeting older Apple OS versions launch cleanly;
/// returns `&.{}` when unavailable in the SDK or on the running OS version.
pub fn copyImageHeaders() []const *const MachHeader {
    const func = cpkg.weakExtern(?CopyImageHeadersFn, "objc_copyImageHeaders") orelse return &.{};
    var count: c_uint = 0;
    const raw = func(&count) orelse return &.{};
    if (count == 0) {
        std.c.free(@ptrCast(@constCast(raw)));
        return &.{};
    }
    return raw[0..count];
}

/// Returns the path of the dynamic library or framework `cls` originated from
/// (`class_getImageName`), or `null` if unavailable.
pub fn getImageName(cls: objc.Class) ?[:0]const u8 {
    const raw: ?[*:0]const u8 = c.class_getImageName(cls.value);
    return std.mem.sliceTo(raw orelse return null, 0);
}

/// Returns the names of all Objective-C classes within `image`
/// (`objc_copyClassNamesForImage`), or `null` if `image` is not loaded.
///
/// When non-null, the caller must free the returned slice with `objc.free`.
pub fn copyClassNamesForImage(image: [:0]const u8) ?[][*:0]const u8 {
    var count: c_uint = 0;
    const raw = c.objc_copyClassNamesForImage(image.ptr, &count);
    if (raw == null) return null;
    if (count == 0) {
        std.c.free(@ptrCast(@constCast(raw)));
        return &.{};
    }
    const ptr: [*][*:0]const u8 = @ptrCast(raw);
    return ptr[0..count];
}

/// Handler signature invoked when a mutation is detected during fast enumeration.
pub const EnumerationMutationHandler = ?*const fn (c.id) callconv(.c) void;

/// Installs the global enumeration mutation handler (`objc_setEnumerationMutationHandler`).
/// Passing `null` restores the runtime's default fatal handler.
pub fn setEnumerationMutationHandler(handler: EnumerationMutationHandler) void {
    c.objc_setEnumerationMutationHandler(handler);
}

/// Triggers an enumeration mutation notification for `obj` (`objc_enumerationMutation`).
/// Note: aborts the process unless a custom handler has been installed via
/// `setEnumerationMutationHandler`.
pub fn enumerationMutation(obj: objc.Object) void {
    c.objc_enumerationMutation(obj.value);
}

/// Hook function type intercepting `class_getImageName` (`objc_hook_getImageName`).
pub const HookGetImageName = if (@hasDecl(c, "objc_hook_getImageName"))
    c.objc_hook_getImageName
else
    ?*const fn (c.Class, [*c][*c]const u8) callconv(.c) c.BOOL;

/// Reports whether `objc_setHook_getImageName` is available in the running Objective-C runtime.
pub fn hasSetHookGetImageName() bool {
    return cpkg.weakExtern(?SetHookGetImageNameFn, "objc_setHook_getImageName") != null;
}

/// Installs a hook for `class_getImageName` (`objc_setHook_getImageName`), storing
/// the previous hook in `out_old_value`. Unrecognized classes must be delegated to
/// `out_old_value.*`. Weak-linked for older deployment targets; sets `out_old_value.* = null`
/// and no-ops if unavailable at runtime.
pub fn setHookGetImageName(new_value: HookGetImageName, out_old_value: *HookGetImageName) void {
    assert(new_value != null);
    if (cpkg.weakExtern(?SetHookGetImageNameFn, "objc_setHook_getImageName")) |func| {
        func(new_value, out_old_value);
    } else {
        out_old_value.* = null;
    }
}

/// Hook function type assisting `objc_getClass` lookups (`objc_hook_getClass`).
pub const HookGetClass = if (@hasDecl(c, "objc_hook_getClass"))
    c.objc_hook_getClass
else
    ?*const fn ([*c]const u8, [*c]c.Class) callconv(.c) c.BOOL;

/// Reports whether `objc_setHook_getClass` is available in the running Objective-C runtime.
pub fn hasSetHookGetClass() bool {
    return cpkg.weakExtern(?SetHookGetClassFn, "objc_setHook_getClass") != null;
}

/// Installs a hook for `objc_getClass` (`objc_setHook_getClass`), storing the
/// previous hook in `out_old_value`. Unrecognized class names must be delegated
/// to `out_old_value.*`. Weak-linked for older deployment targets; sets `out_old_value.* = null`
/// and no-ops if unavailable at runtime.
pub fn setHookGetClass(new_value: HookGetClass, out_old_value: *HookGetClass) void {
    assert(new_value != null);
    if (cpkg.weakExtern(?SetHookGetClassFn, "objc_setHook_getClass")) |func| {
        func(new_value, out_old_value);
    } else {
        out_old_value.* = null;
    }
}

/// Hook function type providing names for lazily-named classes (`objc_hook_lazyClassNamer`).
pub const HookLazyClassNamer = if (@hasDecl(c, "objc_hook_lazyClassNamer"))
    c.objc_hook_lazyClassNamer
else
    ?*const fn (c.Class) callconv(.c) [*c]const u8;

/// Reports whether `objc_setHook_lazyClassNamer` is available in the running Objective-C runtime.
pub fn hasSetHookLazyClassNamer() bool {
    return cpkg.weakExtern(?SetHookLazyClassNamerFn, "objc_setHook_lazyClassNamer") != null;
}

/// Installs a hook for lazily-named classes (`objc_setHook_lazyClassNamer`),
/// storing the previous hook in `out_old_value`. Unrecognized classes must be
/// delegated to `out_old_value.*`. Weak-linked for older deployment targets; sets
/// `out_old_value.* = null` and no-ops if unavailable at runtime.
pub fn setHookLazyClassNamer(new_value: HookLazyClassNamer, out_old_value: *HookLazyClassNamer) void {
    assert(new_value != null);
    if (cpkg.weakExtern(?SetHookLazyClassNamerFn, "objc_setHook_lazyClassNamer")) |func| {
        func(new_value, out_old_value);
    } else {
        out_old_value.* = null;
    }
}

/// Callback invoked for each loaded Objective-C image (`objc_func_loadImage`).
/// Called with the Objective-C runtime's internal lock held.
pub const LoadImageFunc = if (@hasDecl(c, "objc_func_loadImage"))
    c.objc_func_loadImage
else
    ?*const fn (?*const MachHeader) callconv(.c) void;

/// Reports whether `objc_addLoadImageFunc` is available in the running Objective-C runtime.
pub fn hasAddLoadImageFunc() bool {
    return cpkg.weakExtern(?AddLoadImageFuncFn, "objc_addLoadImageFunc") != null;
}

/// Registers `func` to be invoked immediately for all currently loaded Objective-C
/// images and subsequently before `+load` for newly loaded images (`objc_addLoadImageFunc`).
/// Weak-linked for older deployment targets; no-ops if unavailable at runtime.
pub fn addLoadImageFunc(func: LoadImageFunc) void {
    assert(func != null);
    if (cpkg.weakExtern(?AddLoadImageFuncFn, "objc_addLoadImageFunc")) |func_ptr| {
        func_ptr(func);
    }
}

test "copyImageNames returns loaded runtime images" {
    const testing = std.testing;

    const names = copyImageNames();
    defer objc.free(names);
    try testing.expect(names.len > 0);

    var found_core_image = false;
    for (names) |raw_name| {
        const name = std.mem.span(raw_name);
        if (std.mem.endsWith(u8, name, "libobjc.A.dylib") or
            std.mem.endsWith(u8, name, "Foundation"))
        {
            found_core_image = true;
            break;
        }
    }
    try testing.expect(found_core_image);
}

test "getImageName and copyClassNamesForImage" {
    const testing = std.testing;

    try testing.expect(getImageName(.{ .value = null }) == null);

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;
    const img_name = getImageName(NSObject) orelse return error.ImageNameNotFound;
    try testing.expect(img_name.len > 0);

    const class_names = copyClassNamesForImage(img_name) orelse return error.ClassNamesNotFound;
    defer objc.free(class_names);
    try testing.expect(class_names.len > 0);

    var found_nsobject = false;
    for (class_names) |raw_cls| {
        if (std.mem.eql(u8, std.mem.span(raw_cls), "NSObject")) {
            found_nsobject = true;
            break;
        }
    }
    try testing.expect(found_nsobject);

    try testing.expect(copyClassNamesForImage("/nonexistent/image/path.dylib") == null);
}

test "copyImageHeaders" {
    const testing = std.testing;

    const headers = copyImageHeaders();
    defer objc.free(headers);

    if (hasCopyImageHeaders()) {
        try testing.expect(headers.len > 0);
        // Every header must coerce cleanly to *const anyopaque (used by objc_enumerateClasses)
        // and point to a valid Mach-O header in memory.
        const first_opaque: *const anyopaque = headers[0];
        try testing.expect(@intFromPtr(first_opaque) != 0);
        if (@sizeOf(usize) == 8) {
            const magic: *const u32 = @ptrCast(@alignCast(headers[0]));
            try testing.expectEqual(std.macho.MH_MAGIC_64, magic.*);
        }
    } else {
        try testing.expectEqual(@as(usize, 0), headers.len);
    }
}

test "setEnumerationMutationHandler and enumerationMutation" {
    const testing = std.testing;

    const State = struct {
        threadlocal var mutated: bool = false;
        threadlocal var mutated_id: c.id = null;

        fn handler(obj_id: c.id) callconv(.c) void {
            mutated = true;
            mutated_id = obj_id;
        }
    };

    State.mutated = false;
    State.mutated_id = null;

    setEnumerationMutationHandler(&State.handler);
    defer setEnumerationMutationHandler(null);

    const NSObject = objc.getClass("NSObject").?;
    const obj = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer obj.release();

    enumerationMutation(obj);

    try testing.expect(State.mutated);
    try testing.expectEqual(obj.value, State.mutated_id);
}

test "setHookGetClass intercepts unknown classes and preserves normal lookup" {
    if (!hasSetHookGetClass()) return;
    const testing = std.testing;

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    const State = struct {
        var old_hook: HookGetClass = null;
        var fallback_class: c.Class = null;
        var observed_delegate_lookup: bool = false;
        var observed_resolved_lookup: bool = false;

        fn hook(name: [*c]const u8, out_class: [*c]c.Class) callconv(.c) c.BOOL {
            if (name != null) {
                const slice = std.mem.span(name);
                if (std.mem.eql(u8, slice, "ZigObjCNonExistentHookTestClass_999")) {
                    observed_delegate_lookup = true;
                } else if (std.mem.eql(u8, slice, "ZigObjCNonExistentHookResolveClass_999")) {
                    observed_resolved_lookup = true;
                    out_class.* = fallback_class;
                    return cpkg.boolParam(fallback_class != null);
                }
            }
            if (old_hook) |prev| {
                return prev(name, out_class);
            }
            out_class.* = null;
            return cpkg.boolParam(false);
        }
    };

    State.old_hook = null;
    State.fallback_class = NSObject.value;
    State.observed_delegate_lookup = false;
    State.observed_resolved_lookup = false;

    setHookGetClass(&State.hook, &State.old_hook);
    defer if (State.old_hook) |prev| {
        var discarded: HookGetClass = null;
        setHookGetClass(prev, &discarded);
    };

    // Unknown class delegated to old_hook returns null after firing hook.
    try testing.expect(objc.getClass("ZigObjCNonExistentHookTestClass_999") == null);
    try testing.expect(State.observed_delegate_lookup);

    // Unknown class resolved by hook returns fallback class.
    const resolved = objc.getClass("ZigObjCNonExistentHookResolveClass_999");
    try testing.expect(State.observed_resolved_lookup);
    try testing.expect(resolved != null);
    try testing.expectEqual(NSObject.value, resolved.?.value);

    // Normal class lookup remains intact while hook is installed.
    try testing.expectEqual(NSObject.value, objc.getClass("NSObject").?.value);

    // Explicitly restore and verify post-restore behavior as well.
    if (State.old_hook) |prev| {
        var discarded: HookGetClass = null;
        setHookGetClass(prev, &discarded);
        State.old_hook = null;
    }

    try testing.expectEqual(NSObject.value, objc.getClass("NSObject").?.value);
    try testing.expect(objc.getClass("ZigObjCNonExistentHookResolveClass_999") == null);
}

test "setHookGetImageName intercepts target class and delegates others" {
    if (!hasSetHookGetImageName()) return;
    const testing = std.testing;

    const NSObject = objc.getClass("NSObject").?;
    const expected_nsobject_img = getImageName(NSObject) orelse return error.ImageNameNotFound;

    const dyn_cls = objc.allocateClassPair(NSObject, "ZigObjCHookImageNameTestClass_999") orelse return error.AllocateClassFailed;
    objc.registerClassPair(dyn_cls);
    defer objc.disposeClassPair(dyn_cls);

    const State = struct {
        var old_hook: HookGetImageName = null;
        var target_cls: c.Class = null;
        const custom_image: [:0]const u8 = "/virtual/zig-objc-hook-test.dylib";

        fn hook(cls: c.Class, out_image_name: [*c][*c]const u8) callconv(.c) c.BOOL {
            if (cls != null and cls == target_cls) {
                out_image_name.* = custom_image.ptr;
                return cpkg.boolParam(true);
            }
            if (old_hook) |prev| {
                return prev(cls, out_image_name);
            }
            out_image_name.* = null;
            return cpkg.boolParam(false);
        }
    };

    State.old_hook = null;
    State.target_cls = dyn_cls.value;

    setHookGetImageName(&State.hook, &State.old_hook);
    defer if (State.old_hook) |prev| {
        var discarded: HookGetImageName = null;
        setHookGetImageName(prev, &discarded);
    };

    try testing.expectEqualStrings(State.custom_image, getImageName(dyn_cls).?);
    try testing.expectEqualStrings(expected_nsobject_img, getImageName(NSObject).?);
}

test "setHookLazyClassNamer installs and restores hook" {
    if (!hasSetHookLazyClassNamer()) return;
    const testing = std.testing;

    const State = struct {
        var old_hook: HookLazyClassNamer = null;

        fn hook(cls: c.Class) callconv(.c) [*c]const u8 {
            if (old_hook) |prev| {
                return prev(cls);
            }
            return null;
        }
    };

    State.old_hook = null;
    setHookLazyClassNamer(&State.hook, &State.old_hook);
    defer if (State.old_hook) |prev| {
        var discarded: HookLazyClassNamer = null;
        setHookLazyClassNamer(prev, &discarded);
    };

    try testing.expect(State.old_hook != null);
}

test "addLoadImageFunc invokes callback for currently loaded images" {
    if (!hasAddLoadImageFunc()) return;
    const testing = std.testing;

    const State = struct {
        var count: std.atomic.Value(usize) = .init(0);

        fn onLoad(header: ?*const MachHeader) callconv(.c) void {
            if (header != null) {
                _ = count.fetchAdd(1, .monotonic);
            }
        }
    };

    addLoadImageFunc(&State.onLoad);
    try testing.expect(State.count.load(.monotonic) > 0);
}

comptime {
    if (@hasDecl(c, "objc_hook_getImageName")) {
        assert(HookGetImageName == ?*const fn (c.Class, [*c][*c]const u8) callconv(.c) c.BOOL);
    }
    if (@hasDecl(c, "objc_hook_getClass")) {
        assert(HookGetClass == ?*const fn ([*c]const u8, [*c]c.Class) callconv(.c) c.BOOL);
    }
    if (@hasDecl(c, "objc_hook_lazyClassNamer")) {
        assert(HookLazyClassNamer == ?*const fn (c.Class) callconv(.c) [*c]const u8);
    }
    if (@hasDecl(c, "objc_func_loadImage")) {
        assert(LoadImageFunc == ?*const fn (?*const MachHeader) callconv(.c) void);
    }
}

test {
    std.testing.refAllDecls(@This());
}
