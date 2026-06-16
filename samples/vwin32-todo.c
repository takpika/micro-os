#include <windows.h>
#include <stdio.h>

#define ID_PRINT 1001
#define ID_EXIT 1002

static const char *windowClassName = "MicroOSWin32TodoWindow";

static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    (void)lParam;

    switch (message) {
    case WM_CREATE:
        CreateWindow(
            "STATIC",
            "Ported Win32 GUI",
            WS_CHILD | WS_VISIBLE,
            24,
            24,
            260,
            24,
            hwnd,
            NULL,
            NULL,
            NULL
        );
        CreateWindow(
            "STATIC",
            "This is ordinary Win32 code.",
            WS_CHILD | WS_VISIBLE,
            24,
            56,
            280,
            24,
            hwnd,
            NULL,
            NULL,
            NULL
        );
        CreateWindow(
            "BUTTON",
            "Print message",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            24,
            104,
            160,
            32,
            hwnd,
            (HMENU)ID_PRINT,
            NULL,
            NULL
        );
        CreateWindow(
            "BUTTON",
            "Exit",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            24,
            148,
            90,
            32,
            hwnd,
            (HMENU)ID_EXIT,
            NULL,
            NULL
        );
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case ID_PRINT:
            puts("win32-gui: button clicked");
            return 0;
        case ID_EXIT:
            DestroyWindow(hwnd);
            return 0;
        default:
            return 0;
        }
    case WM_DESTROY:
        puts("win32-gui: exiting");
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProc(hwnd, message, wParam, lParam);
    }
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previousInstance, LPSTR commandLine, int commandShow) {
    (void)previousInstance;
    (void)commandLine;

    WNDCLASS windowClass = {0};
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = windowClassName;
    windowClass.hCursor = LoadCursor(NULL, IDC_ARROW);

    RegisterClass(&windowClass);

    HWND window = CreateWindow(
        windowClassName,
        "Win32 GUI App",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        560,
        360,
        NULL,
        NULL,
        instance,
        NULL
    );

    if (!window) {
        MessageBox(NULL, "CreateWindow failed", "Win32 GUI App", 0);
        return 1;
    }

    ShowWindow(window, commandShow);
    UpdateWindow(window);

    MSG message;
    while (GetMessage(&message, NULL, 0, 0)) {
        TranslateMessage(&message);
        DispatchMessage(&message);
    }

    return 0;
}
