#include "windows.h"
#include "micro_os.h"
#include "micro_os_gui_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define WIN32_MAX_CLASSES 64
#define WIN32_MAX_WINDOWS 128

typedef struct win32_class {
    int in_use;
    char *name;
    WNDPROC proc;
} win32_class;

typedef struct win32_window {
    int in_use;
    int id;
    char *class_name;
    char *title;
    DWORD style;
    int control_id;
    HWND parent;
    WNDPROC proc;
    micro_os_gui_window_t gui_window;
    int quit_requested;
} win32_window;

static win32_class win32_classes[WIN32_MAX_CLASSES];
static win32_window win32_windows[WIN32_MAX_WINDOWS];
static int win32_next_atom = 1;
static int win32_next_window_id = 1;
static int win32_quit_requested;
static int win32_exit_code;

static char *win32_strdup(const char *text) {
    const char *resolved = text ? text : "";
    size_t length = strlen(resolved);
    char *copy = (char *)malloc(length + 1);
    if (!copy) {
        return NULL;
    }
    memcpy(copy, resolved, length + 1);
    return copy;
}

static int win32_strieq(const char *lhs, const char *rhs) {
    if (!lhs || !rhs) {
        return 0;
    }

    while (*lhs && *rhs) {
        char a = *lhs;
        char b = *rhs;
        if (a >= 'A' && a <= 'Z') { a = (char)(a - 'A' + 'a'); }
        if (b >= 'A' && b <= 'Z') { b = (char)(b - 'A' + 'a'); }
        if (a != b) {
            return 0;
        }
        lhs++;
        rhs++;
    }
    return *lhs == '\0' && *rhs == '\0';
}

static win32_window *win32_window_from_handle(HWND handle) {
    if (!handle) {
        return NULL;
    }
    win32_window *window = (win32_window *)handle;
    if (!window->in_use) {
        return NULL;
    }
    return window;
}

static win32_class *win32_class_for_name(const char *name) {
    for (int index = 0; index < WIN32_MAX_CLASSES; index++) {
        if (win32_classes[index].in_use && strcmp(win32_classes[index].name, name) == 0) {
            return &win32_classes[index];
        }
    }
    return NULL;
}

static win32_window *win32_alloc_window(void) {
    for (int index = 0; index < WIN32_MAX_WINDOWS; index++) {
        if (!win32_windows[index].in_use) {
            win32_window *window = &win32_windows[index];
            memset(window, 0, sizeof(*window));
            window->in_use = 1;
            window->id = win32_next_window_id++;
            window->gui_window = -1;
            return window;
        }
    }
    return NULL;
}

static int win32_is_builtin_control(const char *class_name) {
    return win32_strieq(class_name, "STATIC") || win32_strieq(class_name, "BUTTON");
}

static void win32_emit_child(micro_os_gui_window_t gui_window, win32_window *child) {
    if (win32_strieq(child->class_name, "STATIC")) {
        micro_os_gui_window_add_text(gui_window, child->title);
        return;
    }

    if (win32_strieq(child->class_name, "BUTTON")) {
        char control_id[64];
        snprintf(control_id, sizeof(control_id), "win32-%d", child->control_id);
        micro_os_gui_window_add_button(gui_window, control_id, child->title);
    }
}

static void win32_show_top_level(win32_window *window) {
    if (window->gui_window >= 0) {
        return;
    }

    window->gui_window = micro_os_gui_window_create(window->title, 560, 360);
    if (window->gui_window < 0) {
        return;
    }

    for (int index = 0; index < WIN32_MAX_WINDOWS; index++) {
        win32_window *child = &win32_windows[index];
        if (child->in_use && child->parent == (HWND)window) {
            win32_emit_child(window->gui_window, child);
        }
    }
    micro_os_gui_window_show(window->gui_window);
}

static win32_window *win32_find_child_by_control(HWND parent, int control_id) {
    for (int index = 0; index < WIN32_MAX_WINDOWS; index++) {
        win32_window *child = &win32_windows[index];
        if (child->in_use && child->parent == parent && child->control_id == control_id) {
            return child;
        }
    }
    return NULL;
}

ATOM RegisterClassA(const WNDCLASSA *wndClass) {
    if (!wndClass || !wndClass->lpszClassName) {
        return 0;
    }

    win32_class *existing = win32_class_for_name(wndClass->lpszClassName);
    if (existing) {
        existing->proc = wndClass->lpfnWndProc;
        return 1;
    }

    for (int index = 0; index < WIN32_MAX_CLASSES; index++) {
        if (!win32_classes[index].in_use) {
            win32_classes[index].in_use = 1;
            win32_classes[index].name = win32_strdup(wndClass->lpszClassName);
            win32_classes[index].proc = wndClass->lpfnWndProc;
            return (ATOM)win32_next_atom++;
        }
    }
    return 0;
}

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
) {
    (void)exStyle;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)instance;

    win32_window *window = win32_alloc_window();
    if (!window) {
        return NULL;
    }

    window->class_name = win32_strdup(className ? className : "");
    window->title = win32_strdup(windowName ? windowName : "");
    window->style = style;
    window->parent = parent;
    window->control_id = (int)(intptr_t)menu;

    win32_class *registered = win32_class_for_name(window->class_name);
    if (registered) {
        window->proc = registered->proc;
    } else if (!win32_is_builtin_control(window->class_name) && parent == NULL) {
        window->proc = DefWindowProcA;
    }

    if (window->proc && parent == NULL) {
        window->proc((HWND)window, WM_CREATE, 0, (LPARAM)param);
    }

    if ((style & WS_VISIBLE) && parent == NULL) {
        win32_show_top_level(window);
    }

    return (HWND)window;
}

BOOL ShowWindow(HWND handle, int commandShow) {
    (void)commandShow;
    win32_window *window = win32_window_from_handle(handle);
    if (!window) {
        return FALSE;
    }
    if (window->parent == NULL) {
        win32_show_top_level(window);
    }
    return TRUE;
}

BOOL UpdateWindow(HWND window) {
    (void)window;
    return TRUE;
}

BOOL DestroyWindow(HWND handle) {
    win32_window *window = win32_window_from_handle(handle);
    if (!window) {
        return FALSE;
    }

    if (window->proc) {
        window->proc(handle, WM_DESTROY, 0, 0);
    }
    if (window->gui_window >= 0) {
        micro_os_gui_window_close(window->gui_window);
    }
    window->in_use = 0;
    return TRUE;
}

BOOL GetMessageA(MSG *message, HWND windowFilter, UINT messageFilterMin, UINT messageFilterMax) {
    (void)windowFilter;
    (void)messageFilterMin;
    (void)messageFilterMax;
    if (!message) {
        return FALSE;
    }

    if (win32_quit_requested) {
        return FALSE;
    }

    for (;;) {
        micro_os_gui_event event;
        int result = micro_os_gui_next_event(&event);
        if (win32_quit_requested) {
            return FALSE;
        }
        if (result <= 0) {
            usleep(16000);
            continue;
        }

        if (strncmp(event.control, "win32-", 6) != 0) {
            continue;
        }

        int control_id = atoi(event.control + 6);
        for (int index = 0; index < WIN32_MAX_WINDOWS; index++) {
            win32_window *top = &win32_windows[index];
            if (!top->in_use || top->parent != NULL || top->gui_window != event.window) {
                continue;
            }

            win32_window *child = win32_find_child_by_control((HWND)top, control_id);
            if (!child) {
                continue;
            }

            message->hwnd = (HWND)top;
            message->message = WM_COMMAND;
            message->wParam = MAKEWPARAM(control_id, BN_CLICKED);
            message->lParam = (LPARAM)(HWND)child;
            return TRUE;
        }
    }
}

BOOL TranslateMessage(const MSG *message) {
    (void)message;
    return TRUE;
}

LRESULT DispatchMessageA(const MSG *message) {
    if (!message) {
        return 0;
    }
    win32_window *window = win32_window_from_handle(message->hwnd);
    if (!window || !window->proc) {
        return 0;
    }
    return window->proc(message->hwnd, message->message, message->wParam, message->lParam);
}

LRESULT DefWindowProcA(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    (void)wParam;
    (void)lParam;
    if (message == WM_CLOSE) {
        DestroyWindow(window);
    }
    return 0;
}

void PostQuitMessage(int exitCode) {
    win32_exit_code = exitCode;
    win32_quit_requested = 1;
}

int MessageBoxA(HWND window, LPCSTR text, LPCSTR caption, UINT type) {
    (void)window;
    (void)type;
    micro_os_stdout(caption ? caption : "Message");
    micro_os_stdout(": ");
    micro_os_stdout(text ? text : "");
    micro_os_stdout("\n");
    return 0;
}

HCURSOR LoadCursorA(HINSTANCE instance, LPCSTR cursorName) {
    (void)instance;
    (void)cursorName;
    return NULL;
}

int micro_os_win32_exit_code(void) {
    return win32_exit_code;
}
