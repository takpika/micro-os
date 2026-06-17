// Direct, dlsym-free resolver for the host ABI.
//
// MicroOSABI.framework (which programs bind their micro_os_* imports to) calls a
// resolver to reach the real implementations — the kernel's @_cdecl exports in
// this app target. We must NOT use dlsym for that on device: depending on the
// configuration the host code lives in the main executable (Release) or the debug
// dylib (Debug), and neither RTLD_MAIN_ONLY nor RTLD_SELF reliably finds it across
// both. Instead this resolver returns the implementations by direct reference —
// the C compiler resolves each name to the @_cdecl symbol at link time, so there
// is no runtime symbol lookup at all.
#include <string.h>
#include <dlfcn.h>
#include "../../include/micro_os.h"

void *micro_os_host_resolve(const char *name) {
    if (!name) return (void *)0;
#define R(fn) if (strcmp(name, #fn) == 0) return (void *)fn;
    R(micro_os_pid)
    R(micro_os_stdout)
    R(micro_os_stderr)
    R(micro_os_stdin)
    R(micro_os_overlay_platform_view_fullscreen)
    R(micro_os_overlay_platform_view)
    R(micro_os_overlay_remove)
    R(micro_os_overlay_platform_view_fullscreen_for_pid)
    R(micro_os_overlay_remove_for_pid)
    R(micro_os_kernel_panic)
    R(micro_os_service_register)
    R(micro_os_service_lookup)
    R(micro_os_process_observe_exit)
    R(micro_os_ptty_create)
    R(micro_os_ptty_write)
    R(micro_os_ptty_input)
    R(micro_os_ptty_read)
    R(micro_os_ptty_observe_output)
    R(micro_os_tty_get_lflag)
    R(micro_os_tty_set_lflag)
    R(micro_os_process_keep_alive)
    R(micro_os_process_termination_requested)
    R(micro_os_process_exit)
    R(micro_os_spawn)
    R(micro_os_spawn_with_tty)
    R(micro_os_fork)
    R(micro_os_exec_forked_child)
    R(micro_os_exit_forked_child)
    R(micro_os_fork_child_begin)
    R(micro_os_fork_child_end)
    R(micro_os_waitpid)
    R(micro_os_access)
    R(micro_os_fd_kind)
    R(micro_os_fd_open)
    R(micro_os_fd_dup)
    R(micro_os_fd_dup2)
    R(micro_os_fd_close)
    R(micro_os_fd_pipe)
    R(micro_os_fd_read)
    R(micro_os_fd_write)
    R(micro_os_fd_lseek)
#undef R
    return (void *)0;
}

// Hand the resolver above to a freshly dlopen()'d MicroOSABI.framework.
void micro_os_install_resolver(void *abi_handle) {
    if (!abi_handle) return;
    void (*set_resolver)(void *(*)(const char *)) =
        (void (*)(void *(*)(const char *)))dlsym(abi_handle, "micro_os_abi_set_resolver");
    if (set_resolver) set_resolver(micro_os_host_resolve);
}
