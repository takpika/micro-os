/* iOS SDK shim for <sys/disk.h>.
 *
 * macOS ships <sys/disk.h>; the iOS SDK does not. This system-wide compat
 * header lets CUI programs that probe block devices (e.g. toybox's
 * lib/portability.c get_block_device_size, guarded by __APPLE__) compile
 * unchanged for iOS. Staged ahead of the SDK via -I, it shadows the (absent)
 * SDK header. The ioctls are inert on iOS — the sandbox can't reach block
 * devices — so this only needs to satisfy the compiler.
 *
 * This is build-integration glue, not a third-party source edit.
 */
#ifndef MICRO_OS_SYS_DISK_SHIM_H
#define MICRO_OS_SYS_DISK_SHIM_H

#include <stdint.h>
#include <sys/ioctl.h>

#ifndef DKIOCGETBLOCKSIZE
#define DKIOCGETBLOCKSIZE  _IOR('d', 24, uint32_t)
#endif
#ifndef DKIOCGETBLOCKCOUNT
#define DKIOCGETBLOCKCOUNT _IOR('d', 25, uint64_t)
#endif

#endif /* MICRO_OS_SYS_DISK_SHIM_H */
