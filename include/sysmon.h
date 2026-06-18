#ifndef MICRO_OS_SYSMON_H
#define MICRO_OS_SYSMON_H

#include <stddef.h>
#include <xpc/xpc.h>

typedef struct micro_os_sysmon_request *sysmon_request_t;
typedef struct micro_os_sysmon_table *sysmon_table_t;
typedef struct micro_os_sysmon_row *sysmon_row_t;

#define SYSMON_REQUEST_TYPE_PROCESS 1

#define SYSMON_ATTR_PROC_PID 1
#define SYSMON_ATTR_PROC_FLAGS 2
#define SYSMON_ATTR_PROC_UID 3
#define SYSMON_ATTR_PROC_COMM 4
#define SYSMON_ATTR_PROC_ARGUMENTS 5
#define SYSMON_ATTR_PROC_RUID 6
#define SYSMON_ATTR_PROC_RGID 7
#define SYSMON_ATTR_PROC_PPID 8
#define SYSMON_ATTR_PROC_PGID 9
#define SYSMON_ATTR_PROC_TDEV 10
#define SYSMON_ATTR_PROC_START 11

sysmon_request_t sysmon_request_create_with_error(int type, void (^handler)(sysmon_table_t table, const char *error));
void sysmon_request_add_attribute(sysmon_request_t request, int attribute);
void sysmon_request_execute(sysmon_request_t request);
void sysmon_release(void *object);
sysmon_table_t sysmon_retain(sysmon_table_t table);
size_t sysmon_table_get_count(sysmon_table_t table);
sysmon_row_t sysmon_table_get_row(sysmon_table_t table, size_t index);
xpc_object_t sysmon_row_get_value(sysmon_row_t row, int attribute);

#endif
