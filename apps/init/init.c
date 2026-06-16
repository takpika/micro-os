// init (PID 1) — a generic launcher. Reads $BUNDLE/etc/init.conf (TOML) and runs
// two commands: `pre-start` (bootstrap, to completion) then `start` (the
// session). When `start` exits, init returns and the kernel panics. init knows
// nothing about busybox / shells / wm — that is all policy in init.conf.
//
//   [command]
//   pre-start = 'busybox sh -c "busybox --install -s ~/.local/bin"'
//   start     = 'busybox sh -i'

#include "micro_os.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void logmsg(int is_err, const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (is_err) micro_os_stderr(buf);
    else micro_os_stdout(buf);
}

static char *trim(char *s) {
    while (*s == ' ' || *s == '\t' || *s == '\r') s++;
    char *end = s + strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
        *--end = 0;
    }
    return s;
}

// Parse a TOML string value (literal '…', basic "…", or bare). Returns malloc'd.
static char *parse_value(const char *raw) {
    if (*raw == '\'') {
        const char *end = strchr(raw + 1, '\'');
        size_t len = end ? (size_t)(end - (raw + 1)) : strlen(raw + 1);
        char *value = malloc(len + 1);
        memcpy(value, raw + 1, len);
        value[len] = 0;
        return value;
    }
    if (*raw == '"') {
        char *value = malloc(strlen(raw) + 1);
        size_t vi = 0;
        for (const char *p = raw + 1; *p; ) {
            if (*p == '\\' && p[1]) {
                char c = p[1];
                value[vi++] = (c == 'n') ? '\n' : (c == 't') ? '\t' : c;
                p += 2;
                continue;
            }
            if (*p == '"') break;
            value[vi++] = *p++;
        }
        value[vi] = 0;
        return value;
    }
    size_t len = 0;
    while (raw[len] && raw[len] != ' ' && raw[len] != '\t' && raw[len] != '#') len++;
    char *value = malloc(len + 1);
    memcpy(value, raw, len);
    value[len] = 0;
    return value;
}

// Extract [command] pre-start / start from init.conf text (modified in place).
static void parse_conf(char *text, char **pre_start, char **start) {
    *pre_start = NULL;
    *start = NULL;
    char section[64] = "";
    char *save = NULL;

    for (char *line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char *t = trim(line);
        if (*t == 0 || *t == '#') continue;

        if (*t == '[') {
            char *close = strchr(t, ']');
            if (close) {
                size_t len = (size_t)(close - (t + 1));
                if (len >= sizeof section) len = sizeof section - 1;
                memcpy(section, t + 1, len);
                section[len] = 0;
                char *trimmed = trim(section);
                memmove(section, trimmed, strlen(trimmed) + 1);
            }
            continue;
        }

        char *eq = strchr(t, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = trim(t);
        char *val = trim(eq + 1);
        if (strcmp(section, "command") == 0) {
            if (strcmp(key, "pre-start") == 0) *pre_start = parse_value(val);
            else if (strcmp(key, "start") == 0) *start = parse_value(val);
        }
    }
}

// Split a command line into argv (quotes stripped; no variable expansion).
// Returns argc; *out_argv is a malloc'd, NULL-terminated array of malloc'd strings.
static int split_command(const char *s, char ***out_argv) {
    int cap = 8, argc = 0;
    char **argv = malloc(cap * sizeof(char *));
    char *token = malloc(strlen(s) + 1);
    size_t ti = 0;
    int has_token = 0;

    const char *p = s;
    while (*p) {
        char c = *p;
        if (c == ' ' || c == '\t') {
            if (has_token) {
                token[ti] = 0;
                if (argc + 1 >= cap) { cap *= 2; argv = realloc(argv, cap * sizeof(char *)); }
                argv[argc++] = strdup(token);
                ti = 0; has_token = 0;
            }
            p++;
            continue;
        }
        if (c == '\'') {
            has_token = 1; p++;
            while (*p && *p != '\'') token[ti++] = *p++;
            if (*p) p++;
            continue;
        }
        if (c == '"') {
            has_token = 1; p++;
            while (*p && *p != '"') {
                if (*p == '\\' && (p[1] == '"' || p[1] == '\\')) { token[ti++] = p[1]; p += 2; continue; }
                token[ti++] = *p++;
            }
            if (*p) p++;
            continue;
        }
        has_token = 1;
        token[ti++] = c;
        p++;
    }
    if (has_token) {
        token[ti] = 0;
        if (argc + 1 >= cap) { cap *= 2; argv = realloc(argv, cap * sizeof(char *)); }
        argv[argc++] = strdup(token);
    }

    free(token);
    argv[argc] = NULL;
    *out_argv = argv;
    return argc;
}

// Launch a command line and block until it exits. Returns its exit status.
static int run_and_wait(const char *command_line) {
    char **argv = NULL;
    int n = split_command(command_line, &argv);
    int result = -1;
    if (n == 0) {
        logmsg(1, "init: empty command\n");
    } else {
        int pid = micro_os_spawn(argv[0], n - 1, (n > 1) ? &argv[1] : NULL);
        if (pid > 0) {
            int status = 0;
            micro_os_waitpid(pid, &status, 0);
            result = status;
        } else {
            logmsg(1, "init: failed to launch %s\n", argv[0]);
        }
    }
    for (int i = 0; i < n; i++) free(argv[i]);
    free(argv);
    return result;
}

int entry(int argc, char **argv) {
    (void)argc;
    (void)argv;
    logmsg(0, "init: starting\n");

    const char *bundle = getenv("BUNDLE");
    if (!bundle || !*bundle) {
        logmsg(1, "init: BUNDLE is not set; cannot locate init.conf\n");
        return 1;
    }
    setenv("APP_ROOT", bundle, 1);

    char path[4096];
    snprintf(path, sizeof path, "%s/etc/init.conf", bundle);
    FILE *file = fopen(path, "rb");
    if (!file) {
        logmsg(1, "init: cannot read %s\n", path);
        return 1;
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (size < 0) { fclose(file); logmsg(1, "init: cannot size %s\n", path); return 1; }
    char *text = malloc((size_t)size + 1);
    size_t read = fread(text, 1, (size_t)size, file);
    text[read] = 0;
    fclose(file);

    char *pre_start = NULL, *start = NULL;
    parse_conf(text, &pre_start, &start);

    if (pre_start && *pre_start) {
        logmsg(0, "init: pre-start: %s\n", pre_start);
        int status = run_and_wait(pre_start);
        logmsg(0, "init: pre-start exited (status %d)\n", status);
    }

    int code;
    if (!start || !*start) {
        logmsg(1, "init: init.conf has no [command] start = …\n");
        code = 1;
    } else {
        logmsg(0, "init: start: %s\n", start);
        code = run_and_wait(start);
        logmsg(0, "init: start exited (status %d); halting\n", code);
    }

    free(pre_start);
    free(start);
    free(text);
    return code;
}
