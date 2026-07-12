#ifndef MICRO_OS_H
#define MICRO_OS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t micro_os_pid(void);
void micro_os_stdout(const char *text);
void micro_os_stderr(const char *text);
int32_t micro_os_stdin(char *buffer, int32_t maxBytes);
// Mount a retained platform view as an overlay; returns an overlay id. A process
// may hold several overlays (e.g. a window plus a fullscreen layer on top) and
// drop them individually with micro_os_overlay_remove. Process exit drops them all.
int32_t micro_os_overlay_platform_view_fullscreen(void *retainedPlatformView);
int32_t micro_os_overlay_platform_view(void *retainedPlatformView, double x, double y, double width, double height);
void micro_os_overlay_remove(int32_t overlayID);
// Same, but with the owning pid named explicitly (for a display server adding an
// overlay from the main thread, where the per-thread pid is not its own).
int32_t micro_os_overlay_platform_view_fullscreen_for_pid(void *retainedPlatformView, int32_t pid);
void micro_os_overlay_remove_for_pid(int32_t overlayID, int32_t pid);
void micro_os_kernel_panic(const char *text);
void micro_os_service_register(const char *name, void *serviceTable);
void *micro_os_service_lookup(const char *name);
void micro_os_process_observe_exit(void (*callback)(int32_t pid, void *context), void *context);
int32_t micro_os_ptty_create(const char *name);
void micro_os_ptty_write(int32_t id, const char *text);
void micro_os_ptty_input(int32_t id, const char *text);
void micro_os_ptty_key_input(int32_t id, int32_t key, uint32_t modifiers, const char *text);
void micro_os_keyboard_device_input(int32_t phase, int32_t key, uint32_t modifiers, const char *text);
int32_t micro_os_keyboard_device_subscribe(void (*callback)(int32_t phase, int32_t key, uint32_t modifiers, const char *text, void *context), void *context);
void micro_os_keyboard_device_unsubscribe(int32_t subscriptionID);
int32_t micro_os_ptty_read(int32_t id, char *buffer, int32_t maxBytes);
void micro_os_ptty_observe_output(int32_t id, void (*callback)(int32_t id, const char *text, void *context), void *context);
uint32_t micro_os_tty_get_lflag(void);
void micro_os_tty_set_lflag(uint32_t lflag);
void micro_os_process_keep_alive(void);
// Non-blocking: nonzero once `kill` (cooperative termination) has been requested
// for the calling process. A GUI runtime's frame loop polls this so it can break
// out and let the app's own main() clean up (close window, stop audio, …).
int32_t micro_os_process_termination_requested(void);
void micro_os_process_exit(int32_t code) __attribute__((noreturn));
int32_t micro_os_process_signal(int32_t pid, int32_t signal);
int32_t micro_os_signal_set_ignored(int32_t pid, int32_t signal, int32_t ignored);
int32_t micro_os_setpgid(int32_t pid, int32_t pgid);
int32_t micro_os_getpgid(int32_t pid);
int32_t micro_os_tcsetpgrp(int32_t tty_fd, int32_t pgid);
int32_t micro_os_tcgetpgrp(int32_t tty_fd);
int32_t micro_os_spawn(const char *dylib, int32_t argc, char **argv);
int32_t micro_os_spawn_with_tty(const char *dylib, int32_t argc, char **argv, int32_t ttyID);
int32_t micro_os_fork(void);
int32_t micro_os_exec_forked_child(int32_t pid, const char *dylib, int32_t argc, char **argv);
void micro_os_exit_forked_child(int32_t pid, int32_t code);
void micro_os_fork_child_begin(int32_t child);
void micro_os_fork_child_end(void);
int32_t micro_os_waitpid(int32_t pid, int32_t *status, int32_t options);
int32_t micro_os_access(const char *path, int32_t mode);
int32_t micro_os_fd_kind(int32_t fd);
int32_t micro_os_fd_open(int32_t kind, const void *bytes, int32_t count);
int32_t micro_os_fd_dup(int32_t fd);
int32_t micro_os_fd_dup2(int32_t fd, int32_t fd2);
int32_t micro_os_fd_close(int32_t fd);
int32_t micro_os_fd_pipe(int32_t fds[2]);
int32_t micro_os_fd_read(int32_t fd, void *buffer, int32_t count);
int32_t micro_os_fd_write(int32_t fd, const void *buffer, int32_t count);
int64_t micro_os_fd_lseek(int32_t fd, int64_t offset, int32_t whence);

#define MICRO_OS_PROCESS_COMMAND_LENGTH 64
#define MICRO_OS_PROCESS_ARGV_LENGTH 256

typedef struct micro_os_process_info {
    int32_t pid;
    int32_t parent_pid;
    int32_t pgid;
    int32_t tty_id;
    int32_t state;
    uint64_t start_time_ms;
    char command[MICRO_OS_PROCESS_COMMAND_LENGTH];
    char argv[MICRO_OS_PROCESS_ARGV_LENGTH];
} micro_os_process_info_t;

int32_t micro_os_process_snapshot(micro_os_process_info_t *buffer, int32_t maxEntries);

typedef int32_t (*micro_os_entry_fn)(int32_t argc, char **argv);
typedef int32_t (*micro_os_wm_open_window_fn)(int32_t ownerPID, const char *title, void *retainedPlatformView, double width, double height);
typedef void (*micro_os_wm_set_title_fn)(int32_t windowID, const char *title);
typedef void (*micro_os_wm_set_permission_fn)(int32_t windowID, const char *key, int32_t enabled);
typedef void (*micro_os_wm_close_handler_fn)(int32_t windowID, void *context);
typedef void (*micro_os_wm_set_close_handler_fn)(int32_t windowID, micro_os_wm_close_handler_fn handler, void *context);
typedef void (*micro_os_wm_set_fullscreen_fn)(int32_t windowID, int32_t enabled);
typedef int32_t (*micro_os_wm_add_chrome_view_fn)(int32_t windowID, void *retainedViewBox);

typedef struct micro_os_wm_service_table {
    int32_t version;
    micro_os_wm_open_window_fn openWindow;
    micro_os_wm_set_title_fn setTitle;
    micro_os_wm_set_permission_fn setPermission;
    micro_os_wm_set_close_handler_fn setCloseHandler;
    micro_os_wm_set_fullscreen_fn setFullscreen;
    micro_os_wm_add_chrome_view_fn addChromeView;
} micro_os_wm_service_table;

#define MICRO_OS_WM_SERVICE_NAME "micro-os.wm.v1"

#ifdef __cplusplus
}
#endif

#endif
