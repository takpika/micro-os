#include "micro_os_gui_shim.h"
#include "micro_os.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GUI_MAX_WINDOWS 64
#define GUI_MAX_EVENTS 64

static int32_t gui_host_open_window(const char *title, const char *document, double width, double height) {
    typedef int32_t (*fn_t)(const char *, const char *, double, double);
    fn_t fn = (fn_t)dlsym(RTLD_DEFAULT, "micro_os_gui_host_open_window");
    return fn ? fn(title, document, width, height) : -1;
}

static int32_t gui_host_update_window(int32_t window_id, const char *document) {
    typedef int32_t (*fn_t)(int32_t, const char *);
    fn_t fn = (fn_t)dlsym(RTLD_DEFAULT, "micro_os_gui_host_update_window");
    return fn ? fn(window_id, document) : -1;
}

static int32_t gui_host_close_window(int32_t window_id) {
    typedef int32_t (*fn_t)(int32_t);
    fn_t fn = (fn_t)dlsym(RTLD_DEFAULT, "micro_os_gui_host_close_window");
    return fn ? fn(window_id) : -1;
}

typedef struct gui_buffer {
    char *bytes;
    size_t length;
    size_t capacity;
} gui_buffer;

typedef struct gui_window {
    int in_use;
    int shown;
    int32_t remote_id;
    double width;
    double height;
    char *title;
    gui_buffer document;
} gui_window;

static gui_window gui_windows[GUI_MAX_WINDOWS];
static micro_os_gui_event gui_events[GUI_MAX_EVENTS];
static int gui_event_read_index;
static int gui_event_write_index;
static int gui_event_count;
static pthread_mutex_t gui_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gui_event_cond = PTHREAD_COND_INITIALIZER;
static int gui_initialized;

static int gui_buffer_reserve(gui_buffer *buffer, size_t extra) {
    size_t required = buffer->length + extra + 1;
    if (required <= buffer->capacity) {
        return 0;
    }

    size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
    while (capacity < required) {
        capacity *= 2;
    }

    char *bytes = (char *)realloc(buffer->bytes, capacity);
    if (!bytes) {
        return -1;
    }

    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return 0;
}

static int gui_buffer_append(gui_buffer *buffer, const char *text) {
    size_t length = text ? strlen(text) : 0;
    if (gui_buffer_reserve(buffer, length) != 0) {
        return -1;
    }

    if (length > 0) {
        memcpy(buffer->bytes + buffer->length, text, length);
        buffer->length += length;
    }
    buffer->bytes[buffer->length] = '\0';
    return 0;
}

static int gui_buffer_append_escaped(gui_buffer *buffer, const char *text) {
    const unsigned char *cursor = (const unsigned char *)(text ? text : "");
    while (*cursor) {
        char encoded[4];
        switch (*cursor) {
        case '%':
        case '|':
        case '\n':
        case '\r':
        case '\t':
            snprintf(encoded, sizeof(encoded), "%%%02X", *cursor);
            if (gui_buffer_append(buffer, encoded) != 0) {
                return -1;
            }
            break;
        default:
            if (gui_buffer_reserve(buffer, 1) != 0) {
                return -1;
            }
            buffer->bytes[buffer->length++] = (char)*cursor;
            buffer->bytes[buffer->length] = '\0';
            break;
        }
        cursor++;
    }
    return 0;
}

static gui_window *gui_window_for(micro_os_gui_window_t window) {
    if (window <= 0 || window > GUI_MAX_WINDOWS) {
        return NULL;
    }
    gui_window *entry = &gui_windows[window - 1];
    return entry->in_use ? entry : NULL;
}

static int gui_append_row(micro_os_gui_window_t window, const char *kind, const char *first, const char *second) {
    gui_window *entry = gui_window_for(window);
    if (!entry) {
        return -1;
    }

    if (gui_buffer_append(&entry->document, kind) != 0 ||
        gui_buffer_append(&entry->document, "|") != 0 ||
        gui_buffer_append_escaped(&entry->document, first) != 0) {
        return -1;
    }

    if (second) {
        if (gui_buffer_append(&entry->document, "|") != 0 ||
            gui_buffer_append_escaped(&entry->document, second) != 0) {
            return -1;
        }
    }

    return gui_buffer_append(&entry->document, "\n");
}

void micro_os_gui_deliver_event(int32_t window_id, const char *control_id, const char *event_name) {
    pthread_mutex_lock(&gui_lock);
    micro_os_gui_event *event = &gui_events[gui_event_write_index];
    event->window = window_id;
    snprintf(event->control, sizeof(event->control), "%s", control_id ? control_id : "");
    snprintf(event->name, sizeof(event->name), "%s", event_name ? event_name : "");
    gui_event_write_index = (gui_event_write_index + 1) % GUI_MAX_EVENTS;
    if (gui_event_count == GUI_MAX_EVENTS) {
        gui_event_read_index = (gui_event_read_index + 1) % GUI_MAX_EVENTS;
    } else {
        gui_event_count++;
    }
    pthread_cond_signal(&gui_event_cond);
    pthread_mutex_unlock(&gui_lock);
}

int micro_os_gui_init(void) {
    if (gui_initialized) {
        return 0;
    }

    gui_initialized = 1;
    return 0;
}

micro_os_gui_window_t micro_os_gui_window_create(const char *title, double width, double height) {
    micro_os_gui_init();

    for (int index = 0; index < GUI_MAX_WINDOWS; index++) {
        if (!gui_windows[index].in_use) {
            gui_window *entry = &gui_windows[index];
            memset(entry, 0, sizeof(*entry));
            entry->in_use = 1;
            entry->remote_id = -1;
            entry->width = width;
            entry->height = height;
            entry->title = strdup(title ? title : "Untitled");
            gui_buffer_append(&entry->document, "v1\n");
            return index + 1;
        }
    }

    return -1;
}

int micro_os_gui_window_add_text(micro_os_gui_window_t window, const char *text) {
    return gui_append_row(window, "text", text, NULL);
}

int micro_os_gui_window_add_label(micro_os_gui_window_t window, const char *text) {
    return gui_append_row(window, "label", text, NULL);
}

int micro_os_gui_window_add_button(micro_os_gui_window_t window, const char *controlID, const char *title) {
    return gui_append_row(window, "button", controlID, title);
}

int micro_os_gui_window_add_spacer(micro_os_gui_window_t window) {
    return gui_append_row(window, "spacer", "", NULL);
}

int micro_os_gui_window_add_divider(micro_os_gui_window_t window) {
    return gui_append_row(window, "divider", "", NULL);
}

int micro_os_gui_window_show(micro_os_gui_window_t window) {
    gui_window *entry = gui_window_for(window);
    if (!entry) {
        return -1;
    }

    entry->remote_id = gui_host_open_window(
        entry->title,
        entry->document.bytes ? entry->document.bytes : "v1\n",
        entry->width,
        entry->height
    );
    entry->shown = entry->remote_id >= 0;
    return entry->remote_id;
}

int micro_os_gui_window_update(micro_os_gui_window_t window) {
    gui_window *entry = gui_window_for(window);
    if (!entry || !entry->shown) {
        return -1;
    }

    return gui_host_update_window(
        entry->remote_id,
        entry->document.bytes ? entry->document.bytes : "v1\n"
    );
}

int micro_os_gui_window_close(micro_os_gui_window_t window) {
    gui_window *entry = gui_window_for(window);
    if (!entry || !entry->shown) {
        return -1;
    }

    int result = gui_host_close_window(entry->remote_id);
    entry->shown = 0;
    return result;
}

int micro_os_gui_next_event(micro_os_gui_event *event) {
    if (!event) {
        return -1;
    }

    pthread_mutex_lock(&gui_lock);
    while (gui_event_count == 0) {
        pthread_cond_wait(&gui_event_cond, &gui_lock);
    }

    *event = gui_events[gui_event_read_index];
    gui_event_read_index = (gui_event_read_index + 1) % GUI_MAX_EVENTS;
    gui_event_count--;
    pthread_mutex_unlock(&gui_lock);
    return 1;
}

void micro_os_gui_run(void) {
    micro_os_process_keep_alive();
}

int micro_os_gui_NSApplicationMain(int argc, char **argv) {
    (void)argc;
    (void)argv;
    micro_os_gui_init();
    micro_os_gui_run();
    return 0;
}
