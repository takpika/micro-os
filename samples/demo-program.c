#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int entry(int argc, char **argv) {
    printf("hello from ordinary C pid=%d argc=%d\n", getpid(), argc);

    for (int i = 0; i < argc; i++) {
        printf("argv[%d]=%s\n", i, argv[i]);
    }

    fputs("stderr is routed through the CRT shim\n", stderr);
    printf("\x1b[32mANSI green\x1b[0m \x1b[1;36mbold cyan\x1b[0m \x1b[4;33munderlined yellow\x1b[0m\n");

    if (argc > 1 && argv[1] != NULL && argv[1][0] == 'x') {
        exit(7);
    }

    return 0;
}
