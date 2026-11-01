#include "ChangmunOffScreen.h"
#include <CoreGraphics/CoreGraphics.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// In C so that it runs when the code is loaded: Swift has no way to run something before the first test, and a test that makes a window first would
// show it on the user's screen.

static const CGPoint parked = {-32000, -32000};
static bool active = false;

typedef void (*ObjectFn)(id, SEL, id);
typedef void (*PlainFn)(id, SEL);
typedef void (*OrderFn)(id, SEL, long, long);
typedef void (*OriginFn)(id, SEL, CGPoint);
typedef void (*FrameFn)(id, SEL, CGRect, BOOL);
typedef void (*AnimatedFrameFn)(id, SEL, CGRect, BOOL, BOOL);

static ObjectFn orderFront, makeKeyAndOrderFront;
static PlainFn orderFrontRegardless;
static OrderFn orderWindow;
static OriginFn setFrameOrigin;
static FrameFn setFrame;
static AnimatedFrameFn setFrameAnimated;

static bool follows_another(id window) {
    BOOL (*yes)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    id (*other)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return yes(window, sel_registerName("isSheet")) || other(window, sel_registerName("sheetParent")) != nil
        || other(window, sel_registerName("parentWindow")) != nil;
}

static void park(id window) {
    if (!follows_another(window)) setFrameOrigin(window, sel_registerName("setFrameOrigin:"), parked);
}

static void hooked_orderFront(id self, SEL cmd, id sender) { park(self); orderFront(self, cmd, sender); }
static void hooked_makeKey(id self, SEL cmd, id sender) { park(self); makeKeyAndOrderFront(self, cmd, sender); }
static void hooked_regardless(id self, SEL cmd) { park(self); orderFrontRegardless(self, cmd); }
static void hooked_order(id self, SEL cmd, long place, long other) { park(self); orderWindow(self, cmd, place, other); }
static void hooked_center(id self, SEL cmd) { (void)cmd; park(self); }
static CGRect hooked_constrain(id self, SEL cmd, CGRect rect, id screen) { (void)self; (void)cmd; (void)screen; return rect; }
static void hooked_origin(id self, SEL cmd, CGPoint point) { setFrameOrigin(self, cmd, follows_another(self) ? point : parked); }
static void hooked_topLeft(id self, SEL cmd, CGPoint point) { (void)cmd; (void)point; park(self); }

static void hooked_frame(id self, SEL cmd, CGRect rect, BOOL display) {
    if (!follows_another(self)) rect.origin = parked;
    setFrame(self, cmd, rect, display);
}

static void hooked_animated(id self, SEL cmd, CGRect rect, BOOL display, BOOL animate) {
    if (!follows_another(self)) rect.origin = parked;
    setFrameAnimated(self, cmd, rect, display, NO);
    (void)animate;
}

static IMP replace(Class window, const char *selector, IMP with) {
    Method method = class_getInstanceMethod(window, sel_registerName(selector));
    return method ? method_setImplementation(method, with) : NULL;
}

void changmun_off_screen_install(void) {
    if (active) return;
    Class window = objc_getClass("NSWindow");
    if (!window) return;
    active = true;
    orderFront = (ObjectFn)replace(window, "orderFront:", (IMP)hooked_orderFront);
    makeKeyAndOrderFront = (ObjectFn)replace(window, "makeKeyAndOrderFront:", (IMP)hooked_makeKey);
    orderFrontRegardless = (PlainFn)replace(window, "orderFrontRegardless", (IMP)hooked_regardless);
    orderWindow = (OrderFn)replace(window, "orderWindow:relativeTo:", (IMP)hooked_order);
    setFrameOrigin = (OriginFn)replace(window, "setFrameOrigin:", (IMP)hooked_origin);
    setFrame = (FrameFn)replace(window, "setFrame:display:", (IMP)hooked_frame);
    setFrameAnimated = (AnimatedFrameFn)replace(window, "setFrame:display:animate:", (IMP)hooked_animated);
    replace(window, "center", (IMP)hooked_center);
    replace(window, "constrainFrameRect:toScreen:", (IMP)hooked_constrain);
    replace(window, "setFrameTopLeftPoint:", (IMP)hooked_topLeft);
}

bool changmun_off_screen_active(void) { return active; }

__attribute__((constructor)) static void changmun_off_screen_on_load(void) {
    const char *name = getprogname();
    if (name && (strstr(name, "swiftpm-testing-helper") || strstr(name, "xctest") || strstr(name, "PackageTests"))) {
        changmun_off_screen_install();
    }
}
