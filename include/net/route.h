#pragma once

#include <sys/socket.h>

/*
 * iOS exposes AF_ROUTE/PF_ROUTE in <sys/socket.h> but does not ship
 * <net/route.h>. BIND only needs these route-message constants to enable its
 * route-socket code path; the code used here does not inspect rt_msghdr.
 */
#ifndef RTM_VERSION
#define RTM_VERSION 5
#endif

#ifndef RTM_NEWADDR
#define RTM_NEWADDR 0xc
#endif

#ifndef RTM_DELADDR
#define RTM_DELADDR 0xd
#endif
