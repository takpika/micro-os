/* iOS SDK shim for <arpa/telnet.h>.
 *
 * The iOS SDK omits the historical telnet option constants. toybox's telnet
 * client only needs the protocol byte values, so define the small standard set
 * it references without changing upstream source.
 */
#ifndef MICRO_OS_ARPA_TELNET_SHIM_H
#define MICRO_OS_ARPA_TELNET_SHIM_H

#define IAC 255
#define DONT 254
#define DO 253
#define WONT 252
#define WILL 251
#define SB 250
#define SE 240

#define TELOPT_ECHO 1
#define TELOPT_SGA 3
#define TELOPT_TTYPE 24
#define TELOPT_NAWS 31

#define TELQUAL_IS 0
#define TELQUAL_SEND 1

#endif /* MICRO_OS_ARPA_TELNET_SHIM_H */
