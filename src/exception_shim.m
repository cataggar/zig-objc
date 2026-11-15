#include <objc/objc.h>
#include <objc/objc-exception.h>

extern id objc_retain(id obj);

void *zig_objc_try_catch(void (*try_fn)(void *ctx), void *ctx, unsigned char *caught_out) {
    @try {
        *caught_out = 0;
        try_fn(ctx);
        return (void *)0;
    } @catch (id exception) {
        *caught_out = 1;
        return (void *)(exception ? objc_retain(exception) : nil);
    } @catch (...) {
        *caught_out = 2;
        return (void *)0;
    }
}
