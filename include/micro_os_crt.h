#ifndef MICRO_OS_CRT_H
#define MICRO_OS_CRT_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>

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

#ifdef __cplusplus
}
#endif

#define printf micro_os_crt_printf
#define fprintf micro_os_crt_fprintf
#define puts micro_os_crt_puts
#define fputs micro_os_crt_fputs
#define fwrite micro_os_crt_fwrite
#define write micro_os_crt_write
#define read micro_os_crt_read
#define fread micro_os_crt_fread
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

#endif
