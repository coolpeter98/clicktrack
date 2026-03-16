#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

extern void on_mouse_event(uint8_t button, int is_down, void *userdata);

static void *g_userdata = NULL;

#define RI_MOUSE_LEFT_BUTTON_DOWN   0x0001
#define RI_MOUSE_LEFT_BUTTON_UP     0x0002

static void process_raw_mouse(RAWMOUSE *mouse) {
    USHORT flags = mouse->usButtonFlags;
    if (flags & RI_MOUSE_LEFT_BUTTON_DOWN) on_mouse_event(0, 1, g_userdata);
    if (flags & RI_MOUSE_LEFT_BUTTON_UP)   on_mouse_event(0, 0, g_userdata);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_INPUT) {
        UINT size = 0;
        GetRawInputData((HRAWINPUT)lParam, RID_INPUT, NULL, &size, sizeof(RAWINPUTHEADER));
        if (size == 0) return 0;

        BYTE buf[256];
        if (size > sizeof(buf)) return 0;
        if (GetRawInputData((HRAWINPUT)lParam, RID_INPUT, buf, &size, sizeof(RAWINPUTHEADER)) == (UINT)-1)
            return 0;

        RAWINPUT *raw = (RAWINPUT *)buf;
        if (raw->header.dwType == RIM_TYPEMOUSE) {
            process_raw_mouse(&raw->data.mouse);
        }
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wParam, lParam);
}

int platform_run_windows(void *userdata) {
    g_userdata = userdata;

    HINSTANCE hinst = GetModuleHandleA(NULL);

    WNDCLASSEXA wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = hinst;
    wc.lpszClassName = "ClickTrackRawInput";

    if (!RegisterClassExA(&wc)) {
        fprintf(stderr, "RegisterClassExA failed: %lu\n", GetLastError());
        return 1;
    }

    HWND hwnd = CreateWindowExA(
        0, "ClickTrackRawInput", NULL, 0,
        0, 0, 0, 0,
        HWND_MESSAGE, NULL, hinst, NULL
    );
    if (!hwnd) {
        fprintf(stderr, "CreateWindowExA failed: %lu\n", GetLastError());
        return 1;
    }

    RAWINPUTDEVICE rid;
    rid.usUsagePage = 0x01;  /* HID_USAGE_PAGE_GENERIC */
    rid.usUsage     = 0x02;  /* HID_USAGE_GENERIC_MOUSE */
    rid.dwFlags     = RIDEV_INPUTSINK;
    rid.hwndTarget  = hwnd;

    if (!RegisterRawInputDevices(&rid, 1, sizeof(rid))) {
        fprintf(stderr, "RegisterRawInputDevices failed: %lu\n", GetLastError());
        return 1;
    }

    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        DispatchMessageA(&msg);
    }

    return 0;
}
