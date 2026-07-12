#ifndef MICRO_OS_CRT_H
#define MICRO_OS_CRT_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <wchar.h>

#include "micro_os.h"

#ifdef __cplusplus
extern "C" {
#endif

int micro_os_crt_printf(const char *format, ...);
int micro_os_crt_fprintf(FILE *stream, const char *format, ...);
int micro_os_crt_puts(const char *text);
int micro_os_crt_fputs(const char *text, FILE *stream);
size_t micro_os_crt_fwrite(const void *ptr, size_t size, size_t count, FILE *stream);
ssize_t micro_os_crt_write(int fd, const void *buffer, size_t count);
ssize_t micro_os_crt_read(int fd, void *buffer, size_t count);
size_t micro_os_crt_fread(void *ptr, size_t size, size_t count, FILE *stream);
char *micro_os_crt_fgets(char *str, int count, FILE *stream);
int micro_os_crt_getchar(void);
int micro_os_crt_getc(FILE *stream);
ssize_t micro_os_crt_getdelim(char **lineptr, size_t *n, int delim, FILE *stream);
ssize_t micro_os_crt_getline(char **lineptr, size_t *n, FILE *stream);
int micro_os_crt_fflush(FILE *stream);
void micro_os_crt_exit(int status) __attribute__((noreturn));
pid_t micro_os_crt_getpid(void);
pid_t micro_os_crt_fork(void);
int micro_os_crt_execv(const char *path, char *const argv[]);
int micro_os_crt_execvp(const char *file, char *const argv[]);
int micro_os_crt_execve(const char *path, char *const argv[], char *const envp[]);
int micro_os_crt_system(const char *command);

#ifdef __cplusplus
}
#endif

static inline int _fseeki64(FILE *stream, long long offset, int origin) {
    return fseeko(stream, (off_t)offset, origin);
}

static inline long long _ftelli64(FILE *stream) {
    return (long long)ftello(stream);
}

static inline FILE *_wfopen(const wchar_t *path, const wchar_t *mode) {
    char pathBuffer[4096];
    char modeBuffer[64];
    if (!path || !mode) {
        return NULL;
    }
    size_t pathLength = wcstombs(pathBuffer, path, sizeof(pathBuffer) - 1);
    if (pathLength == (size_t)-1) {
        return NULL;
    }
    pathBuffer[pathLength] = '\0';
    size_t modeLength = wcstombs(modeBuffer, mode, sizeof(modeBuffer) - 1);
    if (modeLength == (size_t)-1) {
        return NULL;
    }
    modeBuffer[modeLength] = '\0';
    return fopen(pathBuffer, modeBuffer);
}

static inline wchar_t *wcstok_s(wchar_t *str, const wchar_t *delimiters, wchar_t **context) {
    return wcstok(str, delimiters, context);
}

static inline wchar_t *_itow(int value, wchar_t *buffer, int radix) {
    if (!buffer) {
        return NULL;
    }
    if (radix == 16) {
        swprintf(buffer, 34, L"%x", value);
    } else if (radix == 8) {
        swprintf(buffer, 34, L"%o", value);
    } else {
        swprintf(buffer, 34, L"%d", value);
    }
    return buffer;
}

static inline char *itoa(int value, char *buffer, int radix) {
    if (!buffer) {
        return NULL;
    }
    if (radix == 16) {
        snprintf(buffer, 34, "%x", value);
    } else if (radix == 8) {
        snprintf(buffer, 34, "%o", value);
    } else {
        snprintf(buffer, 34, "%d", value);
    }
    return buffer;
}

static inline char *_itoa(int value, char *buffer, int radix) {
    return itoa(value, buffer, radix);
}

static inline errno_t strcpy_s(char *dest, size_t destSize, const char *src) {
    if (!dest || destSize == 0) {
        return 22;
    }
    const char *resolved = src ? src : "";
    size_t length = strlen(resolved);
    if (length >= destSize) {
        dest[0] = '\0';
        return 34;
    }
    memcpy(dest, resolved, length + 1);
    return 0;
}

static inline errno_t strncpy_s(char *dest, size_t destSize, const char *src, size_t count) {
    if (!dest || destSize == 0) {
        return 22;
    }
    const char *resolved = src ? src : "";
    size_t sourceLength = strlen(resolved);
    size_t copyLength = count == (size_t)-1 || count > sourceLength ? sourceLength : count;
    if (copyLength >= destSize) {
        copyLength = destSize - 1;
        memcpy(dest, resolved, copyLength);
        dest[copyLength] = '\0';
        return count == (size_t)-1 ? 0 : 34;
    }
    memcpy(dest, resolved, copyLength);
    dest[copyLength] = '\0';
    return 0;
}

static inline errno_t memcpy_s(void *dest, size_t destSize, const void *src, size_t count) {
    if (!dest || (!src && count != 0)) {
        return 22;
    }
    if (count > destSize) {
        memset(dest, 0, destSize);
        return 34;
    }
    if (count > 0) {
        memcpy(dest, src, count);
    }
    return 0;
}

static inline unsigned short _byteswap_ushort(unsigned short value) {
    return (unsigned short)((value >> 8) | (value << 8));
}

static inline errno_t micro_os_wcopy_part(wchar_t *dest, size_t destSize, const wchar_t *start, size_t count) {
    if (!dest) {
        return destSize == 0 ? 0 : 22;
    }
    if (destSize == 0) {
        return 22;
    }
    if (count >= destSize) {
        dest[0] = L'\0';
        return 34;
    }
    if (count > 0 && start) {
        wmemcpy(dest, start, count);
    }
    dest[count] = L'\0';
    return 0;
}

static inline errno_t _wsplitpath_s(
    const wchar_t *path,
    wchar_t *drive,
    size_t driveSize,
    wchar_t *dir,
    size_t dirSize,
    wchar_t *fname,
    size_t fnameSize,
    wchar_t *ext,
    size_t extSize
) {
    if (!path) {
        return 22;
    }

    const wchar_t *cursor = path;
    const wchar_t *driveStart = path;
    size_t driveLen = 0;
    if (cursor[0] && cursor[1] == L':') {
        driveLen = 2;
        cursor += 2;
    }

    const wchar_t *lastSlash = NULL;
    for (const wchar_t *scan = cursor; *scan; scan++) {
        if (*scan == L'/' || *scan == L'\\') {
            lastSlash = scan;
        }
    }
    const wchar_t *nameStart = lastSlash ? lastSlash + 1 : cursor;
    size_t dirLen = lastSlash ? (size_t)(lastSlash + 1 - cursor) : 0;

    const wchar_t *lastDot = NULL;
    for (const wchar_t *scan = nameStart; *scan; scan++) {
        if (*scan == L'.') {
            lastDot = scan;
        }
    }
    const wchar_t *extStart = lastDot ? lastDot : path + wcslen(path);
    size_t nameLen = (size_t)(extStart - nameStart);
    size_t extLen = lastDot ? wcslen(lastDot) : 0;

    errno_t status = 0;
    errno_t partStatus = micro_os_wcopy_part(drive, driveSize, driveStart, driveLen);
    if (partStatus) { status = partStatus; }
    partStatus = micro_os_wcopy_part(dir, dirSize, cursor, dirLen);
    if (partStatus && !status) { status = partStatus; }
    partStatus = micro_os_wcopy_part(fname, fnameSize, nameStart, nameLen);
    if (partStatus && !status) { status = partStatus; }
    partStatus = micro_os_wcopy_part(ext, extSize, extStart, extLen);
    if (partStatus && !status) { status = partStatus; }
    return status;
}

#define printf micro_os_crt_printf
#define fprintf micro_os_crt_fprintf
#define puts micro_os_crt_puts
#define fputs micro_os_crt_fputs
#ifndef __cplusplus
#define fwrite micro_os_crt_fwrite
#define write micro_os_crt_write
#define read micro_os_crt_read
#define fread micro_os_crt_fread
#endif
#define fgets micro_os_crt_fgets
#define getchar micro_os_crt_getchar
#undef getc
#define getc(stream) micro_os_crt_getc(stream)
#define getdelim micro_os_crt_getdelim
#define getline micro_os_crt_getline
#define fflush micro_os_crt_fflush
#define exit micro_os_crt_exit
#undef _exit
#define _exit micro_os_crt_exit
#define getpid micro_os_crt_getpid
#define fork micro_os_crt_fork
#define vfork micro_os_crt_fork
#define execv micro_os_crt_execv
#define execvp micro_os_crt_execvp
#define execve micro_os_crt_execve
#define system micro_os_crt_system

#endif
