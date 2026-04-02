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
if [ ! -f "$FACTORY_HOSTS" ] || grep -q "connect.prusa3d.com" "$FACTORY_HOSTS" 2>/dev/null; then
    log "Backing up clean factory hosts"
    # Generate a clean hosts file (the backup may have been taken after we blocked hosts)
    printf "127.0.0.1\tlocalhost\n127.0.1.1\tRockchip\n" > "$FACTORY_HOSTS"
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
        ota_updates_enabled) ;; # handled separately below
        timelapse_enabled|timelapse_interval) ;; # handled separately below
        telnet_enabled|web_username|web_password) ;; # handled separately below
        pt_*) ;; # print timelapse settings, handled by the binary
        ip_mode|static_ip|static_mask|static_gateway|static_dns) ;; # handled separately below
        ntp_server) ;; # handled separately below
        audio_announcements) ;; # handled separately below
        wifi_ssid|wifi_password) ;; # handled separately below
        prusa_token|scheduled_reboot) ;; # handled separately below
        *) apply_setting "$key" "$val" ;;
    esac
done < "$SETTINGS"

# ============================================================
# WIFI CREDENTIALS (apply saved SSID/password to wpa_supplicant)
# ============================================================

WIFI_SSID=$(get_setting wifi_ssid "")
WIFI_PASS=$(get_setting wifi_password "")
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
    log "Applying saved WiFi credentials for SSID: $WIFI_SSID"
    WPA_CONF="/tmp/config/wpa_supplicant.conf"
    mkdir -p /tmp/config
    cat > "$WPA_CONF" << WPAEOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	scan_ssid=1
	ssid="${WIFI_SSID}"
	psk="${WIFI_PASS}"
	key_mgmt=WPA-PSK
}
WPAEOF
    # Also update xhr_config.ini so lp_app uses the right credentials
    if [ -f "$CONFIG" ]; then
        sed -i "s|^ssid=.*|ssid=${WIFI_SSID}|" "$CONFIG"
        ENC_PASS=$(echo -n "$WIFI_PASS" | uuencode -m - 2>/dev/null | sed -n '2p')
        [ -n "$ENC_PASS" ] && sed -i "s|^pwd=.*|pwd=${ENC_PASS}|" "$CONFIG"
    fi
    # Restart wpa_supplicant with new config
    killall wpa_supplicant 2>/dev/null
    sleep 1
    wpa_supplicant -Dnl80211 -iwlan0 -c"$WPA_CONF" -B 2>/dev/null
    udhcpc -i wlan0 -b -q 2>/dev/null &
fi

# ============================================================
# PRUSACONNECT TOKEN
# ============================================================

PRUSA_TOKEN=$(get_setting prusa_token "")
if [ -n "$PRUSA_TOKEN" ]; then
    log "Applying PrusaConnect token"
    echo -n "$PRUSA_TOKEN" > /userdata/xhr_http_token.conf
    sed -i "s|^token=.*|token=${PRUSA_TOKEN}|" "$CONFIG"
fi

# ============================================================
# CORE DUMP CLEANUP
# ============================================================

rm -f /userdata/core* 2>/dev/null

# ============================================================
# CLOUD BLOCKING
# ============================================================

CLOUD_HOSTS="connect.prusa3d.com camera-signaling.prusa3d.com timezone.prusa3d.com prusa3d.pool.ntp.org"
OTA_HOST="connect-ota.prusa3d.com"
OTA_ENABLED=$(get_setting ota_updates_enabled "1")
mount -o remount,rw / 2>/dev/null
if [ "$CLOUD_ENABLED" != "1" ]; then
    log "Cloud disabled — blocking Prusa endpoints in /etc/hosts"
    for h in $CLOUD_HOSTS; do
        grep -qF "$h" "$HOSTS" || echo "127.0.0.1 $h" >> "$HOSTS"
    done
else
    log "Cloud enabled"
fi
if [ "$OTA_ENABLED" != "1" ]; then
    log "OTA firmware updates disabled"
    grep -qF "$OTA_HOST" "$HOSTS" || echo "127.0.0.1 $OTA_HOST" >> "$HOSTS"
else
    log "OTA firmware updates enabled"
    grep -vF "$OTA_HOST" "$HOSTS" > "$HOSTS.tmp" && mv "$HOSTS.tmp" "$HOSTS"
fi
mount -o remount,ro / 2>/dev/null

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
# Copy snapshot_grabber and libjpeg to /tmp (FAT32 has no execute permissions)
if [ -f "$SD/bin/snapshot_grabber" ]; then
    cp "$SD/bin/snapshot_grabber" /tmp/snapshot_grabber 2>/dev/null && chmod +x /tmp/snapshot_grabber
    log "snapshot_grabber copied to /tmp ($(wc -c < /tmp/snapshot_grabber) bytes)"
fi
if [ -f "$SD/bin/libjpeg.so.8" ]; then
    cp "$SD/bin/libjpeg.so.8" /tmp/libjpeg.so.8 2>/dev/null
    log "libjpeg.so.8 copied to /tmp ($(wc -c < /tmp/libjpeg.so.8) bytes)"
fi
(
    sleep 20
    while true; do
        if [ -x /tmp/snapshot_grabber ]; then
            # Kill after 10s to prevent hung process from blocking the loop
            LD_LIBRARY_PATH=/tmp /tmp/snapshot_grabber /tmp/buddy_snapshot.jpg 2>/dev/null &
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
    # Truncate large log files (max 500KB each)
    for lf in buddy_boot.log web_access.log print_timelapse.log; do
        LPATH="$SD/logs/$lf"
        if [ -f "$LPATH" ]; then
            LSIZE=$(wc -c < "$LPATH" 2>/dev/null)
            if [ "$LSIZE" -gt 512000 ] 2>/dev/null; then
                tail -200 "$LPATH" > "$LPATH.tmp" && mv "$LPATH.tmp" "$LPATH"
            fi
        fi
    done
    # Always enforce retention limits
    # Delete oldest log files (keep last 5)
    ls -1 "$SD/logs/" 2>/dev/null | grep '\.log$' | sort | head -n -5 | while read f; do rm -f "$SD/logs/$f"; done
    # Delete oldest snapshots (keep last 20)
    ls -1 "$SD/snapshots/" 2>/dev/null | grep '\.jpg$' | sort | head -n -20 | while read f; do rm -f "$SD/snapshots/$f"; done
    # Delete oldest regular timelapse dirs (keep last 3)
    ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' | sort | head -n -3 | while read d; do
        rm -rf "$SD/timelapse/$d"
    done

    # Print timelapse sessions — keep last 10, but aggressively trim at 90% disk
    SD_PCT=$(df "$SD" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    PT_KEEP=10
    [ -n "$SD_PCT" ] && [ "$SD_PCT" -gt 90 ] 2>/dev/null && PT_KEEP=3
    ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9]*_[0-9]' | sort | head -n -${PT_KEEP} | while read d; do
        rm -rf "$SD/timelapse/$d"
    done
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
# SCHEDULED DAILY REBOOT
# ============================================================

SCHED_REBOOT=$(get_setting scheduled_reboot "")
if [ -n "$SCHED_REBOOT" ]; then
    log "Scheduled daily reboot at ${SCHED_REBOOT}"
    (
        while true; do
            sleep 60
            CUR_TIME=$(date +%H:%M 2>/dev/null)
            if [ "$CUR_TIME" = "$SCHED_REBOOT" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') [boot] Scheduled reboot triggered" >> "$LOGFILE"
                sync
                sleep 2
                reboot -f
            fi
        done
    ) &
fi

# ============================================================
# WIFI AP FALLBACK — wait for connection before starting lp_app
# ============================================================

log "Waiting up to 30s for WiFi connection"
_wifi_wait=0
while [ $_wifi_wait -lt 30 ]; do
    WLAN_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')
    [ -n "$WLAN_IP" ] && break
    sleep 2
    _wifi_wait=$((_wifi_wait + 2))
done

if [ -n "$WLAN_IP" ]; then
    log "WiFi connected: ${WLAN_IP}"
else
    log "No WiFi after 30s — entering AP-only mode (lp_app will not start)"
    touch /tmp/buddy_ap_mode
    [ -f "$SD/sounds/wifi_ap_mode.wav" ] && simple_ao -i "$SD/sounds/wifi_ap_mode.wav" -v 50 2>/dev/null

    # Build unique SSID using last 4 hex chars of CPU serial
    AP_SUFFIX=$(grep -i '^Serial' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//' | tail -c 5 | tr 'a-f' 'A-F')
    [ -z "$AP_SUFFIX" ] && AP_SUFFIX="0000"
    AP_SSID="Buddy3D-${AP_SUFFIX}"

    killall wpa_supplicant 2>/dev/null
    killall udhcpc 2>/dev/null
    sleep 1

    # Start hostapd first (takes control of wlan0)
    cat > /tmp/hostapd.conf << HAPEOF
interface=wlan0
driver=nl80211
ssid=${AP_SSID}
channel=6
hw_mode=g
auth_algs=1
wpa=0
HAPEOF
    hostapd -B /tmp/hostapd.conf
    sleep 1

    # Set IP after hostapd is running (hostapd resets the interface)
    ifconfig wlan0 192.168.4.1 netmask 255.255.255.0 up
    sleep 2

    # Start DHCP server
    cat > /tmp/udhcpd_ap.conf << 'APEOF'
start 192.168.4.100
end 192.168.4.200
interface wlan0
option subnet 255.255.255.0
option router 192.168.4.1
option dns 192.168.4.1
option lease 3600
APEOF
    mkdir -p /var/lib/misc
    touch /var/lib/misc/udhcpd.leases
    udhcpd /tmp/udhcpd_ap.conf &

    log "AP mode started (SSID: ${AP_SSID}) — connect to configure WiFi at http://192.168.4.1/"

    # Stay alive — web server is already running, just wait here
    # When the user configures WiFi and reboots, lp_app will start normally
    while true; do sleep 3600; done
fi

# ============================================================
# START CAMERA APP
# ============================================================

log "Starting lp_app (main camera application)"
sync
lp_app --noshell --log2file $SD/logs
log_err "lp_app exited unexpectedly (exit code: $?)"
