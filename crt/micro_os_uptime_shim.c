#include <stddef.h>
#include <sys/socket.h>

int micro_os_realhostname_sa(char *host, size_t hsize, struct sockaddr *addr, int addrlen) {
    (void)host;
    (void)hsize;
    (void)addr;
    (void)addrlen;
    return 0;
}
