#!/bin/sh

SD=/mnt/sdcard
SETTINGS=$SD/buddy_settings.ini
CONFIG=/userdata/xhr_config.ini
FACTORY_CONFIG=/userdata/xhr_config.ini.factory
HOSTS=/etc/hosts
FACTORY_HOSTS=$SD/hosts.factory
LOGFILE=$SD/logs/buddy_boot.log

# ============================================================
# LOGGING
# ============================================================

mkdir -p $SD/logs

log() {
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "----")
    echo "${TIMESTAMP} [boot] $*" >> "$LOGFILE"
}

log_err() {
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "----")
    echo "${TIMESTAMP} [ERROR] $*" >> "$LOGFILE"
}

log "=========================================="
log "Buddy3D boot script starting"
log "=========================================="

# ============================================================
# HELPERS
# ============================================================

get_setting() {
    VAL=$(grep "^$1=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '\r')
    [ -z "$VAL" ] && VAL="$2"
    echo "$VAL"
}

apply_setting() {
    KEY="$1" ; VAL="$2"
    if grep -q "^${KEY}=" "$CONFIG"; then
        sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$CONFIG"
    elif grep -q '^\[config\]' "$CONFIG"; then
        sed -i "/^\[config\]/a ${KEY}=${VAL}" "$CONFIG"
    fi
}

# ============================================================
# FACTORY BACKUP (first run only)
# ============================================================

if [ ! -f "$FACTORY_CONFIG" ]; then
    log "First run — backing up factory config"
    cp "$CONFIG" "$FACTORY_CONFIG" && cp "$CONFIG" "$SD/xhr_config.ini.factory"
fi
if [ ! -f "$FACTORY_HOSTS" ]; then
    log "First run — backing up factory hosts"
    cp "$HOSTS" "$FACTORY_HOSTS"
fi

# ============================================================
# RESTORE FACTORY CONFIG (clean slate every boot)
# ============================================================

log "Restoring factory config"
cp "$FACTORY_CONFIG" "$CONFIG" || log_err "Failed to restore factory config"
mount -o remount,rw / 2>/dev/null
cp "$FACTORY_HOSTS" "$HOSTS" || log_err "Failed to restore factory hosts"
mount -o remount,ro / 2>/dev/null

# ============================================================
# CREATE DEFAULT SETTINGS (first run only)
# ============================================================

if [ ! -f "$SETTINGS" ]; then
    cat > "$SETTINGS" << 'EOF'
# Buddy3D Camera Settings
# Edit via web UI or manually. Delete this file to reset to factory defaults.

[config]
rtsp_server_mode=2
cloud_enabled=1
video_quality=6
volume=40
ir_mode=1
audio_announcements=1
telnet_enabled=0
timelapse_enabled=0
timelapse_interval=60
ntp_server=pool.ntp.org
EOF
fi

# ============================================================
# APPLY SETTINGS FROM SD CARD
# ============================================================

log "Applying settings from buddy_settings.ini"
CLOUD_ENABLED=0

while IFS='=' read -r key val; do
    key=$(echo "$key" | tr -d '\r' | sed 's/^[ \t]*//')
    val=$(echo "$val" | tr -d '\r' | sed 's/^[ \t]*//')
    [ -z "$key" ] && continue
    case "$key" in
        \#*|"["*) continue ;;
        cloud_enabled) CLOUD_ENABLED="$val" ;;
        timelapse_enabled|timelapse_interval) ;; # handled separately below
        telnet_enabled|web_username|web_password) ;; # handled separately below
        pt_*) ;; # print timelapse settings, handled by the binary
        ip_mode|static_ip|static_mask|static_gateway|static_dns) ;; # handled separately below
        ntp_server) ;; # handled separately below
        audio_announcements) ;; # handled separately below
        *) apply_setting "$key" "$val" ;;
    esac
done < "$SETTINGS"

# ============================================================
# CLOUD BLOCKING
# ============================================================

CLOUD_HOSTS="connect.prusa3d.com camera-signaling.prusa3d.com connect-ota.prusa3d.com timezone.prusa3d.com prusa3d.pool.ntp.org"
if [ "$CLOUD_ENABLED" != "1" ]; then
    log "Cloud disabled — blocking Prusa endpoints in /etc/hosts"
    mount -o remount,rw / 2>/dev/null
    for h in $CLOUD_HOSTS; do
        grep -qF "$h" "$HOSTS" || echo "127.0.0.1 $h" >> "$HOSTS"
    done
    mount -o remount,ro / 2>/dev/null
else
    log "Cloud enabled"
fi

# ============================================================
# NTP CONFIGURATION
# ============================================================

NTP_SRV=$(get_setting ntp_server "pool.ntp.org")
log "NTP server: ${NTP_SRV}"
if [ -n "$NTP_SRV" ]; then
    killall ntpd 2>/dev/null
    # Write config file (this ntpd is full ntpd 4.2.8, not BusyBox — needs -c)
    echo "server ${NTP_SRV} iburst" > /tmp/ntp.conf
    # One-shot sync with -g to allow big initial jump from epoch 0
    ntpd -q -g -c /tmp/ntp.conf 2>/dev/null &
    # Wait for time to sync (up to 15 seconds)
    _ntp_wait=0
    while [ $_ntp_wait -lt 15 ]; do
        [ "$(date +%Y)" -ge 2024 ] && break
        sleep 1
        _ntp_wait=$((_ntp_wait + 1))
    done
    # Start persistent ntpd for ongoing correction
    killall ntpd 2>/dev/null
    ntpd -g -c /tmp/ntp.conf &
    if [ "$(date +%Y)" -ge 2024 ]; then
        log "Time synchronized: $(date '+%Y-%m-%d %H:%M:%S') (PID $!)"
    else
        log_err "Time sync timeout after 15s — timestamps may be incorrect"
    fi
fi

# ============================================================
# AUDIO ANNOUNCEMENTS
# ============================================================

AUDIO_MODE=$(get_setting audio_announcements "1")
log "Audio mode: ${AUDIO_MODE} (0=mute, 1=default, 2=custom)"
case "$AUDIO_MODE" in
    0)
        printf 'RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x00\x00' > /tmp/silent.wav
        MUTED=0
        for f in /oem/usr/etc/*.wav; do
            if [ -f "$f" ]; then
                mount --bind /tmp/silent.wav "$f" 2>/dev/null && MUTED=$((MUTED+1))
            fi
        done
        log "Muted ${MUTED} audio announcement files"
        ;;
    2)
        if [ -d "$SD/sounds" ]; then
            OVERLAID=0
            for f in "$SD/sounds/"*.wav; do
                if [ -f "$f" ]; then
                    BASENAME=$(basename "$f")
                    if [ -f "/oem/usr/etc/$BASENAME" ]; then
                        mount --bind "$f" "/oem/usr/etc/$BASENAME" 2>/dev/null && OVERLAID=$((OVERLAID+1))
                    fi
                fi
            done
            log "Overlaid ${OVERLAID} custom sound files"
        else
            log "No sounds/ directory on SD card — custom mode has no effect"
        fi
        ;;
esac

# ============================================================
# TELNET
# ============================================================

TEL=$(get_setting telnet_enabled "1")
if [ "$TEL" = "1" ]; then
    (while true; do telnetd 2>/dev/null; sleep 10; done) &
    log "Telnet enabled (respawn loop started)"
else
    log "Telnet disabled"
fi

# ============================================================
# WEB SERVER
# ============================================================

sh $SD/web/server.sh &
log "Web server started (PID $!)"

# ============================================================
# PRINT TIMELAPSE LISTENER
# ============================================================

PT_ENABLED=$(get_setting pt_enabled "0")
if [ "$PT_ENABLED" = "1" ]; then
    if [ -f "$SD/bin/print_timelapse" ]; then
        cp "$SD/bin/print_timelapse" /tmp/print_timelapse
        chmod +x /tmp/print_timelapse
        /tmp/print_timelapse &
        log "Print timelapse listener started (PID $!)"
    else
        log_err "Print timelapse enabled but binary not found at $SD/bin/print_timelapse"
    fi
else
    log "Print timelapse disabled"
fi

# ============================================================
# SNAPSHOT CAPTURE (background loop for live preview)
# ============================================================

mkdir -p $SD/snapshots $SD/timelapse

log "Starting snapshot capture"
# Copy snapshot_grabber to /tmp (FAT32 has no execute permissions)
if [ -f "$SD/bin/snapshot_grabber" ]; then
    cp "$SD/bin/snapshot_grabber" /tmp/snapshot_grabber 2>/dev/null && chmod +x /tmp/snapshot_grabber
    log "snapshot_grabber copied to /tmp ($(wc -c < /tmp/snapshot_grabber) bytes)"
fi
(
    sleep 20
    while true; do
        if [ -x /tmp/snapshot_grabber ]; then
            # Kill after 10s to prevent hung process from blocking the loop
            /tmp/snapshot_grabber /tmp/buddy_snapshot.jpg 2>/dev/null &
            SG_PID=$!
            SG_WAIT=0
            while [ $SG_WAIT -lt 10 ] && kill -0 $SG_PID 2>/dev/null; do
                sleep 1
                SG_WAIT=$((SG_WAIT + 1))
            done
            kill -0 $SG_PID 2>/dev/null && kill -9 $SG_PID 2>/dev/null
            wait $SG_PID 2>/dev/null
        fi
        sleep 5
    done
) &

# ============================================================
# TIMELAPSE (background process)
# ============================================================

log "Starting timelapse background process"
(
    sleep 20
    while true; do
        TL_ON=$(grep "^timelapse_enabled=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        TL_INT=$(grep "^timelapse_interval=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        [ -z "$TL_INT" ] && TL_INT=60
        if [ "$TL_ON" = "1" ] && [ -f /tmp/buddy_snapshot.jpg ] && [ "$(wc -c < /tmp/buddy_snapshot.jpg 2>/dev/null)" -gt 1000 ]; then
            DIR="$SD/timelapse/$(date +%Y-%m-%d)"
            mkdir -p "$DIR"
            FNAME="$DIR/$(date +%H-%M-%S).jpg"
            if cp /tmp/buddy_snapshot.jpg "$FNAME" 2>/dev/null; then
                sync
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to save timelapse frame: $FNAME" >> "$LOGFILE"
            fi
        fi
        sleep "${TL_INT:-60}"
    done
) &

# ============================================================
# STORAGE CLEANUP (automatic rotation)
# ============================================================

cleanup_storage() {
    SD_PCT=$(df "$SD" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    [ -z "$SD_PCT" ] && return
    if [ "$SD_PCT" -gt 90 ]; then
        log "Storage at ${SD_PCT}% — running cleanup"
        # Delete oldest log files (keep last 3)
        ls -1 "$SD/logs/" 2>/dev/null | grep '\.log$' | sort | head -n -3 | while read f; do rm -f "$SD/logs/$f"; done
        # Delete oldest snapshots (keep last 20)
        ls -1 "$SD/snapshots/" 2>/dev/null | grep '\.jpg$' | sort | head -n -20 | while read f; do rm -f "$SD/snapshots/$f"; done
        # Delete oldest regular timelapse dirs without videos (keep last 3)
        ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' | sort | head -n -3 | while read d; do
            [ ! -f "$SD/timelapse/$d/timelapse.mp4" ] && rm -rf "$SD/timelapse/$d"
        done
        # Delete oldest print timelapse sessions without videos (keep last 3)
        ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9]*_[0-9]' | sort | head -n -3 | while read d; do
            [ ! -f "$SD/timelapse/$d/timelapse.mp4" ] && rm -rf "$SD/timelapse/$d"
        done
        log "Cleanup complete — now at $(df "$SD" 2>/dev/null | tail -1 | awk '{print $5}') used"
    fi
}

# Run cleanup at boot
cleanup_storage

# Periodic cleanup (every hour)
(
    while true; do
        sleep 3600
        cleanup_storage
    done
) &
log "Storage cleanup monitor started"

# ============================================================
# STATIC IP (applied after WiFi connects)
# ============================================================

IP_MODE=$(get_setting ip_mode "dhcp")
log "IP mode: ${IP_MODE}"
if [ "$IP_MODE" = "static" ]; then
    (
        sleep 20
        S_IP=$(grep "^static_ip=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        S_MASK=$(grep "^static_mask=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        S_GW=$(grep "^static_gateway=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        S_DNS=$(grep "^static_dns=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')
        [ -z "$S_MASK" ] && S_MASK="255.255.255.0"
        if [ -n "$S_IP" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] Applying static IP: ${S_IP}/${S_MASK} gw=${S_GW} dns=${S_DNS}" >> "$LOGFILE"
            killall udhcpc 2>/dev/null
            ifconfig wlan0 "$S_IP" netmask "$S_MASK" 2>/dev/null
            [ -n "$S_GW" ] && route add default gw "$S_GW" 2>/dev/null
            [ -n "$S_DNS" ] && echo "nameserver $S_DNS" > /etc/resolv.conf 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] Static IP applied" >> "$LOGFILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Static IP mode set but no IP address configured" >> "$LOGFILE"
        fi
    ) &
fi

# ============================================================
# WIFI AP FALLBACK MODE
# ============================================================

log "WiFi AP fallback: will check in 40 seconds"
(
    sleep 40
    WLAN_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')
    if [ -z "$WLAN_IP" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] No WiFi connection after 40s — starting AP mode" >> "$LOGFILE"
        killall wpa_supplicant 2>/dev/null
        sleep 2
        ifconfig wlan0 192.168.4.1 netmask 255.255.255.0 up
        cat > /tmp/udhcpd_ap.conf << 'APEOF'
start 192.168.4.100
end 192.168.4.200
interface wlan0
option subnet 255.255.255.0
option router 192.168.4.1
option dns 192.168.4.1
option lease 3600
APEOF
        udhcpd /tmp/udhcpd_ap.conf &
        cat > /tmp/hostapd.conf << 'APEOF'
interface=wlan0
driver=nl80211
ssid=Buddy3D-Setup
channel=6
hw_mode=g
auth_algs=1
wpa=0
APEOF
        if which hostapd >/dev/null 2>&1; then
            hostapd /tmp/hostapd.conf &
            echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] AP mode started via hostapd (SSID: Buddy3D-Setup)" >> "$LOGFILE"
        else
            cat > /tmp/wpa_ap.conf << 'APEOF2'
network={
    ssid="Buddy3D-Setup"
    mode=2
    key_mgmt=NONE
    frequency=2437
}
APEOF2
            wpa_supplicant -Dnl80211 -iwlan0 -c/tmp/wpa_ap.conf -B 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] AP mode started via wpa_supplicant (SSID: Buddy3D-Setup)" >> "$LOGFILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] WiFi connected: ${WLAN_IP} — AP fallback not needed" >> "$LOGFILE"
    fi
) &

# ============================================================
# START CAMERA APP
# ============================================================

log "Starting lp_app (main camera application)"
sync
lp_app --noshell --log2file $SD/logs
log_err "lp_app exited unexpectedly (exit code: $?)"
