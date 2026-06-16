#include <stdio.h>
#include <string.h>
#include <unistd.h>

int entry(int argc, char **argv) {
    char buffer[128];

    puts("stdin demo: type a line and press return");
    ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer) - 1);
    if (count <= 0) {
        puts("stdin demo: no input");
        return 1;
    }

    buffer[count] = '\0';
    printf("stdin demo: read %zd bytes: %s", count, buffer);
    if (buffer[count - 1] != '\n') {
        puts("");
    }
    return 0;
}
