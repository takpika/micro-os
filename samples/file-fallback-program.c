#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int entry(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/tmp/micro-os-file-fallback.txt";

    FILE *file = fopen(path, "w");
    if (file == NULL) {
        perror("fopen");
        return 1;
    }

    fprintf(file, "fprintf(file, ...) uses native libc\n");
    fwrite("fwrite(file, ...) uses native libc\n", 1, 35, file);
    fclose(file);

    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd >= 0) {
        write(fd, "write(fileFd, ...) uses native libc\n", 36);
        close(fd);
    }

    printf("wrote native file: %s\n", path);
    return 0;
}
