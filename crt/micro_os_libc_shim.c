#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <pthread.h>
#include <termios.h>
#include <sys/types.h>
#include <unistd.h>

#include "micro_os.h"

#ifndef KERN_PROC_INC_THREAD
#define KERN_PROC_INC_THREAD 0
#endif

typedef ssize_t (*read_fn_t)(int, void *, size_t);
typedef ssize_t (*write_fn_t)(int, const void *, size_t);
typedef int (*close_fn_t)(int);
typedef int (*dup_fn_t)(int);
typedef int (*dup2_fn_t)(int, int);
typedef int (*fcntl_fn_t)(int, int, ...);
typedef int (*open_fn_t)(const char *, int, ...);
typedef int (*openat_fn_t)(int, const char *, int, ...);
typedef int (*setsockopt_fn_t)(int, int, int, const void *, socklen_t);
typedef int (*vfprintf_fn_t)(FILE *, const char *, va_list);
typedef int (*fputs_fn_t)(const char *, FILE *);
typedef size_t (*fwrite_fn_t)(const void *, size_t, size_t, FILE *);
typedef int (*fputc_fn_t)(int, FILE *);
typedef int (*pthread_create_fn_t)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
typedef int (*kill_fn_t)(pid_t, int);
typedef int (*sigwait_fn_t)(const sigset_t *, int *);
typedef int (*sysctl_fn_t)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*sysctlbyname_fn_t)(const char *, void *, size_t *, void *, size_t);

#ifndef SOL_IP
#define SOL_IP IPPROTO_IP
#endif

enum {
    SHIM_FD_NONE = 0,
    SHIM_FD_STDIN = 1,
    SHIM_FD_STDOUT = 2,
    SHIM_FD_STDERR = 3,
    SHIM_FD_NULL = 4,
    SHIM_FD_ZERO = 5,
    SHIM_FD_RANDOM = 6,
    SHIM_FD_MEM = 7,
    SHIM_FD_PIPE_READ = 8,
    SHIM_FD_PIPE_WRITE = 9,
};

#define SHIM_MAX_FDS 1024
#define SHIM_MAX_PIPES 64

struct shim_fd_state {
    unsigned char kind;
    int pipe_index;
    char *memory;
    size_t memory_length;
    size_t memory_offset;
};

struct shim_pipe_state {
    int in_use;
    int read_refs;
    int write_refs;
    char *buffer;
    size_t length;
    size_t offset;
    size_t capacity;
};

static struct shim_fd_state shim_fds[SHIM_MAX_FDS] = {
    { SHIM_FD_STDIN, -1, NULL, 0, 0 },
    { SHIM_FD_STDOUT, -1, NULL, 0, 0 },
    { SHIM_FD_STDERR, -1, NULL, 0, 0 },
};
static struct shim_pipe_state shim_pipes[SHIM_MAX_PIPES];

static void shim_free_fd_state(int fd) {
    if (fd < 0 || fd >= SHIM_MAX_FDS) {
        return;
    }
    if (shim_fds[fd].kind == SHIM_FD_MEM) {
        free(shim_fds[fd].memory);
    }
    if (shim_fds[fd].kind == SHIM_FD_PIPE_READ || shim_fds[fd].kind == SHIM_FD_PIPE_WRITE) {
        int index = shim_fds[fd].pipe_index;
        if (index >= 0 && index < SHIM_MAX_PIPES && shim_pipes[index].in_use) {
            if (shim_fds[fd].kind == SHIM_FD_PIPE_READ && shim_pipes[index].read_refs > 0) {
                shim_pipes[index].read_refs--;
            }
            if (shim_fds[fd].kind == SHIM_FD_PIPE_WRITE && shim_pipes[index].write_refs > 0) {
                shim_pipes[index].write_refs--;
            }
            if (shim_pipes[index].read_refs == 0 && shim_pipes[index].write_refs == 0) {
                free(shim_pipes[index].buffer);
                memset(&shim_pipes[index], 0, sizeof(shim_pipes[index]));
            }
        }
    }
    memset(&shim_fds[fd], 0, sizeof(shim_fds[fd]));
    shim_fds[fd].pipe_index = -1;
}

static int shim_alloc_fd(void) {
    for (int fd = 10; fd < SHIM_MAX_FDS; fd++) {
        if (shim_fds[fd].kind == SHIM_FD_NONE) {
            shim_fds[fd].pipe_index = -1;
            return fd;
        }
    }
    errno = EMFILE;
    return -1;
}

static int shim_alloc_fd_with_kind(int kind) {
    int fd = shim_alloc_fd();
    if (fd < 0) {
        return -1;
    }
    shim_fds[fd].kind = (unsigned char)kind;
    return fd;
}

static int shim_tty_fd_kind(int fd);

static int shim_fd_is_virtual(int fd) {
    if (fd >= 0 && fd < SHIM_MAX_FDS && shim_fds[fd].kind != SHIM_FD_NONE) {
        return 1;
    }
    return micro_os_fd_kind((int32_t)fd) != SHIM_FD_NONE;
}

static int shim_is_tty_fd(int fd) {
    int kind = shim_tty_fd_kind(fd);
    return kind == SHIM_FD_STDIN || kind == SHIM_FD_STDOUT || kind == SHIM_FD_STDERR;
}

static int shim_tty_fd_kind(int fd) {
    int host_kind = micro_os_fd_kind((int32_t)fd);
    if (host_kind != SHIM_FD_NONE) {
        return host_kind;
    }
    if (fd == STDIN_FILENO || fd == STDOUT_FILENO || fd == STDERR_FILENO) {
        return SHIM_FD_NONE;
    }
    if (fd >= 0 && fd < SHIM_MAX_FDS) {
        if (shim_fds[fd].kind != SHIM_FD_NONE) {
            return shim_fds[fd].kind;
        }
    }
    return SHIM_FD_NONE;
}

static void shim_mark_tty_fd(int fd, int kind) {
    if (fd >= 0 && fd < SHIM_MAX_FDS) {
        shim_free_fd_state(fd);
        shim_fds[fd].kind = (unsigned char)kind;
        shim_fds[fd].pipe_index = -1;
    }
}

static int shim_open_host_virtual(int kind, const void *bytes, size_t count) {
    int fd = micro_os_fd_open((int32_t)kind, bytes, (int32_t)count);
    if (fd >= 0 && fd < SHIM_MAX_FDS) {
        shim_free_fd_state(fd);
        shim_fds[fd].kind = (unsigned char)kind;
        shim_fds[fd].pipe_index = -1;
    }
    return fd;
}

static vfprintf_fn_t host_vfprintf_fn(void) {
    static vfprintf_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (vfprintf_fn_t)dlsym(RTLD_NEXT, "vfprintf");
    }
    return fn;
}

static fputs_fn_t host_fputs_fn(void) {
    static fputs_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (fputs_fn_t)dlsym(RTLD_NEXT, "fputs");
    }
    return fn;
}

static fwrite_fn_t host_fwrite_fn(void) {
    static fwrite_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (fwrite_fn_t)dlsym(RTLD_NEXT, "fwrite");
    }
    return fn;
}

static fputc_fn_t host_fputc_fn(void) {
    static fputc_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (fputc_fn_t)dlsym(RTLD_NEXT, "fputc");
    }
    return fn;
}

static pthread_create_fn_t host_pthread_create_fn(void) {
    static pthread_create_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (pthread_create_fn_t)dlsym(RTLD_NEXT, "pthread_create");
    }
    return fn;
}

static kill_fn_t host_kill_fn(void) {
    static kill_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (kill_fn_t)dlsym(RTLD_NEXT, "kill");
    }
    return fn;
}

static sigwait_fn_t host_sigwait_fn(void) {
    static sigwait_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (sigwait_fn_t)dlsym(RTLD_NEXT, "sigwait");
    }
    return fn;
}

static sysctl_fn_t host_sysctl_fn(void) {
    static sysctl_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (sysctl_fn_t)dlsym(RTLD_NEXT, "sysctl");
    }
    return fn;
}

static sysctlbyname_fn_t host_sysctlbyname_fn(void) {
    static sysctlbyname_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (sysctlbyname_fn_t)dlsym(RTLD_NEXT, "sysctlbyname");
    }
    return fn;
}

static void shim_sigurg_handler(int sig) {
    (void)sig;
    if (micro_os_process_termination_requested()) {
        micro_os_process_exit(128 + SIGINT);
    }
}

__attribute__((constructor))
static void shim_install_sigurg_handler(void) {
    typedef int (*real_sigaction_fn)(int, const struct sigaction *, struct sigaction *);
    real_sigaction_fn real_sa = (real_sigaction_fn)dlsym(RTLD_NEXT, "sigaction");
    if (real_sa) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = shim_sigurg_handler;
        sa.sa_flags = 0;
        sigemptyset(&sa.sa_mask);
        real_sa(SIGURG, &sa, NULL);
    }
}

static pthread_mutex_t shim_signal_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t shim_signal_cond = PTHREAD_COND_INITIALIZER;
static unsigned int shim_pending_signals;
static _Thread_local char shim_program_name[MICRO_OS_PROCESS_COMMAND_LENGTH];

struct shim_thread_start {
    void *(*start)(void *);
    void *arg;
    int32_t pid;
};

static void *shim_thread_entry(void *context) {
    struct shim_thread_start start = *(struct shim_thread_start *)context;
    free(context);
    if (start.pid > 0) {
        micro_os_fork_child_begin(start.pid);
    }
    return start.start(start.arg);
}

static int shim_stream_kind(FILE *stream) {
    if (stream == stdout || stream == stderr || stream == stdin) {
        return shim_tty_fd_kind(fileno(stream));
    }
    return SHIM_FD_NONE;
}

static int shim_kind_is_virtual_io(int kind) {
    return kind == SHIM_FD_NULL || kind == SHIM_FD_ZERO || kind == SHIM_FD_RANDOM || kind == SHIM_FD_MEM || kind == SHIM_FD_PIPE_READ || kind == SHIM_FD_PIPE_WRITE;
}

static int shim_vwrite(FILE *stream, const char *format, va_list args) {
    int kind = shim_stream_kind(stream);
    if (kind != SHIM_FD_STDOUT && kind != SHIM_FD_STDERR) {
        if (shim_kind_is_virtual_io(kind)) {
            char stack_buffer[1024];
            va_list copy;
            va_copy(copy, args);
            int length = vsnprintf(stack_buffer, sizeof(stack_buffer), format, copy);
            va_end(copy);
            if (length < 0) {
                return length;
            }
            if ((size_t)length < sizeof(stack_buffer)) {
                return write(fileno(stream), stack_buffer, (size_t)length) < 0 ? -1 : length;
            }
            size_t capacity = (size_t)length + 1;
            char *buffer = (char *)malloc(capacity);
            if (buffer == NULL) {
                errno = ENOMEM;
                return -1;
            }
            vsnprintf(buffer, capacity, format, args);
            ssize_t written = write(fileno(stream), buffer, (size_t)length);
            free(buffer);
            return written < 0 ? -1 : length;
        }
        vfprintf_fn_t fn = host_vfprintf_fn();
        if (fn != NULL) {
            return fn(stream, format, args);
        }
        errno = ENOSYS;
        return -1;
    }

    char stack_buffer[1024];
    va_list copy;
    va_copy(copy, args);
    int length = vsnprintf(stack_buffer, sizeof(stack_buffer), format, copy);
    va_end(copy);
    if (length < 0) {
        return length;
    }

    if ((size_t)length < sizeof(stack_buffer)) {
        if (kind == SHIM_FD_STDERR) {
            micro_os_stderr(stack_buffer);
        } else {
            micro_os_stdout(stack_buffer);
        }
        return length;
    }

    size_t capacity = (size_t)length + 1;
    char *buffer = (char *)malloc(capacity);
    if (buffer == NULL) {
        errno = ENOMEM;
        return -1;
    }
    vsnprintf(buffer, capacity, format, args);
    if (kind == SHIM_FD_STDERR) {
        micro_os_stderr(buffer);
    } else {
        micro_os_stdout(buffer);
    }
    free(buffer);
    return length;
}

static read_fn_t host_read_fn(void) {
    static read_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (read_fn_t)dlsym(RTLD_NEXT, "read");
    }
    return fn;
}

static write_fn_t host_write_fn(void) {
    static write_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (write_fn_t)dlsym(RTLD_NEXT, "write");
    }
    return fn;
}

static close_fn_t host_close_fn(void) {
    static close_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (close_fn_t)dlsym(RTLD_NEXT, "close");
    }
    return fn;
}

static dup_fn_t host_dup_fn(void) {
    static dup_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (dup_fn_t)dlsym(RTLD_NEXT, "dup");
    }
    return fn;
}

static dup2_fn_t host_dup2_fn(void) {
    static dup2_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (dup2_fn_t)dlsym(RTLD_NEXT, "dup2");
    }
    return fn;
}

static fcntl_fn_t host_fcntl_fn(void) {
    static fcntl_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (fcntl_fn_t)dlsym(RTLD_NEXT, "fcntl");
    }
    return fn;
}

static open_fn_t host_open_fn(void) {
    static open_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (open_fn_t)dlsym(RTLD_NEXT, "open");
    }
    return fn;
}

static openat_fn_t host_openat_fn(void) {
    static openat_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (openat_fn_t)dlsym(RTLD_NEXT, "openat");
    }
    return fn;
}

static setsockopt_fn_t host_setsockopt_fn(void) {
    static setsockopt_fn_t fn = NULL;
    if (fn == NULL) {
        fn = (setsockopt_fn_t)dlsym(RTLD_NEXT, "setsockopt");
    }
    return fn;
}

static int shim_open_host_path(const char *path, int flags, mode_t mode, int has_mode) {
    open_fn_t fn = host_open_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (has_mode) {
        return fn(path, flags, mode);
    }
    return fn(path, flags);
}

static int shim_open_memory(const char *text) {
    const char *source = text != NULL ? text : "";
    size_t length = strlen(source);
    return shim_open_host_virtual(SHIM_FD_MEM, source, length);
}

static int shim_open_dev_path(const char *path, int flags, mode_t mode, int has_mode) {
    if (path == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (strcmp(path, "/dev/stdin") == 0) {
        return dup(STDIN_FILENO);
    }
    if (strcmp(path, "/dev/stdout") == 0) {
        return dup(STDOUT_FILENO);
    }
    if (strcmp(path, "/dev/stderr") == 0) {
        return dup(STDERR_FILENO);
    }
    if (strcmp(path, "/dev/tty") == 0) {
        int readable = (flags & O_ACCMODE) != O_WRONLY;
        int writable = (flags & O_ACCMODE) != O_RDONLY;
        if (readable && writable) {
            return dup(STDIN_FILENO);
        }
        return dup(writable ? STDOUT_FILENO : STDIN_FILENO);
    }
    if (strcmp(path, "/dev/null") == 0) {
        (void)mode;
        (void)has_mode;
        return shim_open_host_virtual(SHIM_FD_NULL, NULL, 0);
    }
    if (strcmp(path, "/dev/zero") == 0) {
        return shim_open_host_virtual(SHIM_FD_ZERO, NULL, 0);
    }
    if (strcmp(path, "/dev/random") == 0 || strcmp(path, "/dev/urandom") == 0) {
        return shim_open_host_virtual(SHIM_FD_RANDOM, NULL, 0);
    }
    return shim_open_host_path(path, flags, mode, has_mode);
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    int has_mode = (flags & O_CREAT) != 0;
    if (has_mode) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    return shim_open_dev_path(path, flags, mode, has_mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    int has_mode = (flags & O_CREAT) != 0;
    if (has_mode) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (path == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (path[0] == '/') {
        return shim_open_dev_path(path, flags, mode, has_mode);
    }
    openat_fn_t fn = host_openat_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (has_mode) {
        return fn(dirfd, path, flags, mode);
    }
    return fn(dirfd, path, flags);
}

int setsockopt(int socket, int level, int option_name, const void *option_value, socklen_t option_len) {
    setsockopt_fn_t fn = host_setsockopt_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }

#ifdef IP_RECVTTL
    if ((level == IPPROTO_IP || level == SOL_IP) && option_name == IP_RECVTTL) {
        int result = fn(socket, level, option_name, option_value, option_len);
        if (result == 0 || errno == EINVAL || errno == ENOPROTOOPT) {
            return 0;
        }
        return result;
    }
#endif

    return fn(socket, level, option_name, option_value, option_len);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg) {
    pthread_create_fn_t fn = host_pthread_create_fn();
    if (fn == NULL) {
        return ENOSYS;
    }
    if (start == NULL) {
        return EINVAL;
    }

    struct shim_thread_start *wrapped = (struct shim_thread_start *)malloc(sizeof(*wrapped));
    if (wrapped == NULL) {
        return ENOMEM;
    }
    wrapped->start = start;
    wrapped->arg = arg;
    wrapped->pid = micro_os_pid();

    int result = fn(thread, attr, shim_thread_entry, wrapped);
    if (result != 0) {
        free(wrapped);
    }
    return result;
}

static int shim_snapshot(micro_os_process_info_t **out, int32_t *count) {
    int32_t needed = micro_os_process_snapshot(NULL, 0);
    if (needed <= 0) {
        *out = NULL;
        *count = 0;
        return 0;
    }
    micro_os_process_info_t *items = (micro_os_process_info_t *)calloc((size_t)needed, sizeof(*items));
    if (items == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int32_t actual = micro_os_process_snapshot(items, needed);
    if (actual < 0) {
        free(items);
        errno = EIO;
        return -1;
    }
    if (actual > needed) {
        actual = needed;
    }
    *out = items;
    *count = actual;
    return 0;
}

static const micro_os_process_info_t *shim_find_process_info(pid_t pid, micro_os_process_info_t *items, int32_t count) {
    for (int32_t i = 0; i < count; i++) {
        if (items[i].pid == (int32_t)pid) {
            return &items[i];
        }
    }
    return NULL;
}

static int shim_copy_sysctl_value(const void *source, size_t source_size, void *oldp, size_t *oldlenp) {
    if (oldlenp == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (oldp == NULL) {
        *oldlenp = source_size;
        return 0;
    }
    if (*oldlenp < source_size) {
        *oldlenp = source_size;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, source, source_size);
    *oldlenp = source_size;
    return 0;
}

static int shim_process_matches_sysctl(const micro_os_process_info_t *info, int selector, int value) {
    selector &= ~KERN_PROC_INC_THREAD;
    switch (selector) {
    case KERN_PROC_ALL:
        return 1;
    case KERN_PROC_PID:
        return info->pid == value;
    case KERN_PROC_PGRP:
    case KERN_PROC_SESSION:
        return info->parent_pid == value || info->pid == value;
    case KERN_PROC_TTY:
        return info->tty_id == value;
    case KERN_PROC_UID:
    case KERN_PROC_RUID:
        return getuid() == (uid_t)value;
#ifdef KERN_PROC_RGID
    case KERN_PROC_RGID:
        return getgid() == (gid_t)value;
#endif
    default:
        return 1;
    }
}

static void shim_fill_kinfo_proc(struct kinfo_proc *kp, const micro_os_process_info_t *info) {
    memset(kp, 0, sizeof(*kp));
    kp->kp_proc.p_pid = (pid_t)info->pid;
    kp->kp_proc.p_stat = (char)(info->state != 0 ? info->state : SRUN);
    kp->kp_proc.p_flag = P_CONTROLT | P_LP64;
    kp->kp_proc.p_priority = 31;
    kp->kp_proc.p_usrpri = 31;
    kp->kp_proc.p_starttime.tv_sec = (time_t)(info->start_time_ms / 1000);
    kp->kp_proc.p_starttime.tv_usec = (suseconds_t)((info->start_time_ms % 1000) * 1000);
    snprintf(kp->kp_proc.p_comm, sizeof(kp->kp_proc.p_comm), "%s", info->command[0] ? info->command : "process");

    kp->kp_eproc.e_ppid = (pid_t)info->parent_pid;
    kp->kp_eproc.e_pgid = (pid_t)info->pgid;
    kp->kp_eproc.e_tdev = (dev_t)info->tty_id;
    kp->kp_eproc.e_tpgid = (pid_t)info->pgid;
    kp->kp_eproc.e_pcred.p_ruid = getuid();
    kp->kp_eproc.e_pcred.p_svuid = getuid();
    kp->kp_eproc.e_pcred.p_rgid = getgid();
    kp->kp_eproc.e_pcred.p_svgid = getgid();
    kp->kp_eproc.e_ucred.cr_uid = getuid();
    kp->kp_eproc.e_ucred.cr_ngroups = 1;
    kp->kp_eproc.e_ucred.cr_groups[0] = getgid();
    kp->kp_eproc.e_flag = EPROC_CTTY;
}

static int shim_sysctl_kern_proc(int *name, u_int namelen, void *oldp, size_t *oldlenp) {
    if (namelen < 3 || oldlenp == NULL) {
        errno = EINVAL;
        return -1;
    }

    int selector = name[2];
    int value = namelen >= 4 ? name[3] : 0;
    micro_os_process_info_t *items = NULL;
    int32_t count = 0;
    if (shim_snapshot(&items, &count) != 0) {
        return -1;
    }

    size_t matches = 0;
    for (int32_t i = 0; i < count; i++) {
        if (shim_process_matches_sysctl(&items[i], selector, value)) {
            matches++;
        }
    }

    size_t required = matches * sizeof(struct kinfo_proc);
    if (oldp == NULL) {
        *oldlenp = required;
        free(items);
        return 0;
    }
    if (*oldlenp < required) {
        *oldlenp = required;
        free(items);
        errno = ENOMEM;
        return -1;
    }

    struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
    size_t out = 0;
    for (int32_t i = 0; i < count; i++) {
        if (shim_process_matches_sysctl(&items[i], selector, value)) {
            shim_fill_kinfo_proc(&kp[out++], &items[i]);
        }
    }
    *oldlenp = required;
    free(items);
    return 0;
}

static int shim_count_argv(const char *argv, size_t capacity) {
    int argc = 0;
    size_t offset = 0;
    while (offset < capacity && argv[offset] != '\0') {
        argc++;
        offset += strnlen(argv + offset, capacity - offset) + 1;
    }
    return argc;
}

static int shim_sysctl_procargs2(pid_t pid, void *oldp, size_t *oldlenp) {
    micro_os_process_info_t *items = NULL;
    int32_t count = 0;
    if (shim_snapshot(&items, &count) != 0) {
        return -1;
    }
    const micro_os_process_info_t *info = shim_find_process_info(pid, items, count);
    if (info == NULL) {
        free(items);
        errno = ESRCH;
        return -1;
    }

    int argc = shim_count_argv(info->argv, sizeof(info->argv));
    const char *exec_path = info->command[0] ? info->command : "process";
    size_t exec_len = strlen(exec_path) + 1;
    size_t argv_len = strnlen(info->argv, sizeof(info->argv));
    if (argv_len < sizeof(info->argv)) {
        size_t offset = 0;
        while (offset < sizeof(info->argv) && info->argv[offset] != '\0') {
            offset += strnlen(info->argv + offset, sizeof(info->argv) - offset) + 1;
        }
        argv_len = offset + 1;
    } else {
        argv_len = sizeof(info->argv);
    }

    size_t required = sizeof(int) + exec_len + 1 + argv_len;
    char *buffer = (char *)calloc(1, required);
    if (buffer == NULL) {
        free(items);
        errno = ENOMEM;
        return -1;
    }
    memcpy(buffer, &argc, sizeof(argc));
    size_t offset = sizeof(argc);
    memcpy(buffer + offset, exec_path, exec_len);
    offset += exec_len + 1;
    memcpy(buffer + offset, info->argv, argv_len);

    int result = shim_copy_sysctl_value(buffer, required, oldp, oldlenp);
    free(buffer);
    free(items);
    return result;
}

int sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (newp != NULL || newlen != 0) {
        errno = EPERM;
        return -1;
    }
    if (name == NULL || namelen < 2) {
        errno = EINVAL;
        return -1;
    }
    if (name[0] == CTL_KERN && name[1] == KERN_PROC) {
        return shim_sysctl_kern_proc(name, namelen, oldp, oldlenp);
    }
    if (name[0] == CTL_KERN && name[1] == KERN_PROCARGS2 && namelen >= 3) {
        return shim_sysctl_procargs2((pid_t)name[2], oldp, oldlenp);
    }
    if (name[0] == CTL_KERN && name[1] == KERN_ARGMAX) {
        int argmax = 4096;
        return shim_copy_sysctl_value(&argmax, sizeof(argmax), oldp, oldlenp);
    }

    sysctl_fn_t fn = host_sysctl_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return fn(name, namelen, oldp, oldlenp, newp, newlen);
}

int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (strcmp(name, "kern.argmax") == 0) {
        int argmax = 4096;
        return shim_copy_sysctl_value(&argmax, sizeof(argmax), oldp, oldlenp);
    }
    if (strcmp(name, "kern.fscale") == 0) {
        int fscale = 100;
        return shim_copy_sysctl_value(&fscale, sizeof(fscale), oldp, oldlenp);
    }
    if (strcmp(name, "kern.ccpu") == 0) {
        fixpt_t ccpu = 0;
        return shim_copy_sysctl_value(&ccpu, sizeof(ccpu), oldp, oldlenp);
    }
    sysctlbyname_fn_t fn = host_sysctlbyname_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return fn(name, oldp, oldlenp, newp, newlen);
}

int kill(pid_t pid, int sig) {
    if (pid == getpid() && sig > 0 && sig < (int)(sizeof(shim_pending_signals) * 8)) {
        pthread_mutex_lock(&shim_signal_lock);
        shim_pending_signals |= (1u << (unsigned int)sig);
        pthread_cond_broadcast(&shim_signal_cond);
        pthread_mutex_unlock(&shim_signal_lock);
        return 0;
    }
    if (pid > 0) {
        if (micro_os_process_signal((int32_t)pid, (int32_t)sig) == 0) {
            return 0;
        }
        errno = ESRCH;
        return -1;
    }

    kill_fn_t fn = host_kill_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return fn(pid, sig);
}

pid_t setpgid(pid_t pid, pid_t pgid) {
    return (pid_t)micro_os_setpgid((int32_t)pid, (int32_t)pgid);
}

pid_t getpgid(pid_t pid) {
    return (pid_t)micro_os_getpgid((int32_t)pid);
}

pid_t getpgrp(void) {
    return getpgid(0);
}

int tcsetpgrp(int fd, pid_t pgid) {
    return (int)micro_os_tcsetpgrp((int32_t)fd, (int32_t)pgid);
}

pid_t tcgetpgrp(int fd) {
    return (pid_t)micro_os_tcgetpgrp((int32_t)fd);
}

pid_t setsid(void) {
    int32_t pid = micro_os_pid();
    micro_os_setpgid(pid, pid);
    return (pid_t)pid;
}

sig_t signal(int sig, sig_t handler) {
    micro_os_signal_set_ignored(0, (int32_t)sig, handler == SIG_IGN ? 1 : 0);
    return SIG_DFL;
}

int sigaction(int sig, const struct sigaction *restrict act, struct sigaction *restrict oact) {
    if (oact) {
        oact->sa_handler = SIG_DFL;
        oact->sa_flags = 0;
        sigemptyset(&oact->sa_mask);
    }
    if (act) {
        int ignored = (act->sa_handler == SIG_IGN) ? 1 : 0;
        micro_os_signal_set_ignored(0, (int32_t)sig, ignored);
    }
    return 0;
}

int sigwait(const sigset_t *set, int *sig) {
    if (set == NULL || sig == NULL) {
        return EINVAL;
    }

    pthread_mutex_lock(&shim_signal_lock);
    for (;;) {
        for (int candidate = 1; candidate < (int)(sizeof(shim_pending_signals) * 8); candidate++) {
            if ((shim_pending_signals & (1u << (unsigned int)candidate)) != 0 &&
                sigismember(set, candidate) == 1)
            {
                shim_pending_signals &= ~(1u << (unsigned int)candidate);
                *sig = candidate;
                pthread_mutex_unlock(&shim_signal_lock);
                return 0;
            }
        }
        pthread_cond_wait(&shim_signal_cond, &shim_signal_lock);
    }
}

ssize_t write(int fd, const void *buffer, size_t count) {
    int kind = shim_tty_fd_kind(fd);
    if (kind == SHIM_FD_NULL || kind == SHIM_FD_ZERO || kind == SHIM_FD_RANDOM || kind == SHIM_FD_PIPE_WRITE || kind == SHIM_FD_MEM || kind == SHIM_FD_PIPE_READ) {
        int32_t result = micro_os_fd_write((int32_t)fd, buffer, (int32_t)count);
        if (result < 0) {
            errno = EIO;
            return -1;
        }
        return (ssize_t)result;
    }
    if (kind != SHIM_FD_STDOUT && kind != SHIM_FD_STDERR) {
        write_fn_t fn = host_write_fn();
        if (fn != NULL) {
            return fn(fd, buffer, count);
        }
        errno = ENOSYS;
        return -1;
    }
    if (buffer == NULL) {
        errno = EFAULT;
        return -1;
    }

    char *text = (char *)malloc(count + 1);
    if (text == NULL) {
        errno = ENOMEM;
        return -1;
    }
    memcpy(text, buffer, count);
    text[count] = '\0';
    if (kind == SHIM_FD_STDERR) {
        micro_os_stderr(text);
    } else {
        micro_os_stdout(text);
    }
    free(text);
    return (ssize_t)count;
}

int printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = shim_vwrite(stdout, format, args);
    va_end(args);
    return result;
}

int fprintf(FILE *stream, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = shim_vwrite(stream, format, args);
    va_end(args);
    return result;
}

int vprintf(const char *format, va_list args) {
    return shim_vwrite(stdout, format, args);
}

int vfprintf(FILE *stream, const char *format, va_list args) {
    int kind = shim_stream_kind(stream);
    if (kind == SHIM_FD_STDOUT || kind == SHIM_FD_STDERR || shim_kind_is_virtual_io(kind)) {
        return shim_vwrite(stream, format, args);
    }
    vfprintf_fn_t next = host_vfprintf_fn();
    if (next == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return next(stream, format, args);
}

int puts(const char *text) {
    if (shim_tty_fd_kind(STDOUT_FILENO) != SHIM_FD_STDOUT) {
        if (shim_kind_is_virtual_io(shim_tty_fd_kind(STDOUT_FILENO))) {
            const char *value = text != NULL ? text : "(null)";
            if (write(STDOUT_FILENO, value, strlen(value)) < 0 || write(STDOUT_FILENO, "\n", 1) < 0) {
                return EOF;
            }
            return 0;
        }
        fputs_fn_t fn = host_fputs_fn();
        if (fn != NULL) {
            int result = fn(text != NULL ? text : "(null)", stdout);
            if (result < 0) {
                return result;
            }
            return fn("\n", stdout);
        }
        errno = ENOSYS;
        return EOF;
    }
    micro_os_stdout(text != NULL ? text : "(null)");
    micro_os_stdout("\n");
    return 0;
}

int fputs(const char *text, FILE *stream) {
    int kind = shim_stream_kind(stream);
    if (kind == SHIM_FD_STDERR) {
        micro_os_stderr(text != NULL ? text : "(null)");
    } else if (kind == SHIM_FD_STDOUT) {
        micro_os_stdout(text != NULL ? text : "(null)");
    } else if (shim_kind_is_virtual_io(kind)) {
        const char *value = text != NULL ? text : "(null)";
        return write(fileno(stream), value, strlen(value)) < 0 ? EOF : 0;
    } else {
        fputs_fn_t next = host_fputs_fn();
        if (next == NULL) {
            errno = ENOSYS;
            return EOF;
        }
        return next(text, stream);
    }
    return 0;
}

int fputc(int ch, FILE *stream) {
    unsigned char byte = (unsigned char)ch;
    int kind = shim_stream_kind(stream);
    if (kind == SHIM_FD_STDOUT || kind == SHIM_FD_STDERR || shim_kind_is_virtual_io(kind)) {
        return write(fileno(stream), &byte, 1) == 1 ? byte : EOF;
    }
    fputc_fn_t next = host_fputc_fn();
    if (next == NULL) {
        errno = ENOSYS;
        return EOF;
    }
    return next(ch, stream);
}

int putc(int ch, FILE *stream) {
    return fputc(ch, stream);
}

int putchar(int ch) {
    return fputc(ch, stdout);
}

size_t fwrite(const void *ptr, size_t size, size_t count, FILE *stream) {
    int kind = shim_stream_kind(stream);
    if (kind != SHIM_FD_STDOUT && kind != SHIM_FD_STDERR) {
        if (shim_kind_is_virtual_io(kind)) {
            size_t bytes = size * count;
            if (bytes == 0) {
                return 0;
            }
            ssize_t written = write(fileno(stream), ptr, bytes);
            if (written < 0) {
                return 0;
            }
            return size == 0 ? 0 : (size_t)written / size;
        }
        fwrite_fn_t next = host_fwrite_fn();
        if (next == NULL) {
            errno = ENOSYS;
            return 0;
        }
        return next(ptr, size, count, stream);
    }

    size_t bytes = size * count;
    if (ptr == NULL || bytes == 0) {
        return 0;
    }

    char *text = (char *)malloc(bytes + 1);
    if (text == NULL) {
        errno = ENOMEM;
        return 0;
    }
    memcpy(text, ptr, bytes);
    text[bytes] = '\0';
    if (kind == SHIM_FD_STDERR) {
        micro_os_stderr(text);
    } else {
        micro_os_stdout(text);
    }
    free(text);
    return count;
}

// Route command-availability checks through the host: a bundled program is a
// non-executable ".dylib", so a shell's access(X_OK) would otherwise refuse to
// run it. The host reports such paths (and not-yet-existing applet names)
// executable; other checks fall through to the real access().
int access(const char *path, int mode) {
    return micro_os_access(path, mode);
}

ssize_t read(int fd, void *buffer, size_t count) {
    int kind = shim_tty_fd_kind(fd);
    if (buffer == NULL && count > 0) {
        errno = EFAULT;
        return -1;
    }
    if (kind == SHIM_FD_NULL || kind == SHIM_FD_ZERO || kind == SHIM_FD_RANDOM || kind == SHIM_FD_MEM || kind == SHIM_FD_PIPE_READ || kind == SHIM_FD_PIPE_WRITE) {
        int32_t result = micro_os_fd_read((int32_t)fd, buffer, (int32_t)count);
        if (result < 0) {
            errno = EIO;
            return -1;
        }
        return (ssize_t)result;
    }
    if (kind != SHIM_FD_STDIN) {
        read_fn_t fn = host_read_fn();
        if (fn != NULL) {
            return fn(fd, buffer, count);
        }
        errno = ENOSYS;
        return -1;
    }
    uint32_t lflag = micro_os_tty_get_lflag();
    size_t max_count = count;
    if ((lflag & ICANON) == 0 && max_count > 1) {
        max_count = 1;
    }
    return (ssize_t)micro_os_stdin((char *)buffer, (int32_t)max_count);
}

pid_t getpid(void) {
    return (pid_t)micro_os_pid();
}

pid_t getppid(void) {
    micro_os_process_info_t *items = NULL;
    int32_t count = 0;
    if (shim_snapshot(&items, &count) != 0) {
        return 0;
    }
    pid_t pid = getpid();
    pid_t parent = 0;
    const micro_os_process_info_t *info = shim_find_process_info(pid, items, count);
    if (info != NULL) {
        parent = (pid_t)info->parent_pid;
    }
    free(items);
    return parent;
}

const char *getprogname(void) {
    if (shim_program_name[0] != '\0') {
        return shim_program_name;
    }

    micro_os_process_info_t *items = NULL;
    int32_t count = 0;
    if (shim_snapshot(&items, &count) != 0) {
        return "micro-os";
    }
    const micro_os_process_info_t *info = shim_find_process_info(getpid(), items, count);
    if (info != NULL && info->command[0] != '\0') {
        snprintf(shim_program_name, sizeof(shim_program_name), "%s", info->command);
    }
    free(items);
    return shim_program_name[0] != '\0' ? shim_program_name : "micro-os";
}

void setprogname(const char *name) {
    if (name == NULL || name[0] == '\0') {
        shim_program_name[0] = '\0';
        return;
    }
    const char *base = strrchr(name, '/');
    snprintf(shim_program_name, sizeof(shim_program_name), "%s", base != NULL ? base + 1 : name);
}

char *devname(dev_t dev, mode_t type) {
    (void)type;
    static _Thread_local char name[32];
    snprintf(name, sizeof(name), "tty%d", (int)dev);
    return name;
}

int isatty(int fd) {
    if (shim_is_tty_fd(fd)) {
        return 1;
    }
    typedef int (*isatty_fn)(int);
    isatty_fn next = (isatty_fn)dlsym(RTLD_NEXT, "isatty");
    if (next != NULL) {
        return next(fd);
    }
    errno = EBADF;
    return 0;
}

int close(int fd) {
    if (shim_fd_is_virtual(fd)) {
        micro_os_fd_close((int32_t)fd);
        shim_free_fd_state(fd);
        return 0;
    }
    close_fn_t fn = host_close_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return fn(fd);
}

int dup(int fd) {
    if (shim_fd_is_virtual(fd)) {
        int result = micro_os_fd_dup((int32_t)fd);
        if (result >= 0 && result < SHIM_MAX_FDS) {
            shim_free_fd_state(result);
            shim_fds[result].kind = (unsigned char)shim_tty_fd_kind(result);
            shim_fds[result].pipe_index = -1;
        }
        return result;
    }
    dup_fn_t fn = host_dup_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int result = fn(fd);
    if (result >= 0 && shim_is_tty_fd(fd)) {
        shim_mark_tty_fd(result, shim_tty_fd_kind(fd));
    }
    return result;
}

int dup2(int fd, int fd2) {
    if (fd2 < 0 || fd2 >= SHIM_MAX_FDS) {
        errno = EBADF;
        return -1;
    }
    if (shim_fd_is_virtual(fd)) {
        if (fd == fd2) {
            return fd2;
        }
        int result = micro_os_fd_dup2((int32_t)fd, (int32_t)fd2);
        if (result >= 0) {
            shim_free_fd_state(fd2);
            shim_fds[fd2].kind = (unsigned char)shim_tty_fd_kind(fd);
            shim_fds[fd2].pipe_index = -1;
        }
        return result;
    }
    dup2_fn_t fn = host_dup2_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int result = fn(fd, fd2);
    if (result >= 0) {
        micro_os_fd_close((int32_t)fd2);
        shim_mark_tty_fd(fd2, shim_tty_fd_kind(fd));
    }
    return result;
}

int fcntl(int fd, int command, ...) {
    if (shim_fd_is_virtual(fd)) {
        switch (command) {
        case F_GETFD:
            return 0;
        case F_SETFD:
            return 0;
        case F_GETFL:
            return O_RDWR;
        case F_SETFL:
            return 0;
        case F_DUPFD:
#ifdef F_DUPFD_CLOEXEC
        case F_DUPFD_CLOEXEC:
#endif
            return dup(fd);
        default:
            errno = EINVAL;
            return -1;
        }
    }
    fcntl_fn_t fn = host_fcntl_fn();
    if (fn == NULL) {
        errno = ENOSYS;
        return -1;
    }

    int result = -1;
    switch (command) {
    case F_GETFD:
    case F_GETFL:
        result = fn(fd, command);
        break;
    default: {
        va_list args;
        va_start(args, command);
        long argument = va_arg(args, long);
        va_end(args);
        result = fn(fd, command, argument);
        break;
    }
    }

    if (result >= 0 && (command == F_DUPFD || command == F_DUPFD_CLOEXEC) && shim_is_tty_fd(fd)) {
        shim_mark_tty_fd(result, shim_tty_fd_kind(fd));
    }
    return result;
}

int pipe(int fildes[2]) {
    if (fildes == NULL) {
        errno = EFAULT;
        return -1;
    }
    int result = micro_os_fd_pipe((int32_t *)fildes);
    if (result == 0) {
        if (fildes[0] >= 0 && fildes[0] < SHIM_MAX_FDS) {
            shim_free_fd_state(fildes[0]);
            shim_fds[fildes[0]].kind = SHIM_FD_PIPE_READ;
        }
        if (fildes[1] >= 0 && fildes[1] < SHIM_MAX_FDS) {
            shim_free_fd_state(fildes[1]);
            shim_fds[fildes[1]].kind = SHIM_FD_PIPE_WRITE;
        }
    }
    return result;
}

off_t lseek(int fd, off_t offset, int whence) {
    int kind = shim_tty_fd_kind(fd);
    if (kind == SHIM_FD_MEM) {
        int64_t result = micro_os_fd_lseek((int32_t)fd, (int64_t)offset, (int32_t)whence);
        if (result < 0) {
            errno = EINVAL;
            return -1;
        }
        return (off_t)result;
    }
    if (shim_fd_is_virtual(fd)) {
        errno = ESPIPE;
        return -1;
    }
    typedef off_t (*lseek_fn_t)(int, off_t, int);
    static lseek_fn_t next = NULL;
    if (next == NULL) {
        next = (lseek_fn_t)dlsym(RTLD_NEXT, "lseek");
    }
    if (next == NULL) {
        errno = ENOSYS;
        return -1;
    }
    return next(fd, offset, whence);
}

int tcgetattr(int fd, struct termios *termios_p) {
    if (!shim_is_tty_fd(fd)) {
        typedef int (*tcgetattr_fn_t)(int, struct termios *);
        static tcgetattr_fn_t next = NULL;
        if (next == NULL) {
            next = (tcgetattr_fn_t)dlsym(RTLD_NEXT, "tcgetattr");
        }
        if (next != NULL) {
            return next(fd, termios_p);
        }
    }
    if (termios_p == NULL) {
        errno = EFAULT;
        return -1;
    }
    memset(termios_p, 0, sizeof(*termios_p));
    termios_p->c_iflag = ICRNL;
    termios_p->c_oflag = OPOST | ONLCR;
    termios_p->c_cflag = CREAD | CS8;
    termios_p->c_lflag = (tcflag_t)micro_os_tty_get_lflag();
    termios_p->c_cc[VMIN] = 1;
    termios_p->c_cc[VTIME] = 0;
    return 0;
}

int tcsetattr(int fd, int optional_actions, const struct termios *termios_p) {
    (void)optional_actions;
    if (shim_is_tty_fd(fd)) {
        if (termios_p != NULL) {
            micro_os_tty_set_lflag((uint32_t)termios_p->c_lflag);
        }
        return 0;
    }
    typedef int (*tcsetattr_fn_t)(int, int, const struct termios *);
    static tcsetattr_fn_t next = NULL;
    if (next == NULL) {
        next = (tcsetattr_fn_t)dlsym(RTLD_NEXT, "tcsetattr");
    }
    if (next != NULL) {
        return next(fd, optional_actions, termios_p);
    }
    errno = ENOTTY;
    return -1;
}

static _Thread_local jmp_buf fork_jmp_buf;
static _Thread_local int32_t fork_child_pid = -1;
static _Thread_local int fork_in_child = 0;

pid_t fork(void) {
    int32_t child_pid = micro_os_fork();
    if (child_pid <= 0) {
        errno = ENOSYS;
        return -1;
    }

    fork_child_pid = child_pid;

    if (setjmp(fork_jmp_buf) == 0) {
        fork_in_child = 1;
        micro_os_fork_child_begin(child_pid);
        return 0;
    } else {
        fork_in_child = 0;
        fork_child_pid = -1;
        return child_pid;
    }
}

pid_t vfork(void) {
    return fork();
}

static const char *shim_dylib_from_link(const char *path) {
    static _Thread_local char dylib_name[1024];
    char resolved[1024];

    if (path == NULL || strstr(path, "/.local/bin/") == NULL) {
        return NULL;
    }

    if (realpath(path, resolved) == NULL || strcmp(path, resolved) == 0) {
        return NULL;
    }

    const char *extension = strrchr(resolved, '.');
    if (extension == NULL || strcmp(extension, ".dylib") != 0) {
        return NULL;
    }

    snprintf(dylib_name, sizeof(dylib_name), "%s", resolved);
    return dylib_name;
}

static const char *shim_dylib_from_path_search(const char *file) {
    if (file == NULL || file[0] == '\0' || strchr(file, '/') != NULL) {
        return NULL;
    }

    const char *path = getenv("PATH");
    if (path == NULL || path[0] == '\0') {
        return NULL;
    }

    const char *cursor = path;
    while (1) {
        const char *separator = strchr(cursor, ':');
        size_t directory_length = separator != NULL ? (size_t)(separator - cursor) : strlen(cursor);
        const char *directory = directory_length == 0 ? "." : cursor;
        if (directory_length == 0) {
            directory_length = 1;
        }

        size_t file_length = strlen(file);
        size_t candidate_length = directory_length + 1 + file_length + 1;
        char *candidate = (char *)malloc(candidate_length);
        if (candidate == NULL) {
            return NULL;
        }

        snprintf(candidate, candidate_length, "%.*s/%s", (int)directory_length, directory, file);
        const char *dylib = shim_dylib_from_link(candidate);
        free(candidate);
        if (dylib != NULL) {
            return dylib;
        }

        if (separator == NULL) {
            break;
        }
        cursor = separator + 1;
    }

    return NULL;
}

static const char *shim_exec_dylib_for_path(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NULL;
    }

    const char *linked_dylib = shim_dylib_from_link(path);
    if (linked_dylib != NULL) {
        return linked_dylib;
    }

    if (strstr(path, ".dylib") != NULL) {
        return path;
    }

    const char *path_dylib = shim_dylib_from_path_search(path);
    if (path_dylib != NULL) {
        return path_dylib;
    }

    return NULL;
}

int execv(const char *path, char *const argv[]) {
    int argc = 0;
    if (argv != NULL) {
        while (argv[argc] != NULL) {
            argc++;
        }
    }

    const char *dylib = shim_exec_dylib_for_path(path);
    if (dylib == NULL) {
        errno = ENOENT;
        return -1;
    }

    if (fork_in_child && fork_child_pid > 0) {
        int32_t cpid = fork_child_pid;
        micro_os_fork_child_end();
        micro_os_exec_forked_child(cpid, dylib, (int32_t)argc, (char **)argv);
        fork_in_child = 0;
        longjmp(fork_jmp_buf, 1);
        __builtin_unreachable();
    }

    int32_t pid = micro_os_spawn(dylib, (int32_t)argc, (char **)argv);
    if (pid < 0) {
        errno = ENOENT;
        return -1;
    }

    micro_os_process_exit(0);
    __builtin_unreachable();
}

int execve(const char *path, char *const argv[], char *const envp[]) {
    (void)envp;
    return execv(path, argv);
}

int execvp(const char *file, char *const argv[]) {
    if (file == NULL || file[0] == '\0') {
        errno = ENOENT;
        return -1;
    }

    if (strchr(file, '/') != NULL) {
        return execv(file, argv);
    }

    const char *path = getenv("PATH");
    if (path == NULL || path[0] == '\0') {
        path = "/bin:/usr/bin";
    }

    const char *cursor = path;
    while (1) {
        const char *separator = strchr(cursor, ':');
        size_t directory_length = separator != NULL ? (size_t)(separator - cursor) : strlen(cursor);
        const char *directory = directory_length == 0 ? "." : cursor;
        if (directory_length == 0) {
            directory_length = 1;
        }

        size_t file_length = strlen(file);
        size_t candidate_length = directory_length + 1 + file_length + 1;
        char *candidate = (char *)malloc(candidate_length);
        if (candidate == NULL) {
            errno = ENOMEM;
            return -1;
        }

        snprintf(candidate, candidate_length, "%.*s/%s", (int)directory_length, directory, file);
        if (shim_dylib_from_link(candidate) != NULL) {
            execv(candidate, argv);
            free(candidate);
            return -1;
        }

        if (access(candidate, X_OK) == 0) {
            execv(candidate, argv);
            free(candidate);
            return -1;
        }

        free(candidate);
        if (separator == NULL) {
            break;
        }
        cursor = separator + 1;
    }

    errno = ENOENT;
    return -1;
}

pid_t waitpid(pid_t pid, int *status, int options) {
    int32_t raw_status = 0;
    int32_t result = micro_os_waitpid((int32_t)pid, &raw_status, (int32_t)options);
    if (result < 0) {
        errno = ECHILD;
        return -1;
    }
    if (status != NULL) {
        *status = (int)raw_status;
    }
    return (pid_t)result;
}

pid_t wait(int *status) {
    return waitpid(-1, status, 0);
}

void exit(int status) {
    if (fork_in_child && fork_child_pid > 0) {
        int32_t cpid = fork_child_pid;
        micro_os_fork_child_end();
        micro_os_exit_forked_child(cpid, (int32_t)status);
        fork_in_child = 0;
        longjmp(fork_jmp_buf, 1);
        __builtin_unreachable();
    }
    fflush(NULL);
    micro_os_process_exit((int32_t)status);
}

void _exit(int status) {
    if (fork_in_child && fork_child_pid > 0) {
        int32_t cpid = fork_child_pid;
        micro_os_fork_child_end();
        micro_os_exit_forked_child(cpid, (int32_t)status);
        fork_in_child = 0;
        longjmp(fork_jmp_buf, 1);
        __builtin_unreachable();
    }
    micro_os_process_exit((int32_t)status);
}

void _Exit(int status) {
    _exit(status);
}
