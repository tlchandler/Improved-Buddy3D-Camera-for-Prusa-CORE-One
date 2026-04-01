/*
 * print_timelapse — UDP syslog listener for Prusa Core One print timelapse
 *
 * Listens for is_printing and pos_z metrics from the printer,
 * detects print start/end, and captures timelapse snapshots.
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
#include <math.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

/* ============================================================
 * Configuration
 * ============================================================ */

#define CONFIG_FILE      "/mnt/sdcard/buddy_settings.ini"
#define SNAPSHOT_SRC     "/tmp/buddy_snapshot.jpg"
#define STATUS_FILE      "/tmp/print_timelapse_status"
#define LOG_FILE         "/mnt/sdcard/logs/print_timelapse.log"
#define DEFAULT_PORT     8514
#define BUF_SIZE         4096
#define MAX_PATH_LEN     512

typedef enum { IDLE, PRINTING, FINALIZING } PrintState;
typedef enum { MODE_LAYER, MODE_INTERVAL } CaptureMode;

static struct {
    int enabled;
    int port;
    CaptureMode capture_mode;
    float layer_height;
    float debounce_seconds;
    float interval_seconds;
    int confirmation_count;
    int stale_timeout;
    char output_dir[MAX_PATH_LEN];
} config;

static struct {
    PrintState state;
    char print_id[64];
    int frame_counter;
    float last_snapshot_z;
    float last_z_seen;
    time_t last_z_change_time;
    time_t last_interval_snap;
    time_t last_packet_time;
    time_t print_start_time;
    int consecutive_printing;
    int consecutive_idle;
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
    config.layer_height = 0.2f;
    config.debounce_seconds = 2.0f;
    config.interval_seconds = 10.0f;
    config.confirmation_count = 2;
    config.stale_timeout = 120;
    snprintf(config.output_dir, sizeof(config.output_dir), "/mnt/sdcard/timelapse");
    if ((v = get_config_value("pt_enabled")))         config.enabled = atoi(v);
    if ((v = get_config_value("pt_port")))             config.port = atoi(v);
    if ((v = get_config_value("pt_capture_mode")))     config.capture_mode = (strcmp(v, "interval") == 0) ? MODE_INTERVAL : MODE_LAYER;
    if ((v = get_config_value("pt_layer_height")))     config.layer_height = atof(v);
    if ((v = get_config_value("pt_debounce_seconds"))) config.debounce_seconds = atof(v);
    if ((v = get_config_value("pt_interval_seconds"))) config.interval_seconds = atof(v);
    if ((v = get_config_value("pt_confirmation_count"))) config.confirmation_count = atoi(v);
    if ((v = get_config_value("pt_stale_timeout")))    config.stale_timeout = atoi(v);
    if ((v = get_config_value("pt_output_dir")))       strncpy(config.output_dir, v, sizeof(config.output_dir) - 1);
    /* Sanity bounds */
    if (config.port < 1 || config.port > 65535) config.port = DEFAULT_PORT;
    if (config.layer_height < 0.01f) config.layer_height = 0.2f;
    if (config.debounce_seconds < 0.0f) config.debounce_seconds = 2.0f;
    if (config.interval_seconds < 1.0f) config.interval_seconds = 10.0f;
    if (config.confirmation_count < 1) config.confirmation_count = 2;
    if (config.stale_timeout < 10) config.stale_timeout = 120;
}

/* ============================================================
 * Status File
 * ============================================================ */

static void write_status(void) {
    FILE *fp = fopen(STATUS_FILE, "w");
    if (!fp) return;

    const char *state_str = "IDLE";
    if (state.state == PRINTING) state_str = "PRINTING";
    else if (state.state == FINALIZING) state_str = "FINALIZING";

    fprintf(fp, "state=%s\n", state_str);
    fprintf(fp, "print_id=%s\n", state.print_id);
    fprintf(fp, "frame_count=%d\n", state.frame_counter);
    fprintf(fp, "last_z=%.2f\n", state.last_z_seen);

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

    fclose(fp);
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

static void take_snapshot(float z) {
    char dir[MAX_PATH_LEN];
    char filepath[MAX_PATH_LEN];

    snprintf(dir, sizeof(dir), "%s/%s", config.output_dir, state.print_id);
    mkdir_p(dir);

    snprintf(filepath, sizeof(filepath), "%s/frame_%05d.jpg", dir, state.frame_counter);

    /* Copy snapshot source to session directory */
    FILE *src = fopen(SNAPSHOT_SRC, "rb");
    if (!src) {
        LOG_WARN("Cannot open snapshot source %s", SNAPSHOT_SRC);
        return;
    }

    FILE *dst = fopen(filepath, "wb");
    if (!dst) {
        fclose(src);
        LOG_WARN("Cannot create frame file %s", filepath);
        return;
    }

    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), src)) > 0) {
        fwrite(buf, 1, n, dst);
    }

    fclose(src);
    fclose(dst);

    LOG_INFO("Frame %d at Z=%.2fmm -> %s", state.frame_counter, z, filepath);
    state.frame_counter++;
    state.last_snapshot_z = z;
    write_status();
}

/* ============================================================
 * Print Session Management
 * ============================================================ */

static void start_print_session(void) {
    state.state = PRINTING;
    state.print_start_time = time(NULL);

    struct tm *t = localtime(&state.print_start_time);
    strftime(state.print_id, sizeof(state.print_id), "%Y%m%d_%H%M%S", t);

    state.frame_counter = 0;
    state.last_snapshot_z = -1.0f;
    state.last_z_seen = -1.0f;
    state.last_interval_snap = time(NULL);

    char dir[MAX_PATH_LEN];
    snprintf(dir, sizeof(dir), "%s/%s", config.output_dir, state.print_id);
    mkdir_p(dir);

    LOG_INFO("Print started — session %s", state.print_id);
    write_status();
}

static void end_print_session(void) {
    int frames = state.frame_counter;
    char session_id[64];
    strncpy(session_id, state.print_id, sizeof(session_id));
    session_id[sizeof(session_id) - 1] = '\0';

    LOG_INFO("Print ended — session %s, %d frames captured", session_id, frames);
    write_status();

    /* Reset to idle */
    state.state = IDLE;
    state.print_id[0] = '\0';
    state.print_start_time = 0;
    state.consecutive_printing = 0;
    state.consecutive_idle = 0;

    write_status();
}

/* ============================================================
 * Metric Handlers
 * ============================================================ */

static void handle_print_state(int is_printing) {
    if (is_printing) {
        state.consecutive_printing++;
        state.consecutive_idle = 0;

        if (state.state == IDLE && state.consecutive_printing >= config.confirmation_count) {
            start_print_session();
        }
    } else {
        state.consecutive_idle++;
        state.consecutive_printing = 0;

        if (state.state == PRINTING && state.consecutive_idle >= config.confirmation_count) {
            end_print_session();
        }
    }
}

static void handle_z_update(float z) {
    if (state.state != PRINTING) return;

    time_t now = time(NULL);

    if (fabsf(z - state.last_z_seen) > 0.001f) {
        state.last_z_change_time = now;
        state.last_z_seen = z;
    }

    /* If Z drops well below last snapshot (e.g. calibration probe → first layer),
       reset so we don't get stuck waiting for Z to exceed the probe height */
    if (state.last_snapshot_z > 0 && z < state.last_snapshot_z * 0.5f && z < 10.0f) {
        LOG_INFO("Z dropped from %.2f to %.2f — resetting layer tracking", state.last_snapshot_z, z);
        state.last_snapshot_z = -1.0f;
    }

    if (config.capture_mode == MODE_LAYER) {
        /* Layer mode: snapshot when Z advances by layer_height and is stable */
        int z_advanced = (z >= state.last_snapshot_z + config.layer_height - 0.01f);
        int z_stable = (difftime(now, state.last_z_change_time) >= config.debounce_seconds);
        int z_positive = (z > 0.0f);

        if (z_advanced && z_stable && z_positive) {
            take_snapshot(z);
        }
    } else {
        /* Interval mode: snapshot every N seconds */
        if (difftime(now, state.last_interval_snap) >= config.interval_seconds) {
            take_snapshot(state.last_z_seen);
            state.last_interval_snap = now;
        }
    }
}

/* ============================================================
 * Packet Parser
 * ============================================================ */

static void process_packet(const char *data, int len) {
    state.last_packet_time = time(NULL);

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

            /* Check for is_printing metric */
            char *match = strstr(line, "is_printing v=");
            if (match) {
                char val = match[14]; /* character after "is_printing v=" */
                if (val == '0' || val == '1') {
                    handle_print_state(val == '1');
                }
                goto next_line;
            }

            /* Check for pos_z metric */
            match = strstr(line, "pos_z v=");
            if (match) {
                float z = atof(match + 8);
                handle_z_update(z);
            }
        }

next_line:
        p = eol + 1;
    }
}

/* ============================================================
 * Stale Session Check
 * ============================================================ */

static void check_stale_session(void) {
    if (state.state != PRINTING) return;
    if (state.last_packet_time == 0) return;

    time_t now = time(NULL);
    if (difftime(now, state.last_packet_time) > config.stale_timeout) {
        LOG_WARN("No data for %ds — assuming print ended", config.stale_timeout);
        end_print_session();
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

int main(int argc, char *argv[]) {
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

    LOG_INFO("Starting print timelapse listener on port %d", config.port);
    LOG_INFO("Capture mode: %s, layer_height=%.2f, interval=%.1fs",
             config.capture_mode == MODE_LAYER ? "layer" : "interval",
             config.layer_height, config.interval_seconds);

    /* Initialize state */
    memset(&state, 0, sizeof(state));
    state.state = IDLE;
    state.last_snapshot_z = -1.0f;
    state.last_z_seen = -1.0f;
    state.last_z_change_time = time(NULL);
    state.last_interval_snap = time(NULL);
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

    /* Set socket timeout for periodic stale checks */
    struct timeval tv;
    tv.tv_sec = 10;
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

        /* Periodic stale session check */
        check_stale_session();
    }

    LOG_INFO("Shutting down");
    close(sock);
    unlink(STATUS_FILE);
    if (logfp) fclose(logfp);

    return 0;
}
