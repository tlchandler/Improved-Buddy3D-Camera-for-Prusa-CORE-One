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
video_quality=1
volume=40
ir_mode=1
audio_announcements=1
telnet_enabled=0
timelapse_enabled=0
timelapse_interval=60
ntp_server=pool.ntp.org
rtsp_resolution=fhd
rtsp_bitrate=
rtsp_fps=
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
        rtsp_resolution|rtsp_bitrate|rtsp_fps) ;; # handled by RTSP patch below
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
# SNAPSHOT CAPTURE SETUP
# ============================================================
# No background loop — all snapshot consumers capture on demand:
#   - Preview page: /snapshot.jpg handler runs snapshot_grabber per request
#   - Always-on timelapse: its own loop runs snapshot_grabber at configured interval
#   - Print timelapse: binary runs snapshot_grabber on layer change / interval
# Copy binaries to /tmp since FAT32 has no execute permissions.

mkdir -p $SD/snapshots $SD/timelapse

if [ -f "$SD/bin/snapshot_grabber" ]; then
    cp "$SD/bin/snapshot_grabber" /tmp/snapshot_grabber 2>/dev/null && chmod +x /tmp/snapshot_grabber
    log "snapshot_grabber copied to /tmp ($(wc -c < /tmp/snapshot_grabber) bytes)"
fi
if [ -f "$SD/bin/libjpeg.so.8" ]; then
    cp "$SD/bin/libjpeg.so.8" /tmp/libjpeg.so.8 2>/dev/null
    log "libjpeg.so.8 copied to /tmp ($(wc -c < /tmp/libjpeg.so.8) bytes)"
fi

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
        if [ "$TL_ON" = "1" ] && [ -x /tmp/snapshot_grabber ]; then
            # Capture directly to the timelapse folder (no background loop dependency)
            TL_TMP="/tmp/buddy_tl_snap.jpg"
            nice -n 19 LD_LIBRARY_PATH=/tmp /tmp/snapshot_grabber "$TL_TMP" 2>/dev/null
            if [ -f "$TL_TMP" ] && [ "$(wc -c < "$TL_TMP" 2>/dev/null)" -gt 1000 ]; then
                DIR="$SD/timelapse/$(date +%Y-%m-%d)"
                mkdir -p "$DIR"
                FNAME="$DIR/$(date +%H-%M-%S).jpg"
                if cp "$TL_TMP" "$FNAME" 2>/dev/null; then
                    sync
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Failed to save timelapse frame: $FNAME" >> "$LOGFILE"
                fi
                rm -f "$TL_TMP"
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

    # Build unique SSID using last 4 hex chars of CPU serial
    AP_SUFFIX=$(grep -i '^Serial' /proc/cpuinfo 2>/dev/null | sed 's/.*: *//' | tail -c 5 | tr 'a-f' 'A-F')
    [ -z "$AP_SUFFIX" ] && AP_SUFFIX="0000"
    AP_SSID="Buddy3D-${AP_SUFFIX}"

    # Clean shutdown of station mode — kill everything, fully release wlan0
    killall hostapd 2>/dev/null
    killall wpa_supplicant 2>/dev/null
    killall udhcpc 2>/dev/null
    killall udhcpd 2>/dev/null
    sleep 2
    ifconfig wlan0 down 2>/dev/null
    sleep 2
    ifconfig wlan0 up 2>/dev/null
    sleep 2

    # Verify nothing else is holding wlan0
    killall wpa_supplicant 2>/dev/null

    # Start hostapd (takes control of wlan0)
    cat > /tmp/hostapd.conf << HAPEOF
interface=wlan0
driver=nl80211
ssid=${AP_SSID}
channel=6
hw_mode=g
auth_algs=1
wpa=0
HAPEOF

    # Try up to 3 times with increasing delays
    _ap_try=0
    while [ $_ap_try -lt 3 ]; do
        killall hostapd 2>/dev/null
        sleep 1
        hostapd -B /tmp/hostapd.conf
        sleep 3
        if pidof hostapd >/dev/null 2>&1; then
            log "hostapd started (attempt $((_ap_try + 1)))"
            break
        fi
        _ap_try=$((_ap_try + 1))
        log_err "hostapd failed to start (attempt ${_ap_try}/3)"
        # Longer reset between retries
        ifconfig wlan0 down 2>/dev/null
        sleep 3
        ifconfig wlan0 up 2>/dev/null
        sleep 2
    done

    if ! pidof hostapd >/dev/null 2>&1; then
        log_err "hostapd failed after 3 attempts — AP mode unavailable"
        # Still try to stay alive for the web server on whatever interface is up
        while true; do sleep 3600; done
    fi

    # Set IP — retry until it sticks (hostapd may reset the interface)
    _ip_wait=0
    while [ $_ip_wait -lt 5 ]; do
        ifconfig wlan0 192.168.4.1 netmask 255.255.255.0 up 2>/dev/null
        sleep 1
        ifconfig wlan0 2>/dev/null | grep -q '192.168.4.1' && break
        _ip_wait=$((_ip_wait + 1))
    done
    if ! ifconfig wlan0 2>/dev/null | grep -q '192.168.4.1'; then
        log_err "Failed to set AP IP address after retries"
    fi

    # Start DHCP server
    cat > /tmp/udhcpd_ap.conf << 'APEOF'
start 192.168.4.100
end 192.168.4.200
interface wlan0
max_leases 20
pidfile /tmp/udhcpd.pid
option subnet 255.255.255.0
option router 192.168.4.1
option lease 3600
APEOF
    mkdir -p /var/lib/misc
    touch /var/lib/misc/udhcpd.leases
    udhcpd /tmp/udhcpd_ap.conf

    log "AP mode started (SSID: ${AP_SSID}) — connect to configure WiFi at http://192.168.4.1/"

    # Voice announcement AFTER everything is verified ready
    [ -f "$SD/sounds/wifi_ap_mode.wav" ] && simple_ao -i "$SD/sounds/wifi_ap_mode.wav" -v 50 2>/dev/null

    # Monitor loop: restart udhcpd if it dies, re-set IP if lost
    while true; do
        sleep 30
        # Ensure IP is still set (hostapd or driver can reset it)
        if ! ifconfig wlan0 2>/dev/null | grep -q '192.168.4.1'; then
            log "AP IP lost — re-applying"
            ifconfig wlan0 192.168.4.1 netmask 255.255.255.0 up 2>/dev/null
        fi
        # Ensure udhcpd is still running
        if [ ! -f /tmp/udhcpd.pid ] || ! kill -0 "$(cat /tmp/udhcpd.pid 2>/dev/null)" 2>/dev/null; then
            log "udhcpd died — restarting"
            udhcpd /tmp/udhcpd_ap.conf
        fi
    done
fi

# ============================================================
# RTSP BITRATE + FPS PATCH (runtime binary modification)
# ============================================================
# lp_app hardcodes H264 CBR bitrates and 25fps frame rate.
# Resolution is controlled by video_quality in xhr_config.ini:
#   FHD = quality 1, HD = quality 6, SD = quality 5
#
# Bitrate patch (offset 368808): replaces resolution-check sequence with
#   unconditional MOVW + STR + B to set any bitrate for any resolution.
# FPS patch (offset 368884): single byte change in MOV R2, #25 instruction
#   that sets both SrcFrameRate and DstFrameRate.
# GOP patch (offset 368880): single byte in MOV R3, #50 (kept at 2x FPS).
#
# Patched binary lives on /userdata/ (UBIFS flash, not tmpfs RAM) to avoid OOM.
# Remove the SD card and the original runs untouched.

# Clean up any leftover patched binary from previous boot
rm -f /userdata/lp_app_patched

RTSP_BR=$(get_setting rtsp_bitrate "")
RTSP_FPS=$(get_setting rtsp_fps "")
NEED_PATCH=0
[ -n "$RTSP_BR" ] && [ "$RTSP_BR" -ge 250 ] 2>/dev/null && [ "$RTSP_BR" -le 6500 ] 2>/dev/null && NEED_PATCH=1
[ -n "$RTSP_FPS" ] && [ "$RTSP_FPS" -ge 5 ] 2>/dev/null && [ "$RTSP_FPS" -le 25 ] 2>/dev/null && NEED_PATCH=1

if [ "$NEED_PATCH" = "1" ]; then
    cp /oem/usr/sbin/lp_app /userdata/lp_app_patched
    _P=/userdata/lp_app_patched

    # Helper: write one byte via dd (handles 0x00 null bytes correctly)
    write_byte() {
        _off=$1 ; _hex=$2
        if [ "$_hex" = "00" ]; then
            dd if=/dev/zero of=$_P bs=1 seek=$_off count=1 conv=notrunc 2>/dev/null
        else
            printf "\\x${_hex}" | dd of=$_P bs=1 seek=$_off conv=notrunc 2>/dev/null
        fi
    }

    # --- Bitrate patch ---
    if [ -n "$RTSP_BR" ] && [ "$RTSP_BR" -ge 250 ] 2>/dev/null && [ "$RTSP_BR" -le 6500 ] 2>/dev/null; then
        # Encode ARM32 MOVW R3, #bitrate: 0xE300_3000 | (imm4 << 16) | imm12
        IMM12=$(( RTSP_BR & 0xFFF ))
        IMM4=$(( (RTSP_BR >> 12) & 0xF ))
        B0=$(printf '%02x' $(( IMM12 & 0xFF )))
        B1=$(printf '%02x' $(( 0x30 | ((IMM12 >> 8) & 0xF) )))
        B2=$(printf '%02x' $(( IMM4 )))
        # Offset 368808: MOVW R3, #bitrate
        write_byte 368808 "$B0" ; write_byte 368809 "$B1"
        write_byte 368810 "$B2" ; write_byte 368811 "e3"
        # Offset 368812: STR R3, [SP, #0x94]
        write_byte 368812 "94" ; write_byte 368813 "30"
        write_byte 368814 "8d" ; write_byte 368815 "e5"
        # Offset 368816: B +2 → skip to common code
        write_byte 368816 "02" ; write_byte 368817 "00"
        write_byte 368818 "00" ; write_byte 368819 "ea"
        log "Patched RTSP bitrate -> ${RTSP_BR} kbps"
    fi

    # --- FPS patch ---
    if [ -n "$RTSP_FPS" ] && [ "$RTSP_FPS" -ge 5 ] 2>/dev/null && [ "$RTSP_FPS" -le 25 ] 2>/dev/null; then
        FPS_HEX=$(printf '%02x' "$RTSP_FPS")
        GOP_VAL=$(( RTSP_FPS * 2 ))
        GOP_HEX=$(printf '%02x' "$GOP_VAL")
        # Offset 368884: MOV R2, #fps (byte 0 of instruction = immediate value)
        write_byte 368884 "$FPS_HEX"
        # Offset 368880: MOV R3, #gop (byte 0 of instruction = immediate value)
        write_byte 368880 "$GOP_HEX"
        log "Patched RTSP FPS -> ${RTSP_FPS} fps (GOP=${GOP_VAL})"
    fi

    chmod +x /userdata/lp_app_patched
    LP_APP_CMD="/userdata/lp_app_patched"
else
    LP_APP_CMD="lp_app"
fi

# ============================================================
# START CAMERA APP
# ============================================================

log "Starting lp_app (main camera application)"
sync
$LP_APP_CMD --noshell --log2file $SD/logs
log_err "lp_app exited unexpectedly (exit code: $?)"
