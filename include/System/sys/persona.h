#ifndef MICRO_OS_SYSTEM_SYS_PERSONA_H
#define MICRO_OS_SYSTEM_SYS_PERSONA_H

#define PERSONA_INFO_V1 1

struct kpersona_info {
    unsigned int persona_info_version;
    unsigned int persona_id;
};

static inline int kpersona_pidinfo(int pid, struct kpersona_info *info) {
    (void)pid;
    if (info != 0) {
        info->persona_id = 0;
    }
    return 0;
}

#endif
