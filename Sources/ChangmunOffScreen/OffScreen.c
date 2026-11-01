#include "ChangmunOffScreen.h"
#include <CoreFoundation/CoreFoundation.h>
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

// Only a sheet goes with the window it hangs from, which is off the screens already. A pop-up is a child window of the one that opened it, and is
// parked like any other: a child isn't carried along when the frame it was given is on a screen.
static bool follows_another(id window) {
    BOOL (*yes)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    id (*other)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return yes(window, sel_registerName("isSheet")) || other(window, sel_registerName("sheetParent")) != nil;
}

static void park(id window) {
    if (follows_another(window)) return;
    setFrameOrigin(window, sel_registerName("setFrameOrigin:"), parked);
    // Not in Mission Control, the app switcher or the Windows menu either.
    unsigned long (*current)(id, SEL) = (unsigned long (*)(id, SEL))objc_msgSend;
    void (*behavior)(id, SEL, unsigned long) = (void (*)(id, SEL, unsigned long))objc_msgSend;
    unsigned long wanted = current(window, sel_registerName("collectionBehavior")) | (1UL << 3) | (1UL << 6);
    if (wanted != current(window, sel_registerName("collectionBehavior"))) behavior(window, sel_registerName("setCollectionBehavior:"), wanted);
    void (*excluded)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    excluded(window, sel_registerName("setExcludedFromWindowsMenu:"), YES);
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

// Whatever path a window took to get on a screen (a setter that isn't hooked, a frame restored by the system), this puts it back within 20 ms.
static bool meets_a_screen(CGRect frame) {
    id (*get)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id screens = get((id)objc_getClass("NSScreen"), sel_registerName("screens"));
    unsigned long (*count)(id, SEL) = (unsigned long (*)(id, SEL))objc_msgSend;
    id (*at)(id, SEL, unsigned long) = (id (*)(id, SEL, unsigned long))objc_msgSend;
    CGRect (*rect)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    for (unsigned long i = 0; i < count(screens, sel_registerName("count")); i++) {
        if (CGRectIntersectsRect(rect(at(screens, sel_registerName("objectAtIndex:"), i), sel_registerName("frame")), frame)) return true;
    }
    return false;
}

static void keep_watch(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    id (*get)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id app = get((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    if (!app) return;
    id windows = get(app, sel_registerName("windows"));
    unsigned long (*count)(id, SEL) = (unsigned long (*)(id, SEL))objc_msgSend;
    id (*at)(id, SEL, unsigned long) = (id (*)(id, SEL, unsigned long))objc_msgSend;
    CGRect (*rect)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    BOOL (*yes)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    for (unsigned long i = 0; i < count(windows, sel_registerName("count")); i++) {
        id window = at(windows, sel_registerName("objectAtIndex:"), i);
        if (follows_another(window) || !yes(window, sel_registerName("isVisible"))) continue;
        if (meets_a_screen(rect(window, sel_registerName("frame")))) park(window);
    }
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
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.02, 0, 0, keep_watch, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
}

bool changmun_off_screen_active(void) { return active; }

__attribute__((constructor)) static void changmun_off_screen_on_load(void) {
    const char *name = getprogname();
    if (name && (strstr(name, "swiftpm-testing-helper") || strstr(name, "xctest") || strstr(name, "PackageTests"))) {
        changmun_off_screen_install();
    }
}
