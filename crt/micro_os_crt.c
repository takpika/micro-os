#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "micro_os.h"

static int micro_os_crt_stream_is_tty(FILE *stream, int expectedFd) {
    return (stream == stdout || stream == stderr || stream == stdin) && isatty(fileno(stream)) && fileno(stream) == expectedFd;
}

static int micro_os_vwrite(FILE *stream, const char *format, va_list args) {
    if (!micro_os_crt_stream_is_tty(stream, STDOUT_FILENO) && !micro_os_crt_stream_is_tty(stream, STDERR_FILENO)) {
        return vfprintf(stream, format, args);
    }

    va_list copy;
    va_copy(copy, args);
    int length = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (length < 0) {
        return length;
    }

    char stackBuffer[1024];
    char *buffer = stackBuffer;
    size_t capacity = (size_t)length + 1;
    if (capacity > sizeof(stackBuffer)) {
        buffer = (char *)malloc(capacity);
        if (buffer == NULL) {
            errno = ENOMEM;
            return -1;
        }
    }

    vsnprintf(buffer, capacity, format, args);
    if (micro_os_crt_stream_is_tty(stream, STDERR_FILENO)) {
        micro_os_stderr(buffer);
    } else {
        micro_os_stdout(buffer);
    }

    if (buffer != stackBuffer) {
        free(buffer);
    }
    return length;
}

int micro_os_crt_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = micro_os_vwrite(stdout, format, args);
    va_end(args);
    return result;
}

int micro_os_crt_fprintf(FILE *stream, const char *format, ...) {
    va_list args;
    va_start(args, format);
    int result = micro_os_vwrite(stream, format, args);
    va_end(args);
    return result;
}

int micro_os_crt_puts(const char *text) {
    if (!isatty(STDOUT_FILENO)) {
        int result = fputs(text != NULL ? text : "(null)", stdout);
        if (result < 0) {
            return result;
        }
        return fputs("\n", stdout);
    }
    micro_os_stdout(text != NULL ? text : "(null)");
    micro_os_stdout("\n");
    return 0;
}

int micro_os_crt_fputs(const char *text, FILE *stream) {
    if (micro_os_crt_stream_is_tty(stream, STDERR_FILENO)) {
        micro_os_stderr(text != NULL ? text : "(null)");
    } else if (micro_os_crt_stream_is_tty(stream, STDOUT_FILENO)) {
        micro_os_stdout(text != NULL ? text : "(null)");
    } else {
        return fputs(text, stream);
    }
    return 0;
}

size_t micro_os_crt_fwrite(const void *ptr, size_t size, size_t count, FILE *stream) {
    int ttyStdout = micro_os_crt_stream_is_tty(stream, STDOUT_FILENO);
    int ttyStderr = micro_os_crt_stream_is_tty(stream, STDERR_FILENO);
    if (!ttyStdout && !ttyStderr) {
        return fwrite(ptr, size, count, stream);
    }

    size_t bytes = size * count;
    if (ptr == NULL || bytes == 0) {
        return 0;
    }

    char *buffer = (char *)malloc(bytes + 1);
    if (buffer == NULL) {
        errno = ENOMEM;
        return 0;
    }
    memcpy(buffer, ptr, bytes);
    buffer[bytes] = '\0';

    if (ttyStderr) {
        micro_os_stderr(buffer);
    } else {
        micro_os_stdout(buffer);
    }
    free(buffer);
    return count;
}

ssize_t micro_os_crt_write(int fd, const void *buffer, size_t count) {
    if ((fd != STDOUT_FILENO && fd != STDERR_FILENO) || !isatty(fd)) {
        return write(fd, buffer, count);
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

    if (fd == STDERR_FILENO) {
        micro_os_stderr(text);
    } else {
        micro_os_stdout(text);
    }
    free(text);
    return (ssize_t)count;
}

ssize_t micro_os_crt_read(int fd, void *buffer, size_t count) {
    // Only the real console stdin routes to the host stdin queue. A redirected
    // fd 0 (a pipe or file, e.g. the read end of `… | cat`) is not a tty, so let
    // it fall through to the shim read(), which honours the kernel fd table.
    // Mirrors micro_os_crt_write's isatty() gate on the output side. isatty()
    // sets errno=ENOTTY on a non-tty; preserve the caller's errno across the
    // probe so a clean read doesn't leave a stale error (grep keys off it).
    int saved_errno = errno;
    int is_console_stdin = (fd == STDIN_FILENO) && isatty(fd);
    errno = saved_errno;
    if (!is_console_stdin) {
        return read(fd, buffer, count);
    }

    if (buffer == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (count == 0) {
        return 0;
    }

    int32_t result = micro_os_stdin((char *)buffer, (int32_t)count);
    if (result < 0) {
        errno = EIO;
        return -1;
    }
    return (ssize_t)result;
}

size_t micro_os_crt_fread(void *ptr, size_t size, size_t count, FILE *stream) {
    if (stream != stdin) {
        return fread(ptr, size, count, stream);
    }

    if (size == 0 || count == 0) {
        return 0;
    }
    size_t bytes = size * count;
    ssize_t result = micro_os_crt_read(STDIN_FILENO, ptr, bytes);
    if (result <= 0) {
        return 0;
    }
    return (size_t)result / size;
}

char *micro_os_crt_fgets(char *str, int count, FILE *stream) {
    if (stream != stdin) {
        return fgets(str, count, stream);
    }

    if (str == NULL || count <= 0) {
        errno = EINVAL;
        return NULL;
    }

    int offset = 0;
    while (offset < count - 1) {
        char ch = '\0';
        ssize_t result = micro_os_crt_read(STDIN_FILENO, &ch, 1);
        if (result <= 0) {
            break;
        }
        str[offset++] = ch;
        if (ch == '\n') {
            break;
        }
    }

    if (offset == 0) {
        return NULL;
    }
    str[offset] = '\0';
    return str;
}

int micro_os_crt_getchar(void) {
    unsigned char ch = 0;
    ssize_t result = micro_os_crt_read(STDIN_FILENO, &ch, 1);
    if (result <= 0) {
        return EOF;
    }
    return (int)ch;
}

// A stream whose underlying fd is managed by the kernel (console stdin, or a
// pipe/file fd in the process fd table — e.g. the read end of `… | grep`) must
// be read through our shim. libc stdio refills its FILE buffer with the raw
// read(2) syscall, which bypasses the shim and hits the unrelated real fd
// (/dev/null → instant EOF). For those, read via micro_os_crt_read instead.
static int micro_os_crt_stream_is_hosted(FILE *stream) {
    if (stream == NULL) return 0;
    if (stream == stdin) return 1;
    int fd = fileno(stream);
    if (fd < 0) return 0;
    return micro_os_fd_kind(fd) != 0;   // 0 == none (real fd)
}

// getc() on stdin must route through the host console too. Unlike read/fgets/
// getchar, libc stdio's getc/getc_unlocked refill the FILE buffer via the raw
// read(2) syscall, which bypasses our shim and hits the (EOF) host fd 0 — so an
// interactive reader like toysh's getc(stdin) would see instant EOF. Route
// hosted streams here; other streams keep native buffered I/O.
int micro_os_crt_getc(FILE *stream) {
    if (micro_os_crt_stream_is_hosted(stream)) {
        unsigned char ch = 0;
        int fd = (stream == stdin) ? STDIN_FILENO : fileno(stream);
        ssize_t r = micro_os_crt_read(fd, &ch, 1);
        return r <= 0 ? EOF : (int)ch;
    }
    return fgetc(stream);
}

// getline()/getdelim() are not macro-wrapped by stdio, so toybox readers built
// on them (do_lines -> tac/sort/…, and grep's fdopen()+getdelim()) would read
// the wrong real fd. Route hosted streams through micro_os_crt_read; others use
// the real getdelim().
ssize_t micro_os_crt_getdelim(char **lineptr, size_t *n, int delim, FILE *stream) {
    if (!micro_os_crt_stream_is_hosted(stream)) {
        return getdelim(lineptr, n, delim, stream);
    }
    if (lineptr == NULL || n == NULL) { errno = EINVAL; return -1; }
    int fd = (stream == stdin) ? STDIN_FILENO : fileno(stream);
    if (*lineptr == NULL || *n == 0) {
        size_t cap = 128;
        char *buf = (char *)realloc(*lineptr, cap);
        if (buf == NULL) { errno = ENOMEM; return -1; }
        *lineptr = buf;
        *n = cap;
    }
    size_t len = 0;
    for (;;) {
        unsigned char ch;
        ssize_t r = micro_os_crt_read(fd, &ch, 1);
        if (r < 0) return -1;
        if (r == 0) break;            // EOF
        if (len + 2 > *n) {
            size_t cap = *n * 2;
            char *buf = (char *)realloc(*lineptr, cap);
            if (buf == NULL) { errno = ENOMEM; return -1; }
            *lineptr = buf;
            *n = cap;
        }
        (*lineptr)[len++] = (char)ch;
        if ((int)ch == delim) break;
    }
    if (len == 0) { errno = 0; return -1; }   // clean EOF is not an error
    (*lineptr)[len] = '\0';
    return (ssize_t)len;
}

ssize_t micro_os_crt_getline(char **lineptr, size_t *n, FILE *stream) {
    return micro_os_crt_getdelim(lineptr, n, '\n', stream);
}

// fflush(NULL) is supposed to flush every open stream, but its global walk also
// visits streams this program didn't open for output — most notably stdio
// streams left on a since-closed fd (e.g. toysh's fdopen(254) for subshell
// marshalling). On Darwin, fflush even touches read streams (to sync the file
// position via lseek), so such a leaked stream makes fflush(NULL) fail EBADF.
// toybox's xexit reads that as a stdout write error and prints a spurious
// "write: Bad file descriptor". Program output goes through the host ABI, so the
// only streams we ever need to flush are stdout/stderr; flush just those and skip
// the global walk. A specific stream still flushes normally.
int micro_os_crt_fflush(FILE *stream) {
    if (stream != NULL) {
        return fflush(stream);
    }
    int out = fflush(stdout);
    int err = fflush(stderr);
    return (out != 0 || err != 0) ? EOF : 0;
}

// ---- fork()/vfork() emulation over the spawn-based kernel --------------------
//
// There is no real fork: all processes are pthreads in one address space, so the
// address space can't be copied. We emulate the fork()+exec() idiom the way a
// single-stack vfork would, by snapshotting and restoring the stack:
//
//   fork()  reserves a child pid, snapshots the live stack from here up to the
//           thread's stack base, sigsetjmp-anchors, and returns 0 — so the caller
//           runs the "child" path. (toybox is built CONFIG_TOYBOX_NORECURSE=y, so
//           that path just sets up fds and exec()s; it never runs an applet
//           in-process, which would clobber this process's globals.)
//   exec*() spawns the command into the reserved pid, then crt_fork_finish()
//           restores the snapshot and siglongjmps back, so fork() "returns" the
//           child pid to the parent with its stack (hence all pointers) intact.
//   exit()/_exit() in that context (e.g. a failed exec) records the child's
//           status and resumes the parent the same way.
//
// crt_fork_finish() runs deeper on the stack than fork()'s anchor (toybox's child
// call chain is longer than its fork chain), so the restored region [lo, base) is
// entirely above the current SP — the memcpy can't corrupt the running frame, and
// no scratch stack is needed. State is per-process (each process has its own copy
// of this dylib via loader isolation); __thread guards the future MT case.
typedef struct {
    int        active;
    int32_t    child;
    sigjmp_buf jb;
    void      *lo;
    size_t     len;
    void      *buf;
} crt_fork_state;
static __thread crt_fork_state crt_fk;

static void crt_fork_finish(void) {
    micro_os_fork_child_end();                   // done acting as the child
    memcpy(crt_fk.lo, crt_fk.buf, crt_fk.len);   // restore parent stack (same addrs)
    free(crt_fk.buf);
    crt_fk.buf = NULL;
    int32_t child = crt_fk.child;
    crt_fk.active = 0;
    siglongjmp(crt_fk.jb, (int)child);           // -> parent; fork() returns child
    __builtin_unreachable();
}

void micro_os_crt_exit(int status) {
    if (crt_fk.active) {
        micro_os_exit_forked_child(crt_fk.child, (int32_t)status);
        crt_fork_finish();
        __builtin_unreachable();
    }
    fflush(NULL);
    micro_os_process_exit((int32_t)status);
    __builtin_unreachable();
}

pid_t micro_os_crt_getpid(void) {
    return (pid_t)micro_os_pid();
}

pid_t micro_os_crt_fork(void) {
    int32_t child = micro_os_fork();
    if (child <= 0) { errno = EAGAIN; return -1; }

    char anchor;
    void *lo = (void *)&anchor;
    void *base = pthread_get_stackaddr_np(pthread_self());   // highest stack addr
    if (base <= lo) { micro_os_exit_forked_child(child, 127); errno = EAGAIN; return -1; }
    size_t len = (size_t)((char *)base - (char *)lo);
    void *buf = malloc(len);
    if (buf == NULL) { micro_os_exit_forked_child(child, 127); errno = ENOMEM; return -1; }
    memcpy(buf, lo, len);

    crt_fk.active = 1;
    crt_fk.child = child;
    crt_fk.lo = lo;
    crt_fk.len = len;
    crt_fk.buf = buf;

    int rv = sigsetjmp(crt_fk.jb, 1);
    if (rv == 0) {
        micro_os_fork_child_begin(child);   // act as the child until exec/exit
        return 0;                           // child path
    }
    return (pid_t)rv;                 // parent path (resumed); rv == child pid
}

int micro_os_crt_execv(const char *path, char *const argv[]) {
    int argc = 0;
    if (argv != NULL) {
        while (argv[argc] != NULL) {
            argc++;
        }
    }

    if (crt_fk.active) {
        // emulated child: spawn the command into the reserved pid (the kernel
        // resolves `path`, falling back to the toybox multicall for applet
        // names), then resume the parent. Never returns.
        int32_t r = micro_os_exec_forked_child(crt_fk.child, path, (int32_t)argc, (char **)argv);
        if (r < 0) {
            micro_os_exit_forked_child(crt_fk.child, 127);
        }
        crt_fork_finish();
        __builtin_unreachable();
    }

    int32_t pid = micro_os_spawn(path, (int32_t)argc, (char **)argv);
    if (pid < 0) {
        errno = ENOENT;
        return -1;
    }

    micro_os_process_exit(0);
    __builtin_unreachable();
}

int micro_os_crt_execvp(const char *file, char *const argv[]) {
    return micro_os_crt_execv(file, argv);
}

int micro_os_crt_execve(const char *path, char *const argv[], char *const envp[]) {
    (void)envp;   // env is process-global in this kernel; ignore the explicit set
    return micro_os_crt_execv(path, argv);
}

int micro_os_crt_system(const char *command) {
    (void)command;
    errno = ENOSYS;
    return -1;
}
