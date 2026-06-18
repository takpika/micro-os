#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <Block.h>
#include <xpc/xpc.h>

#include "micro_os.h"
#include "sysmon.h"

#ifndef PROC_FLAG_SYSTEM
#define PROC_FLAG_SYSTEM 0x00000001
#endif

#ifndef PROC_FLAG_CONTROLT
#define PROC_FLAG_CONTROLT 0x00000002
#endif

struct micro_os_sysmon_row {
    xpc_object_t pid;
    xpc_object_t flags;
    xpc_object_t uid;
    xpc_object_t comm;
    xpc_object_t arguments;
    xpc_object_t ruid;
    xpc_object_t rgid;
    xpc_object_t ppid;
    xpc_object_t pgid;
    xpc_object_t tdev;
    xpc_object_t start;
};

struct micro_os_sysmon_table {
    int kind;
    int refs;
    size_t count;
    struct micro_os_sysmon_row *rows;
};

struct micro_os_sysmon_request {
    int kind;
    int refs;
    int type;
    void (^handler)(sysmon_table_t table, const char *error);
};

enum {
    MICRO_OS_SYSMON_KIND_REQUEST = 1,
    MICRO_OS_SYSMON_KIND_TABLE = 2,
};

static void release_row(struct micro_os_sysmon_row *row) {
    if (row == NULL) {
        return;
    }
    if (row->pid) xpc_release(row->pid);
    if (row->flags) xpc_release(row->flags);
    if (row->uid) xpc_release(row->uid);
    if (row->comm) xpc_release(row->comm);
    if (row->arguments) xpc_release(row->arguments);
    if (row->ruid) xpc_release(row->ruid);
    if (row->rgid) xpc_release(row->rgid);
    if (row->ppid) xpc_release(row->ppid);
    if (row->pgid) xpc_release(row->pgid);
    if (row->tdev) xpc_release(row->tdev);
    if (row->start) xpc_release(row->start);
}

static void append_argv(xpc_object_t array, const char *argv, size_t capacity) {
    size_t offset = 0;
    while (offset < capacity && argv[offset] != '\0') {
        xpc_array_set_string(array, XPC_ARRAY_APPEND, argv + offset);
        offset += strnlen(argv + offset, capacity - offset) + 1;
    }
}

static sysmon_table_t create_process_table(void) {
    int32_t count = micro_os_process_snapshot(NULL, 0);
    if (count < 0) {
        return NULL;
    }

    micro_os_process_info_t *infos = NULL;
    if (count > 0) {
        infos = (micro_os_process_info_t *)calloc((size_t)count, sizeof(*infos));
        if (infos == NULL) {
            return NULL;
        }
        int32_t actual = micro_os_process_snapshot(infos, count);
        if (actual < 0) {
            free(infos);
            return NULL;
        }
        if (actual < count) {
            count = actual;
        }
    }

    sysmon_table_t table = (sysmon_table_t)calloc(1, sizeof(*table));
    if (table == NULL) {
        free(infos);
        return NULL;
    }
    table->kind = MICRO_OS_SYSMON_KIND_TABLE;
    table->refs = 1;
    table->count = (size_t)count;
    table->rows = (struct micro_os_sysmon_row *)calloc((size_t)count, sizeof(*table->rows));
    if (count > 0 && table->rows == NULL) {
        free(table);
        free(infos);
        return NULL;
    }

    uid_t uid = getuid();
    gid_t gid = getgid();
    for (int32_t i = 0; i < count; i++) {
        struct micro_os_sysmon_row *row = &table->rows[i];
        const char *command = infos[i].command[0] ? infos[i].command : "process";
        row->pid = xpc_uint64_create((uint64_t)infos[i].pid);
        row->flags = xpc_uint64_create(PROC_FLAG_CONTROLT);
        row->uid = xpc_uint64_create((uint64_t)uid);
        row->comm = xpc_string_create(command);
        row->arguments = xpc_array_create(NULL, 0);
        append_argv(row->arguments, infos[i].argv, sizeof(infos[i].argv));
        row->ruid = xpc_uint64_create((uint64_t)uid);
        row->rgid = xpc_uint64_create((uint64_t)gid);
        row->ppid = xpc_uint64_create((uint64_t)infos[i].parent_pid);
        row->pgid = xpc_uint64_create((uint64_t)(infos[i].parent_pid > 0 ? infos[i].parent_pid : infos[i].pid));
        row->tdev = xpc_uint64_create((uint64_t)infos[i].tty_id);
        row->start = xpc_date_create((int64_t)infos[i].start_time_ms * 1000000);
    }

    free(infos);
    return table;
}

sysmon_request_t sysmon_request_create_with_error(int type, void (^handler)(sysmon_table_t table, const char *error)) {
    sysmon_request_t request = (sysmon_request_t)calloc(1, sizeof(*request));
    if (request == NULL) {
        return NULL;
    }
    request->kind = MICRO_OS_SYSMON_KIND_REQUEST;
    request->refs = 1;
    request->type = type;
    request->handler = Block_copy(handler);
    return request;
}

void sysmon_request_add_attribute(sysmon_request_t request, int attribute) {
    (void)request;
    (void)attribute;
}

void sysmon_request_execute(sysmon_request_t request) {
    if (request == NULL || request->handler == NULL) {
        return;
    }
    if (request->type != SYSMON_REQUEST_TYPE_PROCESS) {
        request->handler(NULL, "unsupported sysmon request");
        return;
    }
    sysmon_table_t table = create_process_table();
    request->handler(table, table == NULL ? "cannot build process table" : NULL);
    sysmon_release(table);
}

void sysmon_release(void *object) {
    if (object == NULL) {
        return;
    }
    int kind = *(int *)object;
    if (kind == MICRO_OS_SYSMON_KIND_TABLE) {
        sysmon_table_t table = (sysmon_table_t)object;
        table->refs--;
        if (table->refs > 0) {
            return;
        }
        for (size_t i = 0; i < table->count; i++) {
            release_row(&table->rows[i]);
        }
        free(table->rows);
        free(table);
    } else if (kind == MICRO_OS_SYSMON_KIND_REQUEST) {
        sysmon_request_t request = (sysmon_request_t)object;
        request->refs--;
        if (request->refs > 0) {
            return;
        }
        if (request->handler) {
            Block_release(request->handler);
        }
        free(request);
    }
}

sysmon_table_t sysmon_retain(sysmon_table_t table) {
    if (table != NULL) {
        table->refs++;
    }
    return table;
}

size_t sysmon_table_get_count(sysmon_table_t table) {
    return table == NULL ? 0 : table->count;
}

sysmon_row_t sysmon_table_get_row(sysmon_table_t table, size_t index) {
    if (table == NULL || index >= table->count) {
        return NULL;
    }
    return &table->rows[index];
}

xpc_object_t sysmon_row_get_value(sysmon_row_t row, int attribute) {
    if (row == NULL) {
        return NULL;
    }
    switch (attribute) {
    case SYSMON_ATTR_PROC_PID: return row->pid;
    case SYSMON_ATTR_PROC_FLAGS: return row->flags;
    case SYSMON_ATTR_PROC_UID: return row->uid;
    case SYSMON_ATTR_PROC_COMM: return row->comm;
    case SYSMON_ATTR_PROC_ARGUMENTS: return row->arguments;
    case SYSMON_ATTR_PROC_RUID: return row->ruid;
    case SYSMON_ATTR_PROC_RGID: return row->rgid;
    case SYSMON_ATTR_PROC_PPID: return row->ppid;
    case SYSMON_ATTR_PROC_PGID: return row->pgid;
    case SYSMON_ATTR_PROC_TDEV: return row->tdev;
    case SYSMON_ATTR_PROC_START: return row->start;
    default: return NULL;
    }
}
