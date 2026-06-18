/* iOS SDK shim for toybox <netinet/ip_icmp.h> users.
 *
 * Darwin provides struct icmp in the SDK, while toybox's ping uses the Linux
 * struct icmphdr spelling. Keep this as a thin compile-time compatibility layer
 * ahead of the SDK header; the socket behavior remains the platform's.
 */
#ifndef MICRO_OS_NETINET_IP_ICMP_SHIM_H
#define MICRO_OS_NETINET_IP_ICMP_SHIM_H

#include_next <netinet/ip_icmp.h>

#ifndef SOL_IP
#define SOL_IP IPPROTO_IP
#endif

#ifndef SO_MARK
#define SO_MARK 0
#endif

#ifndef ICMP_ECHO
#define ICMP_ECHO 8
#endif

#ifndef ICMP_ECHOREPLY
#define ICMP_ECHOREPLY 0
#endif

#ifndef MICRO_OS_HAVE_ICMPHDR
struct icmphdr {
  unsigned char type;
  unsigned char code;
  unsigned short checksum;
  union {
    struct {
      unsigned short id;
      unsigned short sequence;
    } echo;
    unsigned int gateway;
    struct {
      unsigned short __unused;
      unsigned short mtu;
    } frag;
  } un;
};
#endif

#endif /* MICRO_OS_NETINET_IP_ICMP_SHIM_H */
