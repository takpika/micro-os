#ifndef MICRO_OS_OS_ASSUMES_H
#define MICRO_OS_OS_ASSUMES_H

#include <assert.h>

#define os_assumes(expr) (expr)
#define os_assumes_zero(expr) (expr)
#define os_assert(expr) assert(expr)

#endif
