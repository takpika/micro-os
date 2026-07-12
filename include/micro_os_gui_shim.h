#ifndef MICRO_OS_GUI_SHIM_H
#define MICRO_OS_GUI_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t micro_os_gui_window_t;

typedef struct micro_os_gui_event {
    int32_t window;
    char control[64];
    char name[32];
} micro_os_gui_event;

int micro_os_gui_init(void);
micro_os_gui_window_t micro_os_gui_window_create(const char *title, double width, double height);
int micro_os_gui_window_add_text(micro_os_gui_window_t window, const char *text);
int micro_os_gui_window_add_label(micro_os_gui_window_t window, const char *text);
int micro_os_gui_window_add_button(micro_os_gui_window_t window, const char *controlID, const char *title);
int micro_os_gui_window_add_spacer(micro_os_gui_window_t window);
int micro_os_gui_window_add_divider(micro_os_gui_window_t window);
int micro_os_gui_window_show(micro_os_gui_window_t window);
int micro_os_gui_window_update(micro_os_gui_window_t window);
int micro_os_gui_window_close(micro_os_gui_window_t window);
int micro_os_gui_next_event(micro_os_gui_event *event);
void micro_os_gui_run(void);

int micro_os_gui_NSApplicationMain(int argc, char **argv);

#ifdef MICRO_OS_GUI_SHIM_MAC_COMPAT
#define NSApplicationMain(argc, argv) micro_os_gui_NSApplicationMain((argc), (argv))
#endif

#ifdef __cplusplus
}
#endif

#endif
