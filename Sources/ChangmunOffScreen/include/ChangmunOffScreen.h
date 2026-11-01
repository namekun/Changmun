#pragma once
#include <stdbool.h>

/// Keeps every window of this process off every screen, from here on. For the test copy, which calls it first thing. The test runner gets it by
/// itself when the code is loaded, before any test can make a window. It is never called in the app.
void changmun_off_screen_install(void);

/// Whether the windows of this process are being kept off the screens.
bool changmun_off_screen_active(void);
