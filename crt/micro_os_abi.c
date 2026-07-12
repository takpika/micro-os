// MicroOSABI — the micro_os_* host ABI as a real dylib.
//
// Programs resolve the host ABI (micro_os_spawn, _stdout, …) by linking this
// framework explicitly. The app loads it before any program starts, and each
// function is a thin forwarder to the real implementation, looked up once
// through a resolver the app installs at boot (see micro_os_abi_set_resolver
// below).
#include "micro_os.h"

// The app installs a resolver mapping a host-ABI symbol name to its real
// implementation. We must NOT look it up from here ourselves: on device dyld
// won't resolve these against the main executable; dlsym(RTLD_MAIN_ONLY) misses
// them in Debug (the host code lives in the debug dylib, not the executable);
// and RTLD_DEFAULT could match our own forwarder. The app's resolver uses
// RTLD_SELF, which finds the host code in the app's own image in every config.
static void *(*g_resolve)(const char *name);
void micro_os_abi_set_resolver(void *(*resolver)(const char *name)) { g_resolve = resolver; }

// Cached pointer to the real implementation of `name`.
#define IMPL(name) ({ static void *fp; if (!fp && g_resolve) fp = g_resolve(#name); fp; })

int32_t micro_os_pid(void) { return ((int32_t(*)(void))IMPL(micro_os_pid))(); }
void micro_os_stdout(const char *t) { ((void(*)(const char*))IMPL(micro_os_stdout))(t); }
void micro_os_stderr(const char *t) { ((void(*)(const char*))IMPL(micro_os_stderr))(t); }
int32_t micro_os_stdin(char *b, int32_t n) { return ((int32_t(*)(char*,int32_t))IMPL(micro_os_stdin))(b,n); }

int32_t micro_os_overlay_platform_view_fullscreen(void *v) {
    return ((int32_t(*)(void*))IMPL(micro_os_overlay_platform_view_fullscreen))(v);
}
int32_t micro_os_overlay_platform_view(void *v, double x, double y, double w, double h) {
    return ((int32_t(*)(void*,double,double,double,double))IMPL(micro_os_overlay_platform_view))(v,x,y,w,h);
}
void micro_os_overlay_remove(int32_t id) { ((void(*)(int32_t))IMPL(micro_os_overlay_remove))(id); }
int32_t micro_os_overlay_platform_view_fullscreen_for_pid(void *v, int32_t pid) {
    return ((int32_t(*)(void*,int32_t))IMPL(micro_os_overlay_platform_view_fullscreen_for_pid))(v,pid);
}
void micro_os_overlay_remove_for_pid(int32_t id, int32_t pid) {
    ((void(*)(int32_t,int32_t))IMPL(micro_os_overlay_remove_for_pid))(id,pid);
}

void micro_os_kernel_panic(const char *t) { ((void(*)(const char*))IMPL(micro_os_kernel_panic))(t); }
void micro_os_service_register(const char *n, void *s) { ((void(*)(const char*,void*))IMPL(micro_os_service_register))(n,s); }
void *micro_os_service_lookup(const char *n) { return ((void*(*)(const char*))IMPL(micro_os_service_lookup))(n); }
void micro_os_process_observe_exit(void (*cb)(int32_t,void*), void *ctx) {
    ((void(*)(void(*)(int32_t,void*),void*))IMPL(micro_os_process_observe_exit))(cb,ctx);
}

int32_t micro_os_ptty_create(const char *n) { return ((int32_t(*)(const char*))IMPL(micro_os_ptty_create))(n); }
void micro_os_ptty_write(int32_t id, const char *t) { ((void(*)(int32_t,const char*))IMPL(micro_os_ptty_write))(id,t); }
void micro_os_ptty_input(int32_t id, const char *t) { ((void(*)(int32_t,const char*))IMPL(micro_os_ptty_input))(id,t); }
void micro_os_ptty_key_input(int32_t id, int32_t key, uint32_t modifiers, const char *text) {
    ((void(*)(int32_t,int32_t,uint32_t,const char*))IMPL(micro_os_ptty_key_input))(id,key,modifiers,text);
}
void micro_os_keyboard_device_input(int32_t phase, int32_t key, uint32_t modifiers, const char *text) {
    ((void(*)(int32_t,int32_t,uint32_t,const char*))IMPL(micro_os_keyboard_device_input))(phase,key,modifiers,text);
}
int32_t micro_os_ptty_read(int32_t id, char *b, int32_t n) { return ((int32_t(*)(int32_t,char*,int32_t))IMPL(micro_os_ptty_read))(id,b,n); }
void micro_os_ptty_observe_output(int32_t id, void (*cb)(int32_t,const char*,void*), void *ctx) {
    ((void(*)(int32_t,void(*)(int32_t,const char*,void*),void*))IMPL(micro_os_ptty_observe_output))(id,cb,ctx);
}

int32_t micro_os_keyboard_device_subscribe(void (*cb)(int32_t,int32_t,uint32_t,const char*,void*), void *ctx) {
    return ((int32_t(*)(void(*)(int32_t,int32_t,uint32_t,const char*,void*),void*))IMPL(micro_os_keyboard_device_subscribe))(cb,ctx);
}
void micro_os_keyboard_device_unsubscribe(int32_t id) {
    ((void(*)(int32_t))IMPL(micro_os_keyboard_device_unsubscribe))(id);
}

uint32_t micro_os_tty_get_lflag(void) { return ((uint32_t(*)(void))IMPL(micro_os_tty_get_lflag))(); }
void micro_os_tty_set_lflag(uint32_t f) { ((void(*)(uint32_t))IMPL(micro_os_tty_set_lflag))(f); }

void micro_os_process_keep_alive(void) { ((void(*)(void))IMPL(micro_os_process_keep_alive))(); }
int32_t micro_os_process_termination_requested(void) { return ((int32_t(*)(void))IMPL(micro_os_process_termination_requested))(); }
void micro_os_process_exit(int32_t code) { ((void(*)(int32_t))IMPL(micro_os_process_exit))(code); __builtin_unreachable(); }
int32_t micro_os_process_signal(int32_t pid, int32_t sig) { return ((int32_t(*)(int32_t,int32_t))IMPL(micro_os_process_signal))(pid,sig); }
int32_t micro_os_signal_set_ignored(int32_t pid, int32_t sig, int32_t ignored) { return ((int32_t(*)(int32_t,int32_t,int32_t))IMPL(micro_os_signal_set_ignored))(pid,sig,ignored); }
int32_t micro_os_setpgid(int32_t pid, int32_t pgid) { return ((int32_t(*)(int32_t,int32_t))IMPL(micro_os_setpgid))(pid,pgid); }
int32_t micro_os_getpgid(int32_t pid) { return ((int32_t(*)(int32_t))IMPL(micro_os_getpgid))(pid); }
int32_t micro_os_tcsetpgrp(int32_t fd, int32_t pgid) { return ((int32_t(*)(int32_t,int32_t))IMPL(micro_os_tcsetpgrp))(fd,pgid); }
int32_t micro_os_tcgetpgrp(int32_t fd) { return ((int32_t(*)(int32_t))IMPL(micro_os_tcgetpgrp))(fd); }
int32_t micro_os_process_snapshot(micro_os_process_info_t *b, int32_t n) { return ((int32_t(*)(micro_os_process_info_t*,int32_t))IMPL(micro_os_process_snapshot))(b,n); }

int32_t micro_os_spawn(const char *d, int32_t c, char **v) { return ((int32_t(*)(const char*,int32_t,char**))IMPL(micro_os_spawn))(d,c,v); }
int32_t micro_os_spawn_with_tty(const char *d, int32_t c, char **v, int32_t t) {
    return ((int32_t(*)(const char*,int32_t,char**,int32_t))IMPL(micro_os_spawn_with_tty))(d,c,v,t);
}
int32_t micro_os_fork(void) { return ((int32_t(*)(void))IMPL(micro_os_fork))(); }
int32_t micro_os_exec_forked_child(int32_t pid, const char *d, int32_t c, char **v) {
    return ((int32_t(*)(int32_t,const char*,int32_t,char**))IMPL(micro_os_exec_forked_child))(pid,d,c,v);
}
void micro_os_exit_forked_child(int32_t pid, int32_t code) { ((void(*)(int32_t,int32_t))IMPL(micro_os_exit_forked_child))(pid,code); }
void micro_os_fork_child_begin(int32_t c) { ((void(*)(int32_t))IMPL(micro_os_fork_child_begin))(c); }
void micro_os_fork_child_end(void) { ((void(*)(void))IMPL(micro_os_fork_child_end))(); }
int32_t micro_os_waitpid(int32_t pid, int32_t *st, int32_t o) { return ((int32_t(*)(int32_t,int32_t*,int32_t))IMPL(micro_os_waitpid))(pid,st,o); }

int32_t micro_os_access(const char *p, int32_t m) { return ((int32_t(*)(const char*,int32_t))IMPL(micro_os_access))(p,m); }
int32_t micro_os_fd_kind(int32_t fd) { return ((int32_t(*)(int32_t))IMPL(micro_os_fd_kind))(fd); }
int32_t micro_os_fd_open(int32_t k, const void *b, int32_t c) { return ((int32_t(*)(int32_t,const void*,int32_t))IMPL(micro_os_fd_open))(k,b,c); }
int32_t micro_os_fd_dup(int32_t fd) { return ((int32_t(*)(int32_t))IMPL(micro_os_fd_dup))(fd); }
int32_t micro_os_fd_dup2(int32_t fd, int32_t fd2) { return ((int32_t(*)(int32_t,int32_t))IMPL(micro_os_fd_dup2))(fd,fd2); }
int32_t micro_os_fd_close(int32_t fd) { return ((int32_t(*)(int32_t))IMPL(micro_os_fd_close))(fd); }
int32_t micro_os_fd_pipe(int32_t fds[2]) { return ((int32_t(*)(int32_t*))IMPL(micro_os_fd_pipe))(fds); }
int32_t micro_os_fd_read(int32_t fd, void *b, int32_t c) { return ((int32_t(*)(int32_t,void*,int32_t))IMPL(micro_os_fd_read))(fd,b,c); }
int32_t micro_os_fd_write(int32_t fd, const void *b, int32_t c) { return ((int32_t(*)(int32_t,const void*,int32_t))IMPL(micro_os_fd_write))(fd,b,c); }
int64_t micro_os_fd_lseek(int32_t fd, int64_t off, int32_t wh) { return ((int64_t(*)(int32_t,int64_t,int32_t))IMPL(micro_os_fd_lseek))(fd,off,wh); }
