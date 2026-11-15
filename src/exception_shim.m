#include <objc/objc.h>
#include <objc/objc-exception.h>

extern id objc_retain(id obj);

id zig_objc_try_catch(void (*try_fn)(void *ctx), void *ctx, unsigned char *caught_out) {
    @try {
        *caught_out = 0;
        try_fn(ctx);
        return nil;
    } @catch (id exception) {
        *caught_out = 1;
        return exception ? objc_retain(exception) : nil;
    }
}
