#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

extern void on_mouse_event(uint8_t button, int is_down, const char* device, void *userdata);

static CFMachPortRef g_tap = NULL;

static CGEventRef tap_callback(
    CGEventTapProxy proxy,
    CGEventType     type,
    CGEventRef      event,
    void           *userInfo
) {
    (void)proxy;

    switch (type) {
        case kCGEventLeftMouseDown:
        case kCGEventLeftMouseUp: {
            // Events from physical devices have source PID 0.
            // Events injected via CGEventPost etc. have nonzero source PID.
            int64_t srcPid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
            int is_down = (type == kCGEventLeftMouseDown) ? 1 : 0;
            char device[32];
            if (srcPid != 0) {
                snprintf(device, sizeof(device), "injected");
            } else {
                snprintf(device, sizeof(device), "hardware");
            }
            on_mouse_event(0, is_down, device, userInfo);
            break;
        }

        case kCGEventTapDisabledByTimeout:
        case kCGEventTapDisabledByUserInput:
            if (g_tap) CGEventTapEnable(g_tap, true);
            break;

        default: break;
    }

    return event;
}

int platform_run_macos(void *userdata) {
    CGEventMask mask =
        (1ULL << kCGEventLeftMouseDown) | (1ULL << kCGEventLeftMouseUp);

    CFMachPortRef tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        mask,
        tap_callback,
        userdata
    );

    if (!tap) {
        fprintf(stderr,
            "Failed to create event tap.\n"
            "Grant Accessibility permissions:\n"
            "  System Settings → Privacy & Security → Accessibility\n"
        );
        return 1;
    }

    g_tap = tap;

    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (!src) {
        fprintf(stderr, "CFMachPortCreateRunLoopSource failed\n");
        CFRelease(tap);
        return 1;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    CFRunLoopRun();

    CFRelease(src);
    CFRelease(tap);
    return 0;
}
