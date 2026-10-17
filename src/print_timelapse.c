/*
 * print_timelapse — UDP syslog listener for Prusa Core One print timelapse
 *
 * Listens for explicit start, layer, and completion markers in the printer's
 * gcode metric and captures a fresh frame for layer/completion markers.
 *
 * Runs on Buddy3D camera (Rockchip RV1103, ARMv7, BusyBox Linux).
 * Cross-compile: arm-linux-gnueabihf-gcc -static -o print_timelapse print_timelapse.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

/* ============================================================
 * Configuration
 * ============================================================ */

#ifndef CONFIG_FILE
#define CONFIG_FILE      "/mnt/sdcard/buddy_settings.ini"
#endif
#ifndef SNAPSHOT_GRABBER
#define SNAPSHOT_GRABBER "/tmp/snapshot_grabber"
#endif
#ifndef SNAPSHOT_FRESH
#define SNAPSHOT_FRESH   "/tmp/print_timelapse_capture.jpg"
#endif
#ifndef SNAPSHOT_PREVIEW
#define SNAPSHOT_PREVIEW "/tmp/buddy_snapshot.jpg"
#endif
#ifndef SNAPSHOT_LOCK
#define SNAPSHOT_LOCK    "/tmp/buddy_snapshot.lock"
#endif
#ifndef STATUS_FILE
#define STATUS_FILE      "/tmp/print_timelapse_status"
#endif
#ifndef STATUS_TMP
#define STATUS_TMP       "/tmp/print_timelapse_status.tmp"
#endif
#ifndef LOG_FILE
#define LOG_FILE         "/mnt/sdcard/logs/print_timelapse.log"
#endif
#ifndef DEFAULT_PORT
#define DEFAULT_PORT     8514
#endif
#define BUF_SIZE         4096
#define MAX_PATH_LEN     512
#define SNAPSHOT_MIN_SIZE       1000
#define SNAPSHOT_LOCK_WAIT_MS    500
#define SNAPSHOT_TIMEOUT_MS     3500
#define SNAPSHOT_POLL_MS         100
#define SNAPSHOT_LOCK_STALE_SECS  15
#define CAPTURE_RETRY_SECS          2
#define START_MARKER       "M118 BUDDY_TIMELAPSE_START"
#define LAYER_MARKER       "M118 BUDDY_TIMELAPSE_LAYER"
#define COMPLETE_MARKER    "M118 BUDDY_TIMELAPSE_COMPLETE"
#define START_DEDUPE_SECS  2
#define MAX_PRINT_DESCRIPTION 40

typedef enum { IDLE, PRINTING, FINALIZING } PrintState;
typedef enum { MODE_LAYER, MODE_INTERVAL } CaptureMode;

static struct {
    int enabled;
    int port;
    CaptureMode capture_mode;
    float interval_seconds;
    char output_dir[MAX_PATH_LEN];
} config;

static struct {
    PrintState state;
    char print_id[64];
    int frame_counter;
    time_t last_interval_snap;
    time_t last_capture_attempt;
    time_t last_frame_time;
    time_t last_status_write;
    time_t last_start_marker_time;
    time_t print_start_time;
    long last_layer_id;
    int have_last_layer_id;
    char capture_status[32];
} state;

static volatile int running = 1;
static volatile int reload_config = 0;
static FILE *logfp = NULL;

/* ============================================================
 * Logging
 * ============================================================ */

static void log_msg(const char *level, const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char timebuf[32];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", t);

    if (logfp) {
        va_list ap;
        fprintf(logfp, "%s [%s] ", timebuf, level);
        va_start(ap, fmt);
        vfprintf(logfp, fmt, ap);
        va_end(ap);
        fprintf(logfp, "\n");
        fflush(logfp);
    }
}

#define LOG_INFO(...)  log_msg("INFO", __VA_ARGS__)
#define LOG_WARN(...)  log_msg("WARN", __VA_ARGS__)

/* ============================================================
 * Configuration Parser
 * ============================================================ */

static char *get_config_value(const char *key) {
    static char val[256];
    FILE *fp = fopen(CONFIG_FILE, "r");
    if (!fp) return NULL;

    char line[512];
    size_t keylen = strlen(key);
    val[0] = '\0';

    while (fgets(line, sizeof(line), fp)) {
        /* Skip comments and section headers */
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '[' || *p == '\n') continue;

        if (strncmp(p, key, keylen) == 0 && p[keylen] == '=') {
            char *v = p + keylen + 1;
            /* Trim trailing whitespace/newline */
            char *end = v + strlen(v) - 1;
            while (end > v && (*end == '\n' || *end == '\r' || *end == ' ')) *end-- = '\0';
            strncpy(val, v, sizeof(val) - 1);
            val[sizeof(val) - 1] = '\0';
            fclose(fp);
            return val;
        }
    }
    fclose(fp);
    return NULL;
}

static void load_config(void) {
    char *v;

    config.enabled = 1;
    config.port = DEFAULT_PORT;
    config.capture_mode = MODE_LAYER;
    config.interval_seconds = 10.0f;
    snprintf(config.output_dir, sizeof(config.output_dir), "/mnt/sdcard/timelapse");
    if ((v = get_config_value("pt_enabled")))         config.enabled = atoi(v);
    if ((v = get_config_value("pt_port")))             config.port = atoi(v);
    if ((v = get_config_value("pt_capture_mode")))     config.capture_mode = (strcmp(v, "interval") == 0) ? MODE_INTERVAL : MODE_LAYER;
    if ((v = get_config_value("pt_interval_seconds"))) config.interval_seconds = atof(v);
    if ((v = get_config_value("pt_output_dir")))       strncpy(config.output_dir, v, sizeof(config.output_dir) - 1);
    /* Sanity bounds */
    if (config.port < 1 || config.port > 65535) config.port = DEFAULT_PORT;
    if (config.interval_seconds < 1.0f) config.interval_seconds = 10.0f;
}

/* ============================================================
 * Status File
 * ============================================================ */

static void write_status(void) {
    FILE *fp = fopen(STATUS_TMP, "w");
    if (!fp) return;

    const char *state_str = "IDLE";
    if (state.state == PRINTING) state_str = "PRINTING";
    else if (state.state == FINALIZING) state_str = "FINALIZING";

    fprintf(fp, "state=%s\n", state_str);
    fprintf(fp, "print_id=%s\n", state.print_id);
    fprintf(fp, "frame_count=%d\n", state.frame_counter);
    fprintf(fp, "last_layer=%ld\n",
            state.have_last_layer_id ? state.last_layer_id : -1L);

    if (state.print_start_time > 0) {
        time_t elapsed = time(NULL) - state.print_start_time;
        fprintf(fp, "elapsed_seconds=%ld\n", (long)elapsed);
    } else {
        fprintf(fp, "elapsed_seconds=0\n");
    }

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char timebuf[32];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", t);
    fprintf(fp, "last_update=%s\n", timebuf);

    const char *mode_str = (config.capture_mode == MODE_INTERVAL) ? "interval" : "layer";
    fprintf(fp, "capture_mode=%s\n", mode_str);

    const char *phase = "idle";
    if (state.state == PRINTING) {
        phase = (config.capture_mode == MODE_INTERVAL) ?
                "interval" : "waiting_for_layer";
    } else if (state.state == FINALIZING) {
        phase = "final_capture";
    }
    fprintf(fp, "phase=%s\n", phase);
    fprintf(fp, "capture_status=%s\n", state.capture_status);
    if (state.last_frame_time > 0) {
        fprintf(fp, "last_frame_age_seconds=%ld\n",
                (long)(time(NULL) - state.last_frame_time));
    } else {
        fprintf(fp, "last_frame_age_seconds=-1\n");
    }

    if (fclose(fp) == 0) {
        rename(STATUS_TMP, STATUS_FILE);
        state.last_status_write = time(NULL);
    } else {
        unlink(STATUS_TMP);
    }
}

/* ============================================================
 * Directory Helpers
 * ============================================================ */

static void mkdir_p(const char *path) {
    char tmp[MAX_PATH_LEN];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';

    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

/* ============================================================
 * Snapshot Capture
 * ============================================================ */

static void sleep_millis(int milliseconds) {
    struct timespec delay;
    delay.tv_sec = milliseconds / 1000;
    delay.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
    nanosleep(&delay, NULL);
}

static int valid_snapshot(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode) &&
           st.st_size > SNAPSHOT_MIN_SIZE;
}

static int acquire_snapshot_lock(void) {
    int waited = 0;

    while (waited < SNAPSHOT_LOCK_WAIT_MS) {
        if (mkdir(SNAPSHOT_LOCK, 0700) == 0) return 0;
        if (errno != EEXIST) return -1;

        /* Recover a lock left behind if a capture process was killed. */
        struct stat st;
        if (stat(SNAPSHOT_LOCK, &st) == 0 &&
            difftime(time(NULL), st.st_mtime) > SNAPSHOT_LOCK_STALE_SECS) {
            if (rmdir(SNAPSHOT_LOCK) == 0) {
                LOG_WARN("Removed stale snapshot lock");
                continue;
            }
        }

        sleep_millis(SNAPSHOT_POLL_MS);
        waited += SNAPSHOT_POLL_MS;
    }

    return -1;
}

static int grab_fresh_snapshot(void) {
    if (access(SNAPSHOT_GRABBER, X_OK) != 0) {
        strncpy(state.capture_status, "grabber_missing",
                sizeof(state.capture_status) - 1);
        return -1;
    }

    if (acquire_snapshot_lock() != 0) {
        strncpy(state.capture_status, "capture_busy",
                sizeof(state.capture_status) - 1);
        return -1;
    }

    unlink(SNAPSHOT_FRESH);

    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "w", stdout);
        freopen("/dev/null", "w", stderr);
        setenv("LD_LIBRARY_PATH", "/tmp", 1);
        execl(SNAPSHOT_GRABBER, SNAPSHOT_GRABBER, SNAPSHOT_FRESH, (char *)NULL);
        _exit(127);
    }

    if (pid < 0) {
        rmdir(SNAPSHOT_LOCK);
        strncpy(state.capture_status, "fork_failed",
                sizeof(state.capture_status) - 1);
        return -1;
    }

    int status = 0;
    int waited = 0;
    pid_t result = 0;
    while (waited < SNAPSHOT_TIMEOUT_MS) {
        result = waitpid(pid, &status, WNOHANG);
        if (result == pid || result < 0) break;
        sleep_millis(SNAPSHOT_POLL_MS);
        waited += SNAPSHOT_POLL_MS;
    }

    if (result == 0) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        strncpy(state.capture_status, "capture_timeout",
                sizeof(state.capture_status) - 1);
    } else if (result < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        strncpy(state.capture_status, "grabber_failed",
                sizeof(state.capture_status) - 1);
    }

    rmdir(SNAPSHOT_LOCK);

    if (result != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        !valid_snapshot(SNAPSHOT_FRESH)) {
        if (strcmp(state.capture_status, "capture_timeout") != 0 &&
            strcmp(state.capture_status, "grabber_failed") != 0) {
            strncpy(state.capture_status, "invalid_snapshot",
                    sizeof(state.capture_status) - 1);
        }
        return -1;
    }

    return 0;
}

static int copy_snapshot(const char *source, const char *destination) {
    char tmp_path[MAX_PATH_LEN + 8];
    if (snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", destination) >=
        (int)sizeof(tmp_path)) {
        return -1;
    }

    FILE *src = fopen(source, "rb");
    if (!src) return -1;

    FILE *dst = fopen(tmp_path, "wb");
    if (!dst) {
        fclose(src);
        return -1;
    }

    int ok = 1;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
        if (fwrite(buf, 1, n, dst) != n) {
            ok = 0;
            break;
        }
    }
    if (ferror(src)) ok = 0;
    if (fclose(src) != 0) ok = 0;
    if (fclose(dst) != 0) ok = 0;

    if (!ok || rename(tmp_path, destination) != 0) {
        unlink(tmp_path);
        return -1;
    }

    return 0;
}

static int take_snapshot(long layer_id, int has_layer_id) {
    char dir[MAX_PATH_LEN];
    char filepath[MAX_PATH_LEN];

    snprintf(dir, sizeof(dir), "%s/%s", config.output_dir, state.print_id);
    mkdir_p(dir);

    snprintf(filepath, sizeof(filepath), "%s/frame_%05d.jpg", dir, state.frame_counter);

    state.last_capture_attempt = time(NULL);

    if (grab_fresh_snapshot() != 0) {
        LOG_WARN("Fresh capture failed (%s); frame skipped to avoid saving a stale image",
                 state.capture_status);
        write_status();
        return -1;
    }
    strncpy(state.capture_status, "fresh",
            sizeof(state.capture_status) - 1);

    if (copy_snapshot(SNAPSHOT_FRESH, filepath) != 0) {
        strncpy(state.capture_status, "write_failed",
                sizeof(state.capture_status) - 1);
        LOG_WARN("Cannot create frame file %s", filepath);
        write_status();
        return -1;
    }

    if (has_layer_id) {
        LOG_INFO("Frame %d for layer %ld (%s) -> %s", state.frame_counter,
                 layer_id, state.capture_status, filepath);
    } else {
        LOG_INFO("Frame %d from interval trigger (%s) -> %s",
                 state.frame_counter, state.capture_status, filepath);
    }
    state.frame_counter++;
    state.last_frame_time = time(NULL);
    /* Keep the web preview current while its background grabber yields the
       camera channel to print captures. A preview-copy failure is non-fatal. */
    copy_snapshot(SNAPSHOT_FRESH, SNAPSHOT_PREVIEW);
    write_status();
    return 0;
}

/* ============================================================
 * Print Session Management
 * ============================================================ */

static void extract_print_description(const char *command, char *description,
                                      size_t description_size) {
    const char *marker = strstr(command, START_MARKER);
    if (description_size == 0) return;
    description[0] = '\0';
    if (!marker) return;

    const char *source = marker + strlen(START_MARKER);
    while (*source == ' ' || *source == ':' || *source == '=') source++;

    /* An unexpanded placeholder is less useful than the timestamp-only
       fallback and should not become part of a directory name. */
    static const char unresolved[] = "{input_filename_base}";
    if (strncmp(source, unresolved, sizeof(unresolved) - 1) == 0) {
        const char *after = source + sizeof(unresolved) - 1;
        while (*after == ' ' || *after == '\t') after++;
        if (*after == '\0' || *after == '"' || *after == '\r' ||
            *after == '\n') {
            return;
        }
    }

    size_t used = 0;
    int separator_pending = 0;
    while (*source && *source != '"' && *source != '\r' && *source != '\n') {
        unsigned char ch = (unsigned char)*source++;
        int alphanumeric = ((ch >= 'A' && ch <= 'Z') ||
                            (ch >= 'a' && ch <= 'z') ||
                            (ch >= '0' && ch <= '9'));
        if (!alphanumeric) {
            if (used > 0) separator_pending = 1;
            continue;
        }

        if (separator_pending) {
            /* Leave room for both the separator and the next character. */
            if (used + 2 >= description_size) break;
            description[used++] = '-';
            separator_pending = 0;
        } else if (used + 1 >= description_size) {
            break;
        }
        description[used++] = (char)ch;
    }
    description[used] = '\0';
}

static void choose_print_id(time_t start_time, const char *description) {
    struct tm *t = localtime(&start_time);
    char base_id[32];
    char descriptive_id[64];
    char candidate[64];
    char path[MAX_PATH_LEN];

    strftime(base_id, sizeof(base_id), "%Y%m%d_%H%M%S", t);
    if (description[0]) {
        snprintf(descriptive_id, sizeof(descriptive_id), "%s_%s", base_id,
                 description);
    } else {
        snprintf(descriptive_id, sizeof(descriptive_id), "%s", base_id);
    }

    for (int suffix = 0; suffix < 1000; suffix++) {
        if (suffix == 0) {
            snprintf(candidate, sizeof(candidate), "%s", descriptive_id);
        } else {
            snprintf(candidate, sizeof(candidate), "%s_%02d", descriptive_id,
                     suffix);
        }
        snprintf(path, sizeof(path), "%s/%s", config.output_dir, candidate);
        if (access(path, F_OK) != 0) {
            snprintf(state.print_id, sizeof(state.print_id), "%s", candidate);
            return;
        }
    }

    snprintf(state.print_id, sizeof(state.print_id), "%s_%ld", base_id,
             (long)start_time);
}

static void start_print_session(const char *description) {
    state.state = PRINTING;
    state.print_start_time = time(NULL);
    choose_print_id(state.print_start_time, description);

    state.frame_counter = 0;
    state.last_interval_snap = time(NULL);
    state.last_capture_attempt = 0;
    state.last_frame_time = 0;
    state.last_layer_id = -1;
    state.have_last_layer_id = 0;
    strncpy(state.capture_status, "waiting",
            sizeof(state.capture_status) - 1);

    char dir[MAX_PATH_LEN];
    snprintf(dir, sizeof(dir), "%s/%s", config.output_dir, state.print_id);
    mkdir_p(dir);

    LOG_INFO("Print started — session %s", state.print_id);
    write_status();
}

static void end_print_session(const char *reason) {
    int frames = state.frame_counter;
    char session_id[64];
    strncpy(session_id, state.print_id, sizeof(session_id));
    session_id[sizeof(session_id) - 1] = '\0';

    LOG_INFO("Print ended — session %s, %d frames captured (%s)",
             session_id, frames, reason);
    write_status();

    /* Reset to idle */
    state.state = IDLE;
    state.print_id[0] = '\0';
    state.print_start_time = 0;

    write_status();
}

/* ============================================================
 * Metric Handlers
 * ============================================================ */

static void handle_start_marker(const char *command) {
    if (!strstr(command, START_MARKER)) return;

    char description[MAX_PRINT_DESCRIPTION + 1];
    extract_print_description(command, description, sizeof(description));

    time_t now = time(NULL);
    if (state.last_start_marker_time > 0 &&
        difftime(now, state.last_start_marker_time) < START_DEDUPE_SECS) {
        return;
    }
    state.last_start_marker_time = now;

    /* A start marker always establishes a new run. This deliberately closes
       an unterminated session left by a cancelled or interrupted print. */
    if (state.state != IDLE) {
        LOG_WARN("New start marker supersedes active session %s", state.print_id);
        end_print_session("superseded by new start marker");
    }
    start_print_session(description);
}

static void handle_layer_marker(const char *command) {
    if (config.capture_mode != MODE_LAYER) return;

    const char *marker = strstr(command, LAYER_MARKER);
    if (!marker) return;

    const char *suffix = marker + strlen(LAYER_MARKER);
    while (*suffix == ' ' || *suffix == ':' || *suffix == '=') suffix++;

    char *number_end = NULL;
    errno = 0;
    long layer_id = strtol(suffix, &number_end, 10);
    int has_layer_id = (number_end != suffix && errno == 0 && layer_id >= 0);

    /* START is the only event allowed to open a session. Ignoring an orphaned
       layer marker prevents delayed UDP traffic from reviving an old print. */
    if (state.state != PRINTING) {
        LOG_WARN("Ignoring layer marker without an active print session");
        return;
    }

    if (has_layer_id && state.have_last_layer_id &&
        layer_id == state.last_layer_id) {
        return;
    }
    /* Mark the event before blocking on capture. Redundant marker packets are
       then safe: they recover UDP loss without triggering a second shot after
       the printer has advanced beyond the marker point. */
    if (has_layer_id) {
        LOG_INFO("Layer marker received for layer %ld", layer_id);
        state.last_layer_id = layer_id;
        state.have_last_layer_id = 1;
    } else {
        LOG_INFO("Layer marker received without an ID");
    }
    strncpy(state.capture_status, "capturing",
            sizeof(state.capture_status) - 1);
    write_status();

    take_snapshot(layer_id, has_layer_id);
}

static void handle_complete_marker(const char *command) {
    const char *marker = strstr(command, COMPLETE_MARKER);
    if (!marker || state.state == IDLE) return;

    const char *suffix = marker + strlen(COMPLETE_MARKER);
    while (*suffix == ' ' || *suffix == ':' || *suffix == '=') suffix++;

    char *number_end = NULL;
    errno = 0;
    long layer_id = strtol(suffix, &number_end, 10);
    int has_layer_id = (number_end != suffix && errno == 0 && layer_id >= 0);

    if (has_layer_id) {
        state.last_layer_id = layer_id;
        state.have_last_layer_id = 1;
    }

    LOG_INFO("Completion marker received%s", has_layer_id ?
             " with final layer ID" : "");
    state.state = FINALIZING;
    strncpy(state.capture_status, "capturing_final",
            sizeof(state.capture_status) - 1);
    write_status();

    /* Capture the completed model while the end G-code keeps the head parked.
       Completion still closes the session if the fresh capture fails. */
    take_snapshot(layer_id, has_layer_id);
    end_print_session("completion marker");
}

static void check_interval_capture(void) {
    if (state.state != PRINTING || config.capture_mode != MODE_INTERVAL) return;

    time_t now = time(NULL);
    int interval_due = (difftime(now, state.last_interval_snap) >=
                        config.interval_seconds);
    int retry_ready = (state.last_capture_attempt == 0 ||
                       difftime(now, state.last_capture_attempt) >=
                       CAPTURE_RETRY_SECS);

    if (interval_due && retry_ready && take_snapshot(-1, 0) == 0) {
        state.last_interval_snap = time(NULL);
    }
}

/* ============================================================
 * Packet Parser
 * ============================================================ */

static void process_packet(const char *data, int len) {
    /* Split into lines and process each */
    const char *p = data;
    const char *end = data + len;

    while (p < end) {
        /* Find end of line */
        const char *eol = p;
        while (eol < end && *eol != '\n') eol++;

        int linelen = eol - p;
        if (linelen > 0 && linelen < 256) {
            char line[256];
            memcpy(line, p, linelen);
            line[linelen] = '\0';

            /* The printer records each command as gcode v="..." before
               dispatch. Session boundaries and captures use explicit M118
               markers; unrelated metrics are intentionally ignored. */
            char *match = strstr(line, "gcode v=\"");
            if (match) {
                const char *command = match + 9;
                handle_start_marker(command);
                handle_complete_marker(command);
                handle_layer_marker(command);
            }
        }

        p = eol + 1;
    }
}

/* ============================================================
 * Signal Handlers
 * ============================================================ */

static void sig_handler(int sig) {
    if (sig == SIGTERM || sig == SIGINT) {
        running = 0;
    } else if (sig == SIGHUP) {
        reload_config = 1;
    }
}

/* ============================================================
 * Main
 * ============================================================ */

int main(void) {
    /* Open log file */
    mkdir_p("/mnt/sdcard/logs");
    logfp = fopen(LOG_FILE, "a");

    /* Load configuration */
    load_config();

    if (!config.enabled) {
        LOG_INFO("Print timelapse disabled in config, exiting");
        if (logfp) fclose(logfp);
        return 0;
    }

    LOG_INFO("Starting marker-driven print timelapse listener on port %d",
             config.port);
    LOG_INFO("Capture mode: %s, interval=%.1fs",
             config.capture_mode == MODE_LAYER ? "layer" : "interval",
             config.interval_seconds);

    /* Initialize state */
    memset(&state, 0, sizeof(state));
    state.state = IDLE;
    state.last_layer_id = -1;
    state.last_interval_snap = time(NULL);
    strncpy(state.capture_status, "idle", sizeof(state.capture_status) - 1);
    write_status();

    /* Set up signals */
    signal(SIGTERM, sig_handler);
    signal(SIGINT, sig_handler);
    signal(SIGHUP, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    /* Create UDP socket */
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        LOG_WARN("Failed to create socket: %s", strerror(errno));
        if (logfp) fclose(logfp);
        return 1;
    }

    /* Allow address reuse */
    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(config.port);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOG_WARN("Failed to bind port %d: %s", config.port, strerror(errno));
        close(sock);
        if (logfp) fclose(logfp);
        return 1;
    }

    LOG_INFO("Listening on UDP port %d — waiting for printer metrics", config.port);

    /* A short timeout keeps interval captures and web status independent of
       metric packet frequency. */
    struct timeval tv;
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buf[BUF_SIZE];

    while (running) {
        /* Check for config reload */
        if (reload_config) {
            LOG_INFO("Reloading configuration");
            load_config();
            reload_config = 0;
        }

        /* Receive packet */
        ssize_t n = recvfrom(sock, buf, sizeof(buf) - 1, 0, NULL, NULL);
        if (n > 0) {
            buf[n] = '\0';
            process_packet(buf, n);
        } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
            if (running) {
                LOG_WARN("recvfrom error: %s", strerror(errno));
            }
        }

        check_interval_capture();
        if (state.state != IDLE &&
            difftime(time(NULL), state.last_status_write) >= 5.0) {
            write_status();
        }
    }

    LOG_INFO("Shutting down");
    close(sock);
    unlink(STATUS_FILE);
    if (logfp) fclose(logfp);

    return 0;
}
