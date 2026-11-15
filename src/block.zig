const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const abi = @import("abi.zig");
const cpkg = @import("c.zig");
const c = cpkg.c;
const objc = @import("main.zig");

/// Flags passed to `_Block_object_assign` and `_Block_object_dispose`
/// describing the kind of captured reference (`<Block_private.h>`).
///
/// https://github.com/llvm/llvm-project/blob/734d31a464e204db699c1cf9433494926deb2aa2/compiler-rt/lib/BlocksRuntime/Block_private.h#L101-L108
pub const BlockFieldFlags = enum(c_int) {
    object = 3,
    block = 7,
    byref = 8,
    weak = 16,
    byref_caller = 128,
    _,

    pub const BLOCK_FIELD_IS_OBJECT: BlockFieldFlags = .object;
    pub const BLOCK_FIELD_IS_BLOCK: BlockFieldFlags = .block;
    pub const BLOCK_FIELD_IS_BYREF: BlockFieldFlags = .byref;
    pub const BLOCK_FIELD_IS_WEAK: BlockFieldFlags = .weak;
    pub const BLOCK_BYREF_CALLER: BlockFieldFlags = .byref_caller;

    pub fn combine(a: BlockFieldFlags, b: BlockFieldFlags) BlockFieldFlags {
        return @fromBackingInt(@intCast(@backingInt(a) | @backingInt(b)));
    }
};

/// Clang Block ABI header (`struct Block_layout`).
pub const BlockLayout = extern struct {
    pub const is_objc_block_context = true;

    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
    descriptor: *anyopaque,
};

/// Copies a block to the heap (or increments its reference count if already on the heap).
/// Global blocks are returned unchanged; `null` returns `null`.
pub fn blockCopy(block: ?*const anyopaque) ?*anyopaque {
    return c._Block_copy(block);
}

/// Releases a heap-allocated block (no-op for global blocks or `null`).
pub fn blockRelease(block: ?*const anyopaque) void {
    c._Block_release(block);
}

/// Retains or copies a captured Objective-C object, nested block, or `__block` variable.
pub fn objectAssign(dst: *anyopaque, src: ?*const anyopaque, flags: BlockFieldFlags) void {
    c._Block_object_assign(dst, src, @backingInt(flags));
}

/// Releases or disposes a captured Objective-C object, nested block, or `__block` variable.
pub fn objectDispose(object: ?*const anyopaque, flags: BlockFieldFlags) void {
    c._Block_object_dispose(object, @backingInt(flags));
}

/// Creates a method `IMP` trampoline backed by an Objective-C block.
///
/// The block's parameters (after its block context pointer) must be `(receiver, method_args...)`
/// without a `_cmd: SEL` parameter. Accepts `*Block(...).Context`, `*const Block(...).Context`,
/// `BlockRef(...)`, `objc.Object`, `c.id`, or `*anyopaque`.
pub fn impImplementationWithBlock(block: anytype) c.IMP {
    const T = @TypeOf(block);
    const id_ptr: c.id = switch (T) {
        c.id => block,
        objc.Object => block.value,
        *anyopaque, *const anyopaque => objc.Object.fromId(@constCast(block)).value,
        else => switch (@typeInfo(T)) {
            .@"struct" => if (comptime abi.isBlockRefType(T))
                objc.Object.fromId(block.value).value
            else
                @compileError("impImplementationWithBlock expected *Block.Context, BlockRef, Object, c.id, or *anyopaque, got " ++ @typeName(T)),
            .pointer => |ptr_info| if (ptr_info.size == .one and comptime abi.isBlockContextStruct(ptr_info.child))
                objc.Object.fromId(@as(*anyopaque, @ptrCast(@constCast(block)))).value
            else
                @compileError("impImplementationWithBlock expected *Block.Context, BlockRef, Object, c.id, or *anyopaque, got " ++ @typeName(T)),
            else => @compileError("impImplementationWithBlock expected *Block.Context, BlockRef, Object, c.id, or *anyopaque, got " ++ @typeName(T)),
        },
    };
    assert(id_ptr != null);
    return c.imp_implementationWithBlock(id_ptr);
}

/// Returns the block associated with an `IMP` created via `impImplementationWithBlock`,
/// or `null` if `imp` is not a block-backed trampoline.
pub fn impGetBlock(imp: c.IMP) ?objc.Object {
    const raw = c.imp_getBlock(imp);
    if (raw == null) return null;
    return objc.Object.fromId(raw);
}

/// Disassociates and releases the block backing `imp` (created via `impImplementationWithBlock`).
pub fn impRemoveBlock(imp: c.IMP) bool {
    return cpkg.boolResult(c.imp_removeBlock(imp));
}

/// A typed reference to an Objective-C / Clang block (`Return (^)(Args...)`).
///
/// `BlockRef` is an `extern struct` wrapping a single non-null `*anyopaque` block pointer,
/// making it ABI-identical to a raw Objective-C block pointer / `id` across C callbacks,
/// Objective-C `IMP` method implementations, and `msgSend` arguments and return values.
pub fn BlockRef(comptime Args: anytype, comptime Return: type) type {
    const param_types = extractParamTypes(Args);

    return extern struct {
        const Self = @This();

        pub const is_objc_block = true;
        pub const zig_objc_is_block_ref = true;
        pub const ReturnType = Return;
        pub const InvokeFn = BlockRefInvokeFn(&param_types, Return);

        value: *anyopaque,

        /// Wraps a nullable raw block pointer, returning `null` if `ptr` is `null`.
        pub inline fn fromPtr(ptr: ?*const anyopaque) ?Self {
            const p = ptr orelse return null;
            return .{ .value = @constCast(p) };
        }

        /// Wraps a nullable Objective-C `id`, returning `null` if `id` is `null`.
        pub inline fn fromId(id: c.id) ?Self {
            if (id == null) return null;
            return .{ .value = @ptrCast(id) };
        }

        /// Wraps a non-null `objc.Object` representing a block.
        pub inline fn fromObject(obj: objc.Object) Self {
            assert(obj.value != null);
            return .{ .value = @ptrCast(obj.value) };
        }

        /// Wraps a pointer (`*Context` or `*const Context`) to a Zig `Block` context.
        pub inline fn fromContext(ctx_ptr: anytype) Self {
            const Ptr = @TypeOf(ctx_ptr);
            const ptr_info = @typeInfo(Ptr);
            if (comptime (ptr_info != .pointer or ptr_info.pointer.size != .one or !abi.isBlockContextStruct(ptr_info.pointer.child))) {
                @compileError("BlockRef.fromContext expected a single-item pointer to a Block Context, got " ++ @typeName(Ptr));
            }
            return .{ .value = @ptrCast(@constCast(ctx_ptr)) };
        }

        /// Views this block as an `objc.Object` (`id`).
        pub inline fn asObject(self: Self) objc.Object {
            return objc.Object.fromId(self.value);
        }

        /// Invokes the underlying Clang/Objective-C block with `args`.
        pub inline fn invoke(self: Self, args: anytype) Return {
            const layout: *const BlockLayout = @ptrCast(@alignCast(self.value));
            const invoke_fn: *const InvokeFn = @ptrCast(@alignCast(layout.invoke));
            const call_args = abi.buildTypedCallArgs(.{self.value}, &param_types, args, true);
            return abi.wrapReturn(Return, @call(.auto, invoke_fn, call_args), true);
        }

        /// Copies the block to the heap (or increments its reference count) via `_Block_copy`,
        /// returning `error.OutOfMemory` if heap allocation fails. Pair with `release()`.
        pub fn tryCopy(self: Self) Allocator.Error!Self {
            const copied = c._Block_copy(self.value) orelse return error.OutOfMemory;
            return .{ .value = copied };
        }

        /// Copies the block to the heap (or increments its reference count) via `_Block_copy`,
        /// panicking on out-of-memory. Pair with `release()`.
        pub fn copy(self: Self) Self {
            return self.tryCopy() catch @panic("zig-objc: _Block_copy failed (out of memory)");
        }

        /// Releases a copied block via `_Block_release`.
        pub fn release(self: Self) void {
            c._Block_release(self.value);
        }
    };
}

/// Creates a new block type with captured (closed over) values.
///
/// `CapturesArg` is a struct of captured values made available to the block.
/// `Args` is a tuple (or array/slice) of invocation-time parameter types.
/// `Return` is the return type of the block.
///
/// Captured values of type `objc.Object`, `?objc.Object`, `objc.c.id`, `BlockRef(...)`,
/// `?BlockRef(...)`, and `*OtherBlock.Context` / `?*OtherBlock.Context` are automatically
/// retained/copied when the block is copied to the heap and released/disposed when the
/// heap block is released.
///
/// The callback function signature is available as `Fn`, whose first parameter is always
/// `*const Context`. When `Captures` is `struct {}` (stateless), `initGlobal` can also be
/// used to construct a static `_NSConcreteGlobalBlock` requiring no stack lifetime.
pub fn Block(
    comptime CapturesArg: type,
    comptime Args: anytype,
    comptime Return: type,
) type {
    comptime validateCaptures(CapturesArg);
    const param_types = extractParamTypes(Args);

    return struct {
        const Self = @This();
        pub const is_objc_block = true;

        const captures_info = @typeInfo(Captures).@"struct";
        const has_managed_captures = hasManagedCaptures(Captures);
        const DescriptorType = if (has_managed_captures) DescriptorWithCopyDispose else DescriptorSimple;

        const InvokeReturn = abi.UnwrapReturnType(Return, true);
        const InvokeFn = makeInvokeFnType(&param_types, Return);
        const SignatureFn = makeSignatureFnType(&param_types, Return);
        const needs_bool_trampoline = (c.BOOL != bool) and (Return == bool or hasBoolParam(&param_types));

        pub const signature_encoding = objc.comptimeEncode(SignatureFn);

        const descriptor: DescriptorType = if (has_managed_captures) .{
            .reserved = 0,
            .size = @sizeOf(Context),
            .copy_helper = &descCopyHelper,
            .dispose_helper = &descDisposeHelper,
            .signature = &signature_encoding,
        } else .{
            .reserved = 0,
            .size = @sizeOf(Context),
            .signature = &signature_encoding,
        };

        /// This is the function type that is called back.
        pub const Fn = makeUserFnType(Context, &param_types, Return);

        /// The captures type, so it can be easily referenced again.
        pub const Captures = CapturesArg;

        /// Matching `BlockRef` type for this block signature.
        pub const Ref = BlockRef(Args, Return);

        /// This is the block context sent as the first parameter to the function.
        pub const Context = BlockContext(Captures, InvokeFn, DescriptorType, needs_bool_trampoline);

        /// Create a new stack-allocated block context.
        ///
        /// Note that if `captures` contains Objective-C objects or nested blocks,
        /// they are retained/copied when the block is copied (automatically by
        /// Objective-C APIs that store blocks, or manually via `copy`).
        pub fn init(captures: Captures, func: *const Fn) Context {
            var ctx: Context = undefined;
            ctx.isa = NSConcreteStackBlock;
            ctx.flags = .{
                .copy_dispose = has_managed_captures,
                .stret = cpkg.usesStret(InvokeReturn),
                .signature = true,
            };
            ctx.reserved = 0;
            if (comptime needs_bool_trampoline) {
                ctx.invoke = comptime makeBoolTrampoline();
                ctx.__zig_objc_user_invoke = @ptrCast(func);
            } else {
                ctx.invoke = @ptrCast(func);
            }
            ctx.descriptor = &descriptor;
            inline for (captures_info.field_names, captures_info.field_types) |field_name, field_type| {
                @field(ctx, field_name) = storeCaptureField(field_type, @field(captures, field_name));
            }

            return ctx;
        }

        /// Creates a static global block (`_NSConcreteGlobalBlock` with `BLOCK_IS_GLOBAL`)
        /// for a zero-capture block (`Captures == struct {}`). Needs no stack lifetime
        /// and `_Block_copy` / `_Block_release` treat it as an immortal no-op.
        pub fn initGlobal(comptime func: *const Fn) *const Context {
            if (captures_info.field_types.len != 0) {
                @compileError("Block.initGlobal requires an empty Captures struct (struct {})");
            }
            const Static = struct {
                const global_ctx: Context = if (needs_bool_trampoline) .{
                    .isa = NSConcreteGlobalBlock,
                    .flags = .{
                        .copy_dispose = false,
                        .global = true,
                        .stret = cpkg.usesStret(InvokeReturn),
                        .signature = true,
                    },
                    .reserved = 0,
                    .invoke = makeBoolTrampoline(),
                    .descriptor = &descriptor,
                    .__zig_objc_user_invoke = @ptrCast(func),
                } else .{
                    .isa = NSConcreteGlobalBlock,
                    .flags = .{
                        .copy_dispose = false,
                        .global = true,
                        .stret = cpkg.usesStret(InvokeReturn),
                        .signature = true,
                    },
                    .reserved = 0,
                    .invoke = @ptrCast(func),
                    .descriptor = &descriptor,
                };
            };
            return &Static.global_ctx;
        }

        /// Reconstructs the typed `Captures` struct from `ctx` (converting stored raw `c.id` /
        /// pointer slots back into `objc.Object`, `?objc.Object`, `?BlockRef(...)`, etc.).
        pub fn getCaptures(ctx: *const Context) Captures {
            var result: Captures = undefined;
            inline for (captures_info.field_names, captures_info.field_types) |field_name, field_type| {
                @field(result, field_name) = loadCaptureField(field_type, @field(ctx, field_name));
            }
            return result;
        }

        /// Invoke the block with the given arguments beyond the captured scope.
        pub inline fn invoke(ctx: *const Context, args: anytype) Return {
            const call_args = abi.buildTypedCallArgs(
                .{@as(*const anyopaque, @ptrCast(ctx))},
                &param_types,
                args,
                true,
            );
            return abi.wrapReturn(Return, @call(.auto, ctx.invoke, call_args), true);
        }

        /// Copies the given context to the heap (or increments its reference count).
        /// Must be paired with `release`.
        pub fn copy(ctx: *const Context) Allocator.Error!*Context {
            const copied = c._Block_copy(@ptrCast(ctx)) orelse
                return error.OutOfMemory;
            return @ptrCast(@alignCast(copied));
        }

        /// Releases a copied (or global) block context. Asserts that `ctx` is not an
        /// uncopied stack block.
        pub fn release(ctx: *const Context) void {
            assert(@intFromPtr(ctx.isa) != @intFromPtr(NSConcreteStackBlock));
            c._Block_release(@ptrCast(ctx));
        }

        /// Wraps `ctx` in a typed `BlockRef(Args, Return)`.
        pub inline fn asBlockRef(ctx: *const Context) Ref {
            return Ref.fromContext(ctx);
        }

        /// Views `ctx` as an `objc.Object` (`id`).
        pub inline fn asObject(ctx: *const Context) objc.Object {
            return objc.Object.fromId(@as(*anyopaque, @ptrCast(@constCast(ctx))));
        }

        fn descCopyHelper(dst: *anyopaque, src: *anyopaque) callconv(.c) void {
            const real_dst: *Context = @ptrCast(@alignCast(dst));
            const real_src: *const Context = @ptrCast(@alignCast(src));
            inline for (captures_info.field_names, captures_info.field_types) |field_name, field_type| {
                const kind = comptime classifyCaptureType(field_type);
                if (kind != .plain) {
                    comptime assert(@sizeOf(@TypeOf(@field(real_dst, field_name))) == @sizeOf(*anyopaque));
                    const flag: c_int = switch (kind) {
                        .object => @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_OBJECT),
                        .block => @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_BLOCK),
                        .plain => unreachable,
                    };
                    if (extractRawCapturePtr(@field(real_src, field_name))) |src_ptr| {
                        c._Block_object_assign(
                            @ptrCast(&@field(real_dst, field_name)),
                            src_ptr,
                            flag,
                        );
                    } else {
                        clearRawCaptureField(&@field(real_dst, field_name));
                    }
                }
            }
        }

        fn descDisposeHelper(src: *anyopaque) callconv(.c) void {
            const real_src: *const Context = @ptrCast(@alignCast(src));
            inline for (captures_info.field_names, captures_info.field_types) |field_name, field_type| {
                const kind = comptime classifyCaptureType(field_type);
                if (kind != .plain) {
                    const flag: c_int = switch (kind) {
                        .object => @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_OBJECT),
                        .block => @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_BLOCK),
                        .plain => unreachable,
                    };
                    if (extractRawCapturePtr(@field(real_src, field_name))) |src_ptr| {
                        c._Block_object_dispose(src_ptr, flag);
                    }
                }
            }
        }

        inline fn userFnPtr(ctx: *const Context) *const Fn {
            return @ptrCast(@alignCast(ctx.__zig_objc_user_invoke));
        }

        inline fn fromRawInvokeParam(comptime T: type, raw: abi.UnwrapParamType(T, true)) cAbiBlockFnParamType(T) {
            if (comptime T == bool) return cpkg.boolResult(raw);
            if (comptime abi.isBlockRefType(T)) return T{ .value = raw };
            return raw;
        }

        inline fn toRawInvokeReturn(res: cAbiBlockFnReturnType(Return)) InvokeReturn {
            if (comptime Return == void) return;
            if (comptime Return == bool) return cpkg.boolParam(res);
            if (comptime abi.isBlockRefType(Return)) return res.value;
            return res;
        }

        /// Generates a zero-allocation `callconv(.c)` C-ABI trampoline on targets where
        /// Objective-C `BOOL` (`i8` on `x86_64`) differs from Zig `bool` (`_Bool`),
        /// converting non-`0/1` `BOOL` bytes safely before calling the user `Fn`.
        fn InvokeParam(comptime idx: usize) type {
            return abi.UnwrapParamType(param_types[idx], true);
        }

        fn makeBoolTrampoline() *const InvokeFn {
            const P = InvokeParam;
            const f = fromRawInvokeParam;
            const r = toRawInvokeReturn;
            return switch (param_types.len) {
                0 => &(struct {
                    fn call(raw_ctx: *const anyopaque) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx));
                    }
                }).call,
                1 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0)));
                    }
                }).call,
                2 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1)));
                    }
                }).call,
                3 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2)));
                    }
                }).call,
                4 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2), a3: P(3)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2), f(param_types[3], a3)));
                    }
                }).call,
                5 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2), f(param_types[3], a3), f(param_types[4], a4)));
                    }
                }).call,
                6 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2), f(param_types[3], a3), f(param_types[4], a4), f(param_types[5], a5)));
                    }
                }).call,
                7 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2), f(param_types[3], a3), f(param_types[4], a4), f(param_types[5], a5), f(param_types[6], a6)));
                    }
                }).call,
                8 => &(struct {
                    fn call(raw_ctx: *const anyopaque, a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7)) callconv(.c) InvokeReturn {
                        const ctx: *const Context = @ptrCast(@alignCast(raw_ctx));
                        return r(userFnPtr(ctx)(ctx, f(param_types[0], a0), f(param_types[1], a1), f(param_types[2], a2), f(param_types[3], a3), f(param_types[4], a4), f(param_types[5], a5), f(param_types[6], a6), f(param_types[7], a7)));
                    }
                }).call,
                else => @compileError("Block with bool parameters/return on targets where Objective-C BOOL != bool supports up to 8 parameters"),
            };
        }
    };
}

const CaptureKind = enum {
    plain,
    object,
    block,
};

fn isWeakValueType(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (@hasDecl(T, "zig_objc_is_weak")) return true;
    return @hasField(T, "slot") and
        (@hasDecl(T, "loadRetained") or @hasDecl(T, "loadAutoreleased") or @hasDecl(T, "load")) and
        @hasDecl(T, "deinit");
}

fn validateCaptures(comptime Captures: type) void {
    const info = switch (@typeInfo(Captures)) {
        .@"struct" => |s| s,
        else => @compileError("Block Captures must be a struct (use struct {} for no captures), got " ++ @typeName(Captures)),
    };
    if (info.is_tuple) {
        @compileError("Block Captures must be a named-field struct (use struct {} for no captures), got tuple " ++ @typeName(Captures));
    }
    for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attr| {
        if (std.mem.eql(u8, field_name, "__zig_objc_user_invoke")) {
            @compileError("Block capture field name '__zig_objc_user_invoke' is reserved");
        }
        const natural_align = if (@sizeOf(field_type) == 0) 1 else @alignOf(field_type);
        const explicit_align: usize = if (@typeInfo(@TypeOf(field_attr.@"align")) == .optional)
            (field_attr.@"align" orelse natural_align)
        else
            field_attr.@"align";
        if (@max(natural_align, explicit_align) > 16) {
            @compileError("Block captures cannot have alignment > 16 bytes because macOS _Block_copy uses 16-byte malloc alignment; capture a 16-byte aligned pointer instead");
        }
        validateCaptureFieldType(field_type, false);
    }
}

fn validateCapturePointerTarget(comptime Pointee: type) void {
    switch (@typeInfo(Pointee)) {
        .optional => |opt| {
            if (abi.WrapperUnderlying(opt.child) != null or abi.isBlockRefType(opt.child) or
                @typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice)
            {
                @compileError("pointer/array element " ++ @typeName(Pointee) ++ " is a 16-byte Zig optional struct, not an 8-byte C pointer; for Objective-C out-parameters like id* / NSError**, use *objc.Object (initialized to .{ .value = null }) or *objc.c.id");
            }
            validateCapturePointerTarget(@typeInfo(opt.child).pointer.child);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("C-ABI pointer/array element cannot be Zig slice " ++ @typeName(Pointee) ++ "; pass .ptr and .len");
            }
            validateCapturePointerTarget(ptr.child);
        },
        .array => |arr| validateCapturePointerTarget(arr.child),
        else => {},
    }
}

fn validateCaptureFieldType(comptime T: type, comptime nested_aggregate: bool) void {
    if (abi.isBlockContextStruct(T)) {
        @compileError("Block captures cannot store a Block.Context by value; capture *const Block.Context, BlockRef, or objc.Object instead");
    }
    if (isWeakValueType(T)) {
        @compileError("Block captures cannot store objc.Weak by value (memcpy would corrupt Objective-C weak side tables); capture *objc.Weak instead");
    }
    if (T == comptime_int) {
        @compileError("Block capture cannot have type comptime_int; cast to a concrete integer type with @as");
    }
    if (T == comptime_float) {
        @compileError("Block capture cannot have type comptime_float; cast to a concrete float type with @as");
    }
    if (@sizeOf(T) > 0 and @alignOf(T) > 16) {
        @compileError("Block captures cannot have alignment > 16 bytes because macOS _Block_copy uses 16-byte malloc alignment; capture a 16-byte aligned pointer instead");
    }
    if (nested_aggregate and classifyCaptureType(T) != .plain) {
        @compileError("Block captures cannot store ARC-managed objects or blocks inside a nested array, struct, or union (" ++ @typeName(T) ++ "); capture individual fields or a pointer instead");
    }
    if (abi.WrapperUnderlying(T) != null or abi.isBlockRefType(T)) return;

    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .vector => {},
        .array => |arr| validateCaptureFieldType(arr.child, true),
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                @compileError("Block captures cannot store Zig slice " ++ @typeName(T) ++ " by value; capture a pointer or separate .ptr and .len fields instead");
            }
            validateCapturePointerTarget(ptr.child);
        },
        .@"struct" => |s| {
            if (s.layout == .auto) {
                @compileError("Block captures cannot store auto-layout struct " ++ @typeName(T) ++ " by value; use an extern struct or capture *" ++ @typeName(T) ++ " instead");
            }
            for (s.field_types, s.field_attrs) |FieldType, field_attr| {
                if (s.layout == .@"extern") {
                    const nat = if (@sizeOf(FieldType) == 0) 1 else @alignOf(FieldType);
                    const exp: usize = if (@typeInfo(@TypeOf(field_attr.@"align")) == .optional)
                        (field_attr.@"align" orelse nat)
                    else
                        field_attr.@"align";
                    if (@max(nat, exp) > 16) {
                        @compileError("Block captures cannot have alignment > 16 bytes because macOS _Block_copy uses 16-byte malloc alignment; capture a 16-byte aligned pointer instead");
                    }
                }
                validateCaptureFieldType(FieldType, true);
            }
        },
        .@"union" => |u| {
            if (u.layout == .auto) {
                @compileError("Block captures cannot store auto-layout union " ++ @typeName(T) ++ " by value; use an extern union or capture *" ++ @typeName(T) ++ " instead");
            }
            for (u.field_types, u.field_attrs) |FieldType, field_attr| {
                if (u.layout == .@"extern") {
                    const nat = if (@sizeOf(FieldType) == 0) 1 else @alignOf(FieldType);
                    const exp: usize = if (@typeInfo(@TypeOf(field_attr.@"align")) == .optional)
                        (field_attr.@"align" orelse nat)
                    else
                        field_attr.@"align";
                    if (@max(nat, exp) > 16) {
                        @compileError("Block captures cannot have alignment > 16 bytes because macOS _Block_copy uses 16-byte malloc alignment; capture a 16-byte aligned pointer instead");
                    }
                }
                validateCaptureFieldType(FieldType, true);
            }
        },
        .optional => |opt| {
            if (abi.isBlockContextStruct(opt.child)) {
                @compileError("Block captures cannot store a Block.Context by value; capture ?*const Block.Context, ?BlockRef, or ?objc.Object instead");
            }
            if (isWeakValueType(opt.child)) {
                @compileError("Block captures cannot store objc.Weak by value (memcpy would corrupt Objective-C weak side tables); capture *objc.Weak instead");
            }
            if (abi.WrapperUnderlying(opt.child) != null or abi.isBlockRefType(opt.child)) return;
            if (@typeInfo(opt.child) != .pointer or @typeInfo(opt.child).pointer.size == .slice) {
                @compileError("Block captures cannot store non-pointer optional " ++ @typeName(T) ++ " by value; capture a pointer or separate flag and value fields instead");
            }
            validateCapturePointerTarget(@typeInfo(opt.child).pointer.child);
        },
        else => @compileError("Block captures do not support type " ++ @typeName(T) ++ "; capture a pointer or extern-compatible type instead"),
    }
}

fn classifyCaptureType(comptime T: type) CaptureKind {
    if (T == c.id or T == objc.Object or T == ?objc.Object) return .object;
    if (abi.isBlockRefType(T)) return .block;

    return switch (@typeInfo(T)) {
        .optional => |opt| if (abi.isBlockRefType(opt.child))
            .block
        else switch (@typeInfo(opt.child)) {
            .pointer => |ptr| if ((ptr.size == .one or ptr.size == .c) and abi.isBlockContextStruct(ptr.child))
                .block
            else
                .plain,
            else => .plain,
        },
        .pointer => |ptr| if ((ptr.size == .one or ptr.size == .c) and abi.isBlockContextStruct(ptr.child))
            .block
        else
            .plain,
        else => .plain,
    };
}

fn hasManagedCaptures(comptime Captures: type) bool {
    const info = @typeInfo(Captures).@"struct";
    for (info.field_types) |field_type| {
        if (classifyCaptureType(field_type) != .plain) return true;
    }
    return false;
}

fn hasBoolParam(comptime param_types: []const type) bool {
    for (param_types) |T| {
        if (T == bool) return true;
    }
    return false;
}

fn ContextFieldType(comptime T: type) type {
    if (abi.WrapperUnderlying(T)) |U| return U;
    return switch (@typeInfo(T)) {
        .optional => |opt| if (abi.WrapperUnderlying(opt.child)) |U|
            abi.NullablePtr(U)
        else if (abi.isBlockRefType(opt.child))
            ?*anyopaque
        else
            T,
        else => T,
    };
}

inline fn storeCaptureField(comptime FieldType: type, val: FieldType) ContextFieldType(FieldType) {
    if (comptime abi.WrapperUnderlying(FieldType) != null) return val.value;
    if (comptime @typeInfo(FieldType) == .optional) {
        const Child = @typeInfo(FieldType).optional.child;
        if (comptime (abi.WrapperUnderlying(Child) != null or abi.isBlockRefType(Child))) {
            return if (val) |v| v.value else null;
        }
    }
    return val;
}

inline fn loadCaptureField(comptime FieldType: type, stored: ContextFieldType(FieldType)) FieldType {
    if (FieldType == objc.Object) return objc.Object.fromId(stored);
    if (comptime abi.WrapperUnderlying(FieldType) != null) return FieldType{ .value = stored };
    if (comptime @typeInfo(FieldType) == .optional) {
        const Child = @typeInfo(FieldType).optional.child;
        if (Child == objc.Object) return if (stored == null) null else objc.Object.fromId(stored);
        if (comptime abi.isBlockRefType(Child)) {
            return if (stored) |p| Child{ .value = p } else null;
        }
        if (comptime abi.WrapperUnderlying(Child)) |U| {
            if (comptime (@typeInfo(U) == .optional or (@typeInfo(U) == .pointer and @typeInfo(U).pointer.size == .c))) {
                return if (stored == null) null else Child{ .value = stored };
            } else {
                return if (stored) |p| Child{ .value = p } else null;
            }
        }
    }
    return stored;
}

inline fn extractRawCapturePtr(stored: anytype) ?*const anyopaque {
    const T = @TypeOf(stored);
    if (comptime abi.isBlockRefType(T)) return stored.value;
    return switch (@typeInfo(T)) {
        .optional => if (stored) |p| @ptrCast(p) else null,
        .pointer => |ptr| switch (ptr.size) {
            .c => if (stored == null) null else @ptrCast(stored),
            .one => @ptrCast(stored),
            else => unreachable,
        },
        else => unreachable,
    };
}

inline fn clearRawCaptureField(slot: anytype) void {
    const SlotType = @typeInfo(@TypeOf(slot)).pointer.child;
    switch (@typeInfo(SlotType)) {
        .optional => slot.* = null,
        .pointer => |ptr| if (ptr.size == .c) {
            slot.* = null;
        },
        else => {},
    }
}

fn extractParamTypes(comptime Args: anytype) [Args.len]type {
    var result: [Args.len]type = undefined;
    for (Args, 0..) |Arg, i| result[i] = Arg;
    return result;
}

/// Validates and maps `Block` parameter types for `Block.Fn`, keeping Zig `bool` and
/// `BlockRef(...)` intact while unwrapping `objc` runtime wrappers to their C-ABI pointers.
fn cAbiBlockFnParamType(comptime T: type) type {
    if (abi.isBlockRefType(T)) return T;
    return abi.UnwrapParamType(T, false);
}

/// Validates and maps `Block` return types for `Block.Fn`, keeping Zig `bool`, `BlockRef(...)`,
/// and `*c.Protocol` intact while unwrapping `objc` runtime wrappers.
fn cAbiBlockFnReturnType(comptime T: type) type {
    if (T == void) return void;
    if (abi.isBlockRefType(T)) return T;
    if (T == objc.Protocol) return *c.Protocol;
    return abi.UnwrapReturnType(T, false);
}

fn makeUserFnType(comptime ContextArg: type, comptime param_types: []const type, comptime Return: type) type {
    var fn_params: [param_types.len + 1]type = undefined;
    fn_params[0] = *const ContextArg;
    for (param_types, 1..) |Arg, i| fn_params[i] = cAbiBlockFnParamType(Arg);
    return @Fn(&fn_params, &@splat(.{}), cAbiBlockFnReturnType(Return), .{ .@"callconv" = .c });
}

fn makeInvokeFnType(comptime param_types: []const type, comptime Return: type) type {
    var fn_params: [param_types.len + 1]type = undefined;
    fn_params[0] = *const anyopaque;
    for (param_types, 1..) |Arg, i| fn_params[i] = abi.UnwrapParamType(Arg, true);
    return @Fn(&fn_params, &@splat(.{}), abi.UnwrapReturnType(Return, true), .{ .@"callconv" = .c });
}

fn signatureParamType(comptime T: type) type {
    if (abi.isBlockRefType(T)) return *const BlockLayout;
    if (@typeInfo(T) == .optional and abi.isBlockRefType(@typeInfo(T).optional.child)) {
        return ?*const BlockLayout;
    }
    return abi.UnwrapParamType(T, true);
}

fn signatureReturnType(comptime T: type) type {
    if (T == void) return void;
    if (abi.isBlockRefType(T)) return *const BlockLayout;
    if (@typeInfo(T) == .optional and abi.isBlockRefType(@typeInfo(T).optional.child)) {
        return ?*const BlockLayout;
    }
    return abi.UnwrapReturnType(T, true);
}

fn makeSignatureFnType(comptime param_types: []const type, comptime Return: type) type {
    var fn_params: [param_types.len + 1]type = undefined;
    fn_params[0] = *const BlockLayout;
    for (param_types, 1..) |Arg, i| fn_params[i] = signatureParamType(Arg);
    return @Fn(&fn_params, &@splat(.{}), signatureReturnType(Return), .{ .@"callconv" = .c });
}

fn BlockRefInvokeFn(comptime param_types: []const type, comptime Return: type) type {
    var fn_params: [param_types.len + 1]type = undefined;
    fn_params[0] = *anyopaque;
    for (param_types, 1..) |T, i| fn_params[i] = abi.UnwrapParamType(T, true);
    return @Fn(&fn_params, &@splat(.{}), abi.UnwrapReturnType(Return, true), .{ .@"callconv" = .c });
}

/// This is the type of a block structure that is passed as the first
/// argument to any block invocation. See Block.
fn BlockContext(
    comptime Captures: type,
    comptime InvokeFn: type,
    comptime DescriptorType: type,
    comptime needs_bool_trampoline: bool,
) type {
    const captures_info = @typeInfo(Captures).@"struct";
    if (captures_info.field_types.len == 0 and !needs_bool_trampoline) {
        return extern struct {
            pub const is_objc_block_context = true;

            isa: ?*anyopaque,
            flags: BlockFlags,
            reserved: c_int,
            invoke: *const InvokeFn,
            descriptor: *const DescriptorType,
        };
    }

    const extra_fields: usize = if (needs_bool_trampoline) 1 else 0;
    const field_count = captures_info.field_types.len + 5 + extra_fields;

    var field_names: [field_count][]const u8 = undefined;
    var field_types: [field_count]type = undefined;
    var field_attrs: [field_count]std.lang.Type.Struct.FieldAttributes = undefined;

    field_names[0] = "isa";
    field_types[0] = ?*anyopaque;
    field_attrs[0] = .{
        .default_value_ptr = null,
        .@"comptime" = false,
        .@"align" = @alignOf(*anyopaque),
    };
    field_names[1] = "flags";
    field_types[1] = BlockFlags;
    field_attrs[1] = .{
        .default_value_ptr = null,
        .@"comptime" = false,
        .@"align" = @alignOf(c_int),
    };
    field_names[2] = "reserved";
    field_types[2] = c_int;
    field_attrs[2] = .{
        .default_value_ptr = null,
        .@"comptime" = false,
        .@"align" = @alignOf(c_int),
    };
    field_names[3] = "invoke";
    field_types[3] = *const InvokeFn;
    field_attrs[3] = .{
        .default_value_ptr = null,
        .@"comptime" = false,
        .@"align" = @typeInfo(*const InvokeFn).pointer.attrs.@"align",
    };
    field_names[4] = "descriptor";
    field_types[4] = *const DescriptorType;
    field_attrs[4] = .{
        .default_value_ptr = null,
        .@"comptime" = false,
        .@"align" = @alignOf(*DescriptorType),
    };

    for (
        captures_info.field_names,
        captures_info.field_types,
        captures_info.field_attrs,
        5..,
    ) |field_name, field_type, field_attr, i| {
        const StoredType = ContextFieldType(field_type);
        field_names[i] = field_name;
        field_types[i] = StoredType;
        field_attrs[i] = .{
            .default_value_ptr = null,
            .@"comptime" = false,
            .@"align" = if (StoredType == field_type) field_attr.@"align" else @alignOf(StoredType),
        };
    }

    if (needs_bool_trampoline) {
        const fn_slot = 5 + captures_info.field_types.len;
        field_names[fn_slot] = "__zig_objc_user_invoke";
        field_types[fn_slot] = *const anyopaque;
        field_attrs[fn_slot] = .{
            .default_value_ptr = null,
            .@"comptime" = false,
            .@"align" = @alignOf(*anyopaque),
        };
    }

    return @Struct(.@"extern", null, &field_names, &field_types, &field_attrs);
}

// Pointer to opaque instead of anyopaque: https://github.com/ziglang/zig/issues/18461
const NSConcreteStackBlock = @extern(*opaque {}, .{ .name = "_NSConcreteStackBlock" });
const NSConcreteMallocBlock = @extern(*opaque {}, .{ .name = "_NSConcreteMallocBlock" });
const NSConcreteGlobalBlock = @extern(*opaque {}, .{ .name = "_NSConcreteGlobalBlock" });

const DescriptorSimple = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
    signature: ?[*:0]const u8,
};

const DescriptorWithCopyDispose = extern struct {
    reserved: c_ulong = 0,
    size: c_ulong,
    copy_helper: *const fn (dst: *anyopaque, src: *anyopaque) callconv(.c) void,
    dispose_helper: *const fn (src: *anyopaque) callconv(.c) void,
    signature: ?[*:0]const u8,
};

const BlockFlags = packed struct(c_int) {
    _unused: u23 = 0,
    noescape: bool = false,
    _unused_2: u1 = 0,
    copy_dispose: bool = false,
    ctor: bool = false,
    _unused_3: u1 = 0,
    global: bool = false,
    stret: bool = false,
    signature: bool = false,
    _unused_4: u1 = 0,
};

test "Block" {
    const AddBlock = Block(struct {
        x: i32,
        y: i32,
    }, .{}, i32);

    const captures: AddBlock.Captures = .{
        .x = 2,
        .y = 3,
    };

    var block: AddBlock.Context = AddBlock.init(captures, (struct {
        fn addFn(block: *const AddBlock.Context) callconv(.c) i32 {
            return block.x + block.y;
        }
    }).addFn);

    const ret = AddBlock.invoke(&block, .{});
    try std.testing.expectEqual(@as(i32, 5), ret);

    // Try copy and release
    const copied = try AddBlock.copy(&block);
    AddBlock.release(copied);
}

test "Block copy objc id" {
    // Create an object, refcount 1
    const NSObject = objc.getClass("NSObject").?;
    const obj = NSObject.msgSend(
        objc.Object,
        objc.Sel.registerName("alloc"),
        .{},
    );
    _ = obj.msgSend(objc.Object, objc.Sel.registerName("init"), .{});
    defer obj.release();

    const TestBlock = Block(struct {
        id: objc.c.id,
    }, .{}, objc.c.id);

    var block = TestBlock.init(.{
        .id = obj.value,
    }, (struct {
        fn blockFn(block: *const TestBlock.Context) callconv(.c) objc.c.id {
            return block.id;
        }
    }).blockFn);

    // Copy the block — this exercises descCopyHelper(dst, src).
    // If dst/src are swapped, the copied block's captured id will be garbage
    // rather than obj.value, and invoke will return the wrong pointer.
    const copied = try TestBlock.copy(&block);
    defer TestBlock.release(copied);

    const result = TestBlock.invoke(copied, .{});
    try std.testing.expectEqual(obj.value, result);
}

test "NSString enumerateLinesUsingBlock:" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClass("NSString").?;
    const text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"alpha\nbeta\ngamma\ndelta"});

    var line_count: usize = 0;
    var total_len: usize = 0;

    const LineBlock = Block(struct {
        count: *usize,
        len_sum: *usize,
    }, .{ objc.c.id, *bool }, void);

    var blk = LineBlock.init(.{
        .count = &line_count,
        .len_sum = &total_len,
    }, (struct {
        fn onLine(ctx: *const LineBlock.Context, line_id: objc.c.id, stop: *bool) callconv(.c) void {
            const line = objc.Object.fromId(line_id);
            ctx.count.* += 1;
            ctx.len_sum.* += line.msgSend(usize, "length", .{});
            if (ctx.count.* == 3) stop.* = true;
        }
    }).onLine);

    text.msgSend(void, "enumerateLinesUsingBlock:", .{&blk});
    try std.testing.expectEqual(@as(usize, 3), line_count);
    try std.testing.expectEqual(@as(usize, 5 + 4 + 5), total_len);
}

test "comptimeEncode for Block, Block.Context, BlockLayout, and BlockRef" {
    const MyBlock = Block(struct { x: i32 }, .{i32}, bool);
    const ZeroBlock = Block(struct {}, .{i32}, bool);
    const RefType = BlockRef(.{i32}, bool);

    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(*MyBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(*const MyBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?*MyBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?*const MyBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(*ZeroBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?*ZeroBlock.Context)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(*BlockLayout)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?*BlockLayout)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(MyBlock)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?MyBlock)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(RefType)));
    try std.testing.expectEqualStrings("@?", &(comptime objc.comptimeEncode(?RefType)));
}

test "BlockRef invokes Zig blocks, heap blocks, and genuine Foundation blocks" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSString = objc.getClass("NSString").?;
    const NSNumber = objc.getClass("NSNumber").?;
    const NSArray = objc.getClass("NSArray").?;
    const NSSortDescriptor = objc.getClass("NSSortDescriptor").?;

    // Conversion helpers for null / Object / Context
    const CheckRef = BlockRef(.{ ?objc.Object, i32, bool }, ?objc.Object);
    try std.testing.expect(CheckRef.fromPtr(null) == null);
    try std.testing.expect(CheckRef.fromId(null) == null);

    // 1. Zig Block with Object, ?Object, bool, and numeric args/returns invoked via BlockRef
    const FilterBlock = Block(struct {
        prefix: objc.Object,
    }, .{ ?objc.Object, i32, bool }, ?objc.Object);

    const prefix_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"ok:"});
    var filter_ctx = FilterBlock.init(.{ .prefix = prefix_str }, (struct {
        fn run(ctx: *const FilterBlock.Context, candidate: c.id, min_len: i32, allow: bool) callconv(.c) c.id {
            if (!allow or candidate == null) return null;
            const s = objc.Object.fromId(candidate);
            const len = s.msgSend(usize, "length", .{});
            if (len < @as(usize, @intCast(min_len))) return null;
            const caps = FilterBlock.getCaptures(ctx);
            return caps.prefix.msgSend(objc.Object, "stringByAppendingString:", .{s}).value;
        }
    }).run);

    const filter_ref = FilterBlock.asBlockRef(&filter_ctx);
    const roundtrip_ref = CheckRef.fromObject(filter_ref.asObject());
    const heap_ref = roundtrip_ref.copy();
    defer heap_ref.release();

    const hi = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"hello"});
    const short = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"a"});

    try std.testing.expect(heap_ref.invoke(.{ null, 1, true }) == null);
    try std.testing.expect(heap_ref.invoke(.{ hi, 3, false }) == null);
    try std.testing.expect(heap_ref.invoke(.{ short, 3, true }) == null);

    const matched = heap_ref.invoke(.{ hi, 3, true }) orelse return error.ExpectedObject;
    const expected = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"ok:hello"});
    try std.testing.expect(matched.msgSend(bool, "isEqualToString:", .{expected}));

    // 2. Foundation block round-trip (-[NSSortDescriptor comparator]) + genuine Apple C/Clang block
    const self_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"self"});
    const ComparatorRef = BlockRef(.{ objc.Object, objc.Object }, objc.NSInteger);

    // Selector-based NSSortDescriptor has nil comparator -> verify nullable conversion helpers
    const sel_sort_desc = NSSortDescriptor.msgSend(
        objc.Object,
        "sortDescriptorWithKey:ascending:",
        .{ self_key, true },
    );
    try std.testing.expect(ComparatorRef.fromPtr(sel_sort_desc.msgSend(?*anyopaque, "comparator", .{})) == null);
    try std.testing.expect(ComparatorRef.fromId(sel_sort_desc.msgSend(c.id, "comparator", .{})) == null);

    // Block-based NSSortDescriptor copies the block into Foundation and returns it via msgSend(ComparatorRef, ...)
    const CmpBlock = Block(struct {}, .{ objc.Object, objc.Object }, objc.NSInteger);
    const global_cmp = CmpBlock.initGlobal((struct {
        fn cmp(_: *const CmpBlock.Context, a: c.id, b: c.id) callconv(.c) objc.NSInteger {
            const oa = objc.Object.fromId(a);
            const ob = objc.Object.fromId(b);
            return oa.msgSend(objc.NSInteger, "compare:", .{ob});
        }
    }).cmp);
    const sort_desc = NSSortDescriptor.msgSend(
        objc.Object,
        "sortDescriptorWithKey:ascending:comparator:",
        .{ self_key, true, global_cmp },
    );
    const comparator = sort_desc.msgSend(ComparatorRef, "comparator", .{});
    const comparator_copy = comparator.copy();
    defer comparator_copy.release();

    const n10 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 10)});
    const n20 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 20)});

    try std.testing.expectEqual(@as(objc.NSInteger, -1), comparator_copy.invoke(.{ n10, n20 }));
    try std.testing.expectEqual(@as(objc.NSInteger, 1), comparator_copy.invoke(.{ n20, n10 }));
    try std.testing.expectEqual(@as(objc.NSInteger, 0), comparator_copy.invoke(.{ n10, n10 }));

    // Pass BlockRef as a msgSend argument to -[NSArray sortedArrayUsingComparator:]
    var nums = [_]c.id{ n20.value, n10.value };
    const unsorted = NSArray.msgSend(
        objc.Object,
        "arrayWithObjects:count:",
        .{ @as([*]const c.id, &nums), @as(usize, nums.len) },
    );
    const sorted = unsorted.msgSend(objc.Object, "sortedArrayUsingComparator:", .{comparator_copy});
    const first_sorted = sorted.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)});
    try std.testing.expectEqual(@as(c_int, 10), first_sorted.msgSend(c_int, "intValue", .{}));

    // Genuine Apple Clang-compiled block allocated by libdispatch (dispatch_block_create)
    const dispatch = struct {
        extern "c" fn dispatch_block_create(flags: c_ulong, block: *anyopaque) *anyopaque;
    };
    var ran_apple_block: bool = false;
    const InnerVoidBlock = Block(struct { flag: *bool }, .{}, void);
    var inner_void_ctx = InnerVoidBlock.init(.{ .flag = &ran_apple_block }, (struct {
        fn run(ctx: *const InnerVoidBlock.Context) callconv(.c) void {
            ctx.flag.* = true;
        }
    }).run);
    const apple_block_ptr = dispatch.dispatch_block_create(0, @ptrCast(&inner_void_ctx));
    const VoidRef = BlockRef(.{}, void);
    const apple_block = VoidRef.fromPtr(apple_block_ptr).?;
    defer apple_block.release();
    // Verify its invoke pointer is distinct from our Zig callback (it's Apple's Clang block!)
    const apple_layout: *const BlockLayout = @ptrCast(@alignCast(apple_block.value));
    try std.testing.expect(@intFromPtr(apple_layout.invoke) != @intFromPtr(inner_void_ctx.invoke));
    apple_block.invoke(.{});
    try std.testing.expect(ran_apple_block);

    // 3. BlockRef as a direct parameter in an Objective-C method IMP callback
    const NSObject = objc.getClass("NSObject").?;
    const RunnerCls = objc.allocateClassPair(NSObject, "ZigObjcBlockRefRunner").?;
    defer objc.disposeClassPair(RunnerCls);

    const CalcRef = BlockRef(.{ i32, bool }, i32);
    const runner_impl = struct {
        fn callBlock(_: c.id, _: c.SEL, cb: CalcRef, x: i32) callconv(.c) i32 {
            return cb.invoke(.{ x, true }) + cb.invoke(.{ x, false });
        }
    };
    try std.testing.expect(RunnerCls.addMethod("runBlock:withValue:", runner_impl.callBlock));
    objc.registerClassPair(RunnerCls);

    const runner = RunnerCls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer runner.release();

    const CalcBlock = Block(struct { bonus: i32 }, .{ i32, bool }, i32);
    var calc_ctx = CalcBlock.init(.{ .bonus = 5 }, (struct {
        fn calc(ctx: *const CalcBlock.Context, v: i32, negate: bool) callconv(.c) i32 {
            const base = v + ctx.bonus;
            return if (negate) -base else base * 2;
        }
    }).calc);

    const calc_res = runner.msgSend(
        i32,
        "runBlock:withValue:",
        .{ CalcBlock.asBlockRef(&calc_ctx), @as(i32, 10) },
    );
    // negate=true => -(15) = -15; negate=false => 30; total = 15
    try std.testing.expectEqual(@as(i32, 15), calc_res);
}

test "Block captures objc.Object and nested blocks with retain and dispose lifecycle" {
    const NSObject = objc.getClass("NSObject").?;

    const TrackerState = struct {
        var dealloc_count: usize = 0;
    };
    TrackerState.dealloc_count = 0;

    const TrackerCls = objc.allocateClassPair(NSObject, "ZigObjcBlockCaptureTracker").?;
    defer objc.disposeClassPair(TrackerCls);

    const tracker_impl = struct {
        fn dealloc(self_id: c.id, _: c.SEL) callconv(.c) void {
            TrackerState.dealloc_count += 1;
            const self_obj = objc.Object.fromId(self_id);
            self_obj.msgSendSuper(objc.getClass("NSObject").?, void, "dealloc", .{});
        }
        fn magic(_: c.id, _: c.SEL) callconv(.c) i32 {
            return 77;
        }
    };
    _ = TrackerCls.replaceMethod("dealloc", tracker_impl.dealloc);
    try std.testing.expect(TrackerCls.addMethod("magic", tracker_impl.magic));
    objc.registerClassPair(TrackerCls);

    // 1. Direct objc.Object and ?objc.Object capture lifecycle
    {
        const tracked = TrackerCls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        try std.testing.expectEqual(@as(c_ulong, 1), tracked.msgSend(c_ulong, "retainCount", .{}));

        const ObjBlock = Block(struct {
            obj: objc.Object,
            opt_present: ?objc.Object,
            opt_nil: ?objc.Object,
        }, .{i32}, i32);

        const heap_blk = blk: {
            var stack_blk = ObjBlock.init(.{
                .obj = tracked,
                .opt_present = tracked,
                .opt_nil = null,
            }, (struct {
                fn run(ctx: *const ObjBlock.Context, addend: i32) callconv(.c) i32 {
                    const caps = ObjBlock.getCaptures(ctx);
                    if (caps.opt_nil != null) return -1;
                    const a = caps.obj.msgSend(i32, "magic", .{});
                    const b = caps.opt_present.?.msgSend(i32, "magic", .{});
                    return a + b + addend;
                }
            }).run);

            // Stack init does not retain until copied
            try std.testing.expectEqual(@as(c_ulong, 1), tracked.msgSend(c_ulong, "retainCount", .{}));

            const copied = try ObjBlock.copy(&stack_blk);
            // Both `obj` and `opt_present` retained `tracked` (+2 => retainCount 3)
            try std.testing.expectEqual(@as(c_ulong, 3), tracked.msgSend(c_ulong, "retainCount", .{}));
            break :blk copied;
        };

        // Release original reference — heap block must keep `tracked` alive!
        tracked.release();
        try std.testing.expectEqual(@as(usize, 0), TrackerState.dealloc_count);
        try std.testing.expectEqual(@as(c_ulong, 2), tracked.msgSend(c_ulong, "retainCount", .{}));

        try std.testing.expectEqual(@as(i32, 77 + 77 + 6), ObjBlock.invoke(heap_blk, .{6}));

        // Releasing the heap block disposes both object captures and deallocates `tracked`!
        ObjBlock.release(heap_blk);
        try std.testing.expectEqual(@as(usize, 1), TrackerState.dealloc_count);
    }

    // 2. Nested block capture (BlockRef and *InnerBlock.Context) keeps inner block's object alive
    {
        TrackerState.dealloc_count = 0;
        const inner_tracked = TrackerCls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

        const InnerBlock = Block(struct { obj: objc.Object }, .{i32}, i32);
        const OuterBlock = Block(struct {
            inner_ref: InnerBlock.Ref,
            inner_ctx: *const InnerBlock.Context,
            nil_ref: ?InnerBlock.Ref,
        }, .{i32}, i32);

        const heap_outer = blk: {
            var stack_inner = InnerBlock.init(.{ .obj = inner_tracked }, (struct {
                fn runInner(ctx: *const InnerBlock.Context, x: i32) callconv(.c) i32 {
                    return InnerBlock.getCaptures(ctx).obj.msgSend(i32, "magic", .{}) + x;
                }
            }).runInner);

            var stack_outer = OuterBlock.init(.{
                .inner_ref = InnerBlock.asBlockRef(&stack_inner),
                .inner_ctx = &stack_inner,
                .nil_ref = null,
            }, (struct {
                fn runOuter(ctx: *const OuterBlock.Context, x: i32) callconv(.c) i32 {
                    if (OuterBlock.getCaptures(ctx).nil_ref != null) return -1;
                    return ctx.inner_ref.invoke(.{x}) + InnerBlock.invoke(ctx.inner_ctx, .{x});
                }
            }).runOuter);

            break :blk try OuterBlock.copy(&stack_outer);
        };

        // Release original inner_tracked; nested heap block copies keep it alive!
        inner_tracked.release();
        try std.testing.expectEqual(@as(usize, 0), TrackerState.dealloc_count);

        try std.testing.expectEqual(@as(i32, (77 + 3) * 2), OuterBlock.invoke(heap_outer, .{3}));

        OuterBlock.release(heap_outer);
        try std.testing.expectEqual(@as(usize, 1), TrackerState.dealloc_count);
    }
}

test "Block.initGlobal stateless global block" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const GlobalComparator = Block(struct {}, .{ c.id, c.id }, objc.NSInteger);

    const helper = struct {
        // Returns a BlockRef after its stack frame exits — safe because initGlobal is static.
        fn makeGlobalComparator() GlobalComparator.Ref {
            const global_ctx = GlobalComparator.initGlobal((struct {
                fn cmp(_: *const GlobalComparator.Context, a: c.id, b: c.id) callconv(.c) objc.NSInteger {
                    const va = objc.Object.fromId(a).msgSend(c_int, "intValue", .{});
                    const vb = objc.Object.fromId(b).msgSend(c_int, "intValue", .{});
                    return if (va < vb) -1 else if (va > vb) 1 else 0;
                }
            }).cmp);
            return GlobalComparator.asBlockRef(global_ctx);
        }
    };

    const global_ctx = GlobalComparator.initGlobal((struct {
        fn cmp(_: *const GlobalComparator.Context, a: c.id, b: c.id) callconv(.c) objc.NSInteger {
            const va = objc.Object.fromId(a).msgSend(c_int, "intValue", .{});
            const vb = objc.Object.fromId(b).msgSend(c_int, "intValue", .{});
            return if (va < vb) -1 else if (va > vb) 1 else 0;
        }
    }).cmp);
    try std.testing.expect(global_ctx.flags.global);
    try std.testing.expect(!global_ctx.flags.copy_dispose);

    // Zero-capture stack block (`init(.{}, ...)`) also works cleanly with copy/invoke/release
    var stack_zero = GlobalComparator.init(.{}, (struct {
        fn cmp(_: *const GlobalComparator.Context, a: c.id, b: c.id) callconv(.c) objc.NSInteger {
            const va = objc.Object.fromId(a).msgSend(c_int, "intValue", .{});
            const vb = objc.Object.fromId(b).msgSend(c_int, "intValue", .{});
            return if (va < vb) -1 else if (va > vb) 1 else 0;
        }
    }).cmp);
    const copied_stack_zero = try GlobalComparator.copy(&stack_zero);
    defer GlobalComparator.release(copied_stack_zero);

    // _Block_copy on a global block returns the identical address and release is a no-op
    const copied_global = try GlobalComparator.copy(global_ctx);
    try std.testing.expectEqual(@intFromPtr(global_ctx), @intFromPtr(copied_global));
    GlobalComparator.release(copied_global);

    const cmp_ref = helper.makeGlobalComparator();
    const NSNumber = objc.getClass("NSNumber").?;
    const NSArray = objc.getClass("NSArray").?;
    const n3 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 3)});
    const n1 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 1)});
    const n2 = NSNumber.msgSend(objc.Object, "numberWithInt:", .{@as(c_int, 2)});

    var items = [_]c.id{ n3.value, n1.value, n2.value };
    const arr = NSArray.msgSend(
        objc.Object,
        "arrayWithObjects:count:",
        .{ @as([*]const c.id, &items), @as(usize, items.len) },
    );
    const sorted = arr.msgSend(objc.Object, "sortedArrayUsingComparator:", .{cmp_ref});
    try std.testing.expectEqual(@as(c_int, 1), sorted.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 0)}).msgSend(c_int, "intValue", .{}));
    try std.testing.expectEqual(@as(c_int, 2), sorted.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 1)}).msgSend(c_int, "intValue", .{}));
    try std.testing.expectEqual(@as(c_int, 3), sorted.msgSend(objc.Object, "objectAtIndex:", .{@as(usize, 2)}).msgSend(c_int, "intValue", .{}));
}

test "impImplementationWithBlock, impGetBlock, and impRemoveBlock" {
    const NSObject = objc.getClass("NSObject").?;

    // Plain C function IMP is not backed by a block
    const plain_fn = struct {
        fn f(_: c.id, _: c.SEL) callconv(.c) i32 {
            return 1;
        }
    };
    try std.testing.expect(impGetBlock(@ptrCast(&plain_fn.f)) == null);

    // Block-backed IMP: first arg after Context is receiver `id` (NO `_cmd: SEL`)
    const MethodBlock = Block(struct {
        factor: i32,
        bias_obj: objc.Object,
    }, .{ c.id, i32 }, i32);

    const NSNumber = objc.getClass("NSNumber").?;
    const bias = NSNumber.msgSend(objc.Object, "alloc", .{}).msgSend(
        objc.Object,
        "initWithInt:",
        .{@as(c_int, 100)},
    );

    var method_blk = MethodBlock.init(.{
        .factor = 4,
        .bias_obj = bias,
    }, (struct {
        fn invokeMethod(ctx: *const MethodBlock.Context, receiver: c.id, x: i32) callconv(.c) i32 {
            const self_obj = objc.Object.fromId(receiver);
            if (self_obj.getClass() == null) return -1;
            const caps = MethodBlock.getCaptures(ctx);
            return caps.bias_obj.msgSend(c_int, "intValue", .{}) + (x * ctx.factor);
        }
    }).invokeMethod);

    const imp = impImplementationWithBlock(&method_blk);
    try std.testing.expect(imp != null);

    // imp_implementationWithBlock copied the block and retained `bias`
    bias.release();
    try std.testing.expect(impGetBlock(imp) != null);

    const DynCls = objc.allocateClassPair(NSObject, "ZigObjcImpBlockClass").?;
    try std.testing.expect(cpkg.boolResult(c.class_addMethod(
        DynCls.value,
        objc.sel("computeWithValue:").value,
        imp,
        "i@:i",
    )));
    objc.registerClassPair(DynCls);

    {
        const inst = DynCls.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer inst.release();

        const computed = inst.msgSend(i32, "computeWithValue:", .{@as(i32, 7)});
        try std.testing.expectEqual(@as(i32, 128), computed);
    }

    objc.disposeClassPair(DynCls);
    try std.testing.expect(impRemoveBlock(imp));

    // Verify impImplementationWithBlock also accepts BlockRef, Object, and >16-byte struct returns
    const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const RectBlock = Block(struct {}, .{ c.id, f64 }, Rect);
    const rect_global = RectBlock.initGlobal((struct {
        fn makeRect(_: *const RectBlock.Context, _: c.id, scale: f64) callconv(.c) Rect {
            return .{ .x = 1.0 * scale, .y = 2.0 * scale, .w = 3.0 * scale, .h = 4.0 * scale };
        }
    }).makeRect);
    const rect_ref = RectBlock.asBlockRef(rect_global);
    const r_direct = rect_ref.invoke(.{ NSObject.msgSend(objc.Object, "self", .{}).value, 2.0 });
    try std.testing.expectEqual(@as(f64, 8.0), r_direct.h);

    const rect_imp = impImplementationWithBlock(rect_ref);
    try std.testing.expect(impGetBlock(rect_imp) != null);
    try std.testing.expect(impRemoveBlock(rect_imp));

    const obj_imp = impImplementationWithBlock(RectBlock.asObject(rect_global));
    try std.testing.expect(impGetBlock(obj_imp) != null);
    try std.testing.expect(impRemoveBlock(obj_imp));
}

test "low-level Block.h helpers and BlockFieldFlags" {
    try std.testing.expectEqual(@as(c_int, 3), @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_OBJECT));
    try std.testing.expectEqual(@as(c_int, 7), @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_BLOCK));
    try std.testing.expectEqual(@as(c_int, 8), @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_BYREF));
    try std.testing.expectEqual(@as(c_int, 16), @backingInt(BlockFieldFlags.BLOCK_FIELD_IS_WEAK));
    try std.testing.expectEqual(@as(c_int, 128), @backingInt(BlockFieldFlags.BLOCK_BYREF_CALLER));
    try std.testing.expectEqual(@as(c_int, 24), @backingInt(BlockFieldFlags.combine(.BLOCK_FIELD_IS_BYREF, .BLOCK_FIELD_IS_WEAK)));

    try std.testing.expect(blockCopy(null) == null);
    blockRelease(null);

    const NSObject = objc.getClass("NSObject").?;
    const obj = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    defer obj.release();

    try std.testing.expectEqual(@as(c_ulong, 1), obj.msgSend(c_ulong, "retainCount", .{}));

    var slot: ?*anyopaque = null;
    objectAssign(@ptrCast(&slot), @ptrCast(obj.value), .BLOCK_FIELD_IS_OBJECT);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(c_ulong, 2), obj.msgSend(c_ulong, "retainCount", .{}));

    objectDispose(slot, .BLOCK_FIELD_IS_OBJECT);
    try std.testing.expectEqual(@as(c_ulong, 1), obj.msgSend(c_ulong, "retainCount", .{}));
}

test "Block, BlockRef, and impImplementationWithBlock returning unaligned struct" {
    const testing = std.testing;
    const Unaligned9 = extern struct { a: u8, b: i64 align(1) };

    const StackBlk = Block(struct { offset: i64 }, .{u8}, Unaligned9);
    var stack_ctx = StackBlk.init(.{ .offset = 1000 }, &(struct {
        fn run(ctx: *const StackBlk.Context, tag: u8) callconv(.c) Unaligned9 {
            return .{ .a = tag + 1, .b = ctx.offset - @as(i64, tag) };
        }
    }).run);
    try testing.expectEqual(cpkg.usesStret(Unaligned9), stack_ctx.flags.stret);

    const direct_res = StackBlk.invoke(&stack_ctx, .{@as(u8, 7)});
    try testing.expectEqual(@as(u8, 8), direct_res.a);
    try testing.expectEqual(@as(i64, 993), direct_res.b);

    const ref = StackBlk.asBlockRef(&stack_ctx);
    const ref_res = ref.invoke(.{@as(u8, 9)});
    try testing.expectEqual(@as(u8, 10), ref_res.a);
    try testing.expectEqual(@as(i64, 991), ref_res.b);

    // Also test global block + impImplementationWithBlock roundtrip via msgSend
    const ImpBlk = Block(struct {}, .{ c.id, u8 }, Unaligned9);
    const global_ctx = ImpBlk.initGlobal(&(struct {
        fn run(_: *const ImpBlk.Context, _: c.id, tag: u8) callconv(.c) Unaligned9 {
            return .{ .a = tag ^ 0xFF, .b = -@as(i64, tag) * 1_000_000_000 };
        }
    }).run);
    try testing.expectEqual(cpkg.usesStret(Unaligned9), global_ctx.flags.stret);

    const imp = impImplementationWithBlock(global_ctx);
    defer _ = impRemoveBlock(imp);

    const NSObject = objc.getClass("NSObject").?;
    const Cls = objc.allocateClassPair(NSObject, "ZigObjcImpBlockUnaligned9").?;
    defer objc.disposeClassPair(Cls);

    const enc = comptime objc.comptimeEncode(fn (c.id, c.SEL, u8) callconv(.c) Unaligned9);
    try testing.expect(Cls.addMethodRaw(objc.sel("buildUnaligned:"), imp, &enc));
    objc.registerClassPair(Cls);

    const inst = objc.allocInit(Cls).?;
    defer inst.release();

    const msg_res = inst.msgSend(Unaligned9, "buildUnaligned:", .{@as(u8, 0x0F)});
    try testing.expectEqual(@as(u8, 0xF0), msg_res.a);
    try testing.expectEqual(@as(i64, -15_000_000_000), msg_res.b);
}

test "BlockRef.tryCopy, bool descriptor encoding, and extern Object/Sel signatures" {
    const testing = std.testing;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // 1. Verify Block descriptor signature encodes `bool` as `@encode(BOOL)` (`c.BOOL`)
    //    and nested BlockRef / ?BlockRef as `@?`.
    const InnerBoolBlock = Block(struct {}, .{ i32, bool }, bool);
    const expected_bool_enc = comptime objc.comptimeEncode(c.BOOL) ++ "@?i" ++ objc.comptimeEncode(c.BOOL);
    try testing.expectEqualStrings(expected_bool_enc, &InnerBoolBlock.signature_encoding);

    const global_bool = InnerBoolBlock.initGlobal(&(struct {
        fn check(_: *const InnerBoolBlock.Context, x: i32, invert: bool) callconv(.c) bool {
            const pos = x > 0;
            return if (invert) !pos else pos;
        }
    }).check);
    try testing.expectEqualStrings(expected_bool_enc, std.mem.span(global_bool.descriptor.signature.?));
    try testing.expect(InnerBoolBlock.invoke(global_bool, .{ 5, false }));
    try testing.expect(!InnerBoolBlock.invoke(global_bool, .{ 5, true }));
    if (comptime c.BOOL != bool) {
        // Simulate an Objective-C caller passing a non-0/1 signed char BOOL (e.g. 2 or -1).
        try testing.expectEqual(@as(c.BOOL, 0), global_bool.invoke(global_bool, 5, @as(c.BOOL, 2)));
        try testing.expectEqual(@as(c.BOOL, 1), global_bool.invoke(global_bool, -5, @as(c.BOOL, -1)));
    }

    const bool_ref = InnerBoolBlock.asBlockRef(global_bool);
    const copied_bool_ref = try bool_ref.tryCopy();
    defer copied_bool_ref.release();
    try testing.expect(copied_bool_ref.invoke(.{ -3, true }));
    try testing.expect(!copied_bool_ref.invoke(.{ -3, false }));

    const HigherBlock = Block(struct {}, .{ InnerBoolBlock.Ref, ?InnerBoolBlock.Ref }, bool);
    const expected_higher_enc = comptime objc.comptimeEncode(c.BOOL) ++ "@?@?@?";
    try testing.expectEqualStrings(expected_higher_enc, &HigherBlock.signature_encoding);

    // 2. Stack block copied via BlockRef.tryCopy() keeps captured object alive until release()
    const NSString = objc.getClass("NSString").?;
    const TargetAction = extern struct {
        target: objc.Object,
        action: objc.Sel,
    };

    const ActionBlock = Block(struct {
        prefix: objc.Object,
        fallback_sel: objc.Sel,
        weak_ptr: *objc.Weak,
    }, .{ objc.Object, objc.Sel, TargetAction }, TargetAction);

    var weak_slot: objc.Weak = .{};
    defer weak_slot.deinit();
    const prefix = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"sel:"});
    weak_slot.init(prefix);

    const length_sel = objc.Sel.cached("length");
    const desc_sel = objc.Sel.cached("description");

    const heap_action_ref = blk: {
        var stack_action = ActionBlock.init(.{
            .prefix = prefix,
            .fallback_sel = desc_sel,
            .weak_ptr = &weak_slot,
        }, &(struct {
            fn run(
                ctx: *const ActionBlock.Context,
                raw_obj: c.id,
                raw_sel: c.SEL,
                pair: TargetAction,
            ) callconv(.c) TargetAction {
                const caps = ActionBlock.getCaptures(ctx);
                const obj = objc.Object.fromId(raw_obj);
                const incoming_sel = objc.Sel{ .value = raw_sel };
                const loaded = caps.weak_ptr.loadRetained() orelse caps.prefix;
                defer if (loaded.value == caps.prefix.value) loaded.release();
                const chosen_sel = if (incoming_sel.isEqual(pair.action)) incoming_sel else caps.fallback_sel;
                const combined = loaded.msgSend(objc.Object, "stringByAppendingString:", .{obj});
                return .{ .target = combined, .action = chosen_sel };
            }
        }).run);

        break :blk try ActionBlock.asBlockRef(&stack_action).tryCopy();
    };
    defer heap_action_ref.release();

    const suffix = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"ok"});
    const out_same = heap_action_ref.invoke(.{
        suffix,
        length_sel,
        TargetAction{ .target = suffix, .action = length_sel },
    });
    try testing.expect(out_same.action.isEqual(length_sel));
    try testing.expectEqualStrings(
        "sel:ok",
        std.mem.span(out_same.target.msgSend([*:0]const u8, "UTF8String", .{})),
    );

    const out_diff = heap_action_ref.invoke(.{
        suffix,
        length_sel,
        TargetAction{ .target = suffix, .action = desc_sel },
    });
    try testing.expect(out_diff.action.isEqual(desc_sel));

    // Also test direct Sel/Object return types on Block & BlockRef
    const SelEchoBlock = Block(struct {}, .{ objc.Object, objc.Sel }, objc.Sel);
    const sel_echo = SelEchoBlock.initGlobal(&(struct {
        fn echo(_: *const SelEchoBlock.Context, raw_obj: c.id, raw_sel: c.SEL) callconv(.c) c.SEL {
            _ = objc.Object.fromId(raw_obj);
            return raw_sel;
        }
    }).echo);
    try testing.expect(SelEchoBlock.invoke(sel_echo, .{ suffix, length_sel }).isEqual(length_sel));
    try testing.expect(SelEchoBlock.asBlockRef(sel_echo).invoke(.{ suffix, desc_sel }).isEqual(desc_sel));

    // Verify 16-byte aligned field and nested POD extern struct captures work cleanly
    const NestedPod = extern struct {
        scale: f32,
        bias: f32,
        sel_handle: objc.Sel,
    };
    const SimdPodBlock = Block(struct {
        lanes: [4]f32 align(16),
        pod: NestedPod,
    }, .{f32}, f32);
    var simd_stack = SimdPodBlock.init(.{
        .lanes = .{ 1.0, 2.0, 3.0, 4.0 },
        .pod = .{ .scale = 2.0, .bias = 0.5, .sel_handle = length_sel },
    }, &(struct {
        fn run(ctx: *const SimdPodBlock.Context, x: f32) callconv(.c) f32 {
            const caps = SimdPodBlock.getCaptures(ctx);
            const sum = caps.lanes[0] + caps.lanes[1] + caps.lanes[2] + caps.lanes[3];
            return sum * caps.pod.scale + caps.pod.bias + x;
        }
    }).run);
    const simd_heap = try SimdPodBlock.copy(&simd_stack);
    defer SimdPodBlock.release(simd_heap);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(&simd_heap.lanes) % 16);
    try testing.expectEqual(@as(f32, 22.0), SimdPodBlock.invoke(simd_heap, .{@as(f32, 1.5)}));
}

test {
    std.testing.refAllDecls(@This());
}
