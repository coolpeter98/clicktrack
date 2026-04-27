#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <hidsdi.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

extern void on_mouse_event(uint8_t button, int is_down, const char* device, void *userdata);

static void *g_userdata = NULL;

#define RI_MOUSE_LEFT_BUTTON_DOWN   0x0001
#define RI_MOUSE_LEFT_BUTTON_UP     0x0002

static void get_device_friendly_name(HANDLE hDevice, char *name, UINT nameSize) {
    char devicePath[256];
    UINT pathSize = sizeof(devicePath);
    if (GetRawInputDeviceInfoA(hDevice, RIDI_DEVICENAME, devicePath, &pathSize) == (UINT)-1) {
        snprintf(name, nameSize, "unknown");
        return;
    }

    HANDLE h = CreateFileA(devicePath, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        wchar_t productName[128];
        if (HidD_GetProductString(h, productName, sizeof(productName))) {
            int len = WideCharToMultiByte(CP_UTF8, 0, productName, -1, name, nameSize, NULL, NULL);
            if (len > 1) {
                CloseHandle(h);
                return;
            }
        }
        CloseHandle(h);
    }

    const char *vid = strstr(devicePath, "VID_");
    const char *pid = strstr(devicePath, "PID_");
    if (vid && pid && vid < pid) {
        char vidHex[8] = {0};
        char pidHex[8] = {0};
        memcpy(vidHex, vid + 4, 4);
        memcpy(pidHex, pid + 4, 4);
        snprintf(name, nameSize, "HID#%s/%s", vidHex, pidHex);
        return;
    }

    snprintf(name, nameSize, "handle:%p", (void*)hDevice);
}

static void process_raw_input(RAWINPUT *raw) {
    if (raw->header.dwType != RIM_TYPEMOUSE) return;

    char device[256];
    if (raw->header.hDevice == NULL) {
        snprintf(device, sizeof(device), "injected");
    } else {
        get_device_friendly_name(raw->header.hDevice, device, sizeof(device));
    }

    USHORT flags = raw->data.mouse.usButtonFlags;
    if (flags & RI_MOUSE_LEFT_BUTTON_DOWN) on_mouse_event(0, 1, device, g_userdata);
    if (flags & RI_MOUSE_LEFT_BUTTON_UP)   on_mouse_event(0, 0, device, g_userdata);
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

        process_raw_input((RAWINPUT *)buf);
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
