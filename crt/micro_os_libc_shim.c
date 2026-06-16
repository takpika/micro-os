#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <termios.h>
#include <sys/types.h>
#include <unistd.h>

#include "micro_os.h"

typedef ssize_t (*read_fn_t)(int, void *, size_t);
typedef ssize_t (*write_fn_t)(int, const void *, size_t);
typedef int (*close_fn_t)(int);
typedef int (*dup_fn_t)(int);
typedef int (*dup2_fn_t)(int, int);
typedef int (*fcntl_fn_t)(int, int, ...);
typedef int (*open_fn_t)(const char *, int, ...);
typedef int (*openat_fn_t)(int, const char *, int, ...);
typedef int (*vfprintf_fn_t)(FILE *, const char *, va_list);
typedef int (*fputs_fn_t)(const char *, FILE *);
typedef size_t (*fwrite_fn_t)(const void *, size_t, size_t, FILE *);
typedef int (*fputc_fn_t)(int, FILE *);

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

static int shim_open_proc_path(const char *path) {
    char buffer[512];
    if (strcmp(path, "/proc/self/stat") == 0) {
        snprintf(buffer, sizeof(buffer), "%ld (process) R 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0\n", (long)getpid());
        return shim_open_memory(buffer);
    }
    if (strcmp(path, "/proc/self/status") == 0) {
        snprintf(buffer, sizeof(buffer), "Name:\tprocess\nPid:\t%ld\nPPid:\t0\nState:\tR (running)\n", (long)getpid());
        return shim_open_memory(buffer);
    }
    if (strcmp(path, "/proc/self/cmdline") == 0) {
        return shim_open_memory("process");
    }
    if (strcmp(path, "/proc/self/fd/0") == 0 || strcmp(path, "/proc/curproc/fd/0") == 0) {
        return dup(STDIN_FILENO);
    }
    if (strcmp(path, "/proc/self/fd/1") == 0 || strcmp(path, "/proc/curproc/fd/1") == 0) {
        return dup(STDOUT_FILENO);
    }
    if (strcmp(path, "/proc/self/fd/2") == 0 || strcmp(path, "/proc/curproc/fd/2") == 0) {
        return dup(STDERR_FILENO);
    }
    errno = ENOENT;
    return -1;
}

static int shim_open_dev_path(const char *path, int flags, mode_t mode, int has_mode) {
    if (path == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (strncmp(path, "/proc/", 6) == 0) {
        (void)flags;
        (void)mode;
        (void)has_mode;
        return shim_open_proc_path(path);
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

pid_t fork(void) {
    int32_t child_pid = micro_os_fork();
    if (child_pid > 0) {
        micro_os_exit_forked_child(child_pid, 127);
    }
    errno = ENOSYS;
    return -1;
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
    fflush(NULL);
    micro_os_process_exit((int32_t)status);
}

void _exit(int status) {
    micro_os_process_exit((int32_t)status);
}

void _Exit(int status) {
    micro_os_process_exit((int32_t)status);
}
