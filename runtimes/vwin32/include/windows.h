#ifndef MICRO_OS_WINDOWS_H
#define MICRO_OS_WINDOWS_H

#if !defined(MICRO_OS_WIN32_SHIM)
#error "windows.h is provided by microOS only when MICRO_OS_WIN32_SHIM is defined."
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NULL
#define NULL ((void *)0)
#endif

#define WINAPI
#define CALLBACK
#define APIENTRY WINAPI

typedef void *HANDLE;
typedef void *HINSTANCE;
typedef void *HICON;
typedef void *HCURSOR;
typedef void *HBRUSH;
typedef void *HMENU;
typedef void *HWND;
typedef const char *LPCSTR;
typedef char *LPSTR;
typedef void *LPVOID;
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef intptr_t LRESULT;
typedef uint32_t UINT;
typedef uint32_t DWORD;
typedef int32_t BOOL;
typedef uint16_t WORD;
typedef uint16_t ATOM;
typedef int32_t INT;

typedef LRESULT (CALLBACK *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct WNDCLASSA {
    UINT style;
    WNDPROC lpfnWndProc;
    int cbClsExtra;
    int cbWndExtra;
    HINSTANCE hInstance;
    HICON hIcon;
    HCURSOR hCursor;
    HBRUSH hbrBackground;
    LPCSTR lpszMenuName;
    LPCSTR lpszClassName;
} WNDCLASSA;

typedef WNDCLASSA WNDCLASS;

typedef struct MSG {
    HWND hwnd;
    UINT message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD time;
    int pt_x;
    int pt_y;
} MSG;

#define TRUE 1
#define FALSE 0

#define CW_USEDEFAULT ((int)0x80000000)

#define WS_OVERLAPPED 0x00000000u
#define WS_CAPTION 0x00C00000u
#define WS_SYSMENU 0x00080000u
#define WS_THICKFRAME 0x00040000u
#define WS_MINIMIZEBOX 0x00020000u
#define WS_MAXIMIZEBOX 0x00010000u
#define WS_OVERLAPPEDWINDOW (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX)
#define WS_CHILD 0x40000000u
#define WS_VISIBLE 0x10000000u
#define BS_PUSHBUTTON 0x00000000u

#define SW_HIDE 0
#define SW_SHOWNORMAL 1
#define SW_SHOW 5
#define SW_SHOWDEFAULT 10

#define WM_NULL 0x0000u
#define WM_CREATE 0x0001u
#define WM_DESTROY 0x0002u
#define WM_CLOSE 0x0010u
#define WM_COMMAND 0x0111u

#define BN_CLICKED 0

#define IDC_ARROW ((LPCSTR)32512)
#define COLOR_WINDOW 5

#define LOWORD(l) ((WORD)((uintptr_t)(l) & 0xffffu))
#define HIWORD(l) ((WORD)((((uintptr_t)(l)) >> 16) & 0xffffu))
#define MAKEWPARAM(low, high) ((WPARAM)((((uintptr_t)(WORD)(high)) << 16) | (uintptr_t)(WORD)(low)))

ATOM RegisterClassA(const WNDCLASSA *wndClass);
HWND CreateWindowExA(
    DWORD exStyle,
    LPCSTR className,
    LPCSTR windowName,
    DWORD style,
    int x,
    int y,
    int width,
    int height,
    HWND parent,
    HMENU menu,
    HINSTANCE instance,
    LPVOID param
);
BOOL ShowWindow(HWND window, int commandShow);
BOOL UpdateWindow(HWND window);
BOOL DestroyWindow(HWND window);
BOOL GetMessageA(MSG *message, HWND window, UINT messageFilterMin, UINT messageFilterMax);
BOOL TranslateMessage(const MSG *message);
LRESULT DispatchMessageA(const MSG *message);
LRESULT DefWindowProcA(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
void PostQuitMessage(int exitCode);
int MessageBoxA(HWND window, LPCSTR text, LPCSTR caption, UINT type);
HCURSOR LoadCursorA(HINSTANCE instance, LPCSTR cursorName);

#define RegisterClass RegisterClassA
#define CreateWindowEx CreateWindowExA
#define CreateWindowA(className, windowName, style, x, y, width, height, parent, menu, instance, param) \
    CreateWindowExA(0, (className), (windowName), (style), (x), (y), (width), (height), (parent), (menu), (instance), (param))
#define CreateWindow CreateWindowA
#define GetMessage GetMessageA
#define DispatchMessage DispatchMessageA
#define DefWindowProc DefWindowProcA
#define MessageBox MessageBoxA
#define LoadCursor LoadCursorA

#ifdef __cplusplus
}
#endif

#endif
