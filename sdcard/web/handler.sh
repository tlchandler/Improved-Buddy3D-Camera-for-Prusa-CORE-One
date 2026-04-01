#!/bin/sh
# Buddy3D Camera Web UI — HTTP handler
# Runs via inetd: stdin/stdout are the socket
exec 2>/dev/null

SD=/mnt/sdcard
SETTINGS=$SD/buddy_settings.ini
CONFIG=/userdata/xhr_config.ini
HOSTS=/etc/hosts
WEBLOG=$SD/logs/web_access.log

web_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$WEBLOG" 2>/dev/null
}

# ============================================================
# REQUEST PARSING
# ============================================================

read -r REQUEST_LINE
METHOD=$(echo "$REQUEST_LINE" | cut -d' ' -f1)
REQUEST_PATH=$(echo "$REQUEST_LINE" | cut -d' ' -f2 | cut -d'?' -f1)
QUERY_STRING=$(echo "$REQUEST_LINE" | cut -d' ' -f2 | grep '?' | cut -d'?' -f2-)

CONTENT_LENGTH=0
AUTH_HEADER=""
while IFS= read -r HEADER; do
    HEADER=$(echo "$HEADER" | tr -d '\r')
    [ -z "$HEADER" ] && break
    case "$HEADER" in
        Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$HEADER" | sed 's/[^0-9]//g') ;;
        Authorization:*|authorization:*) AUTH_HEADER=$(echo "$HEADER" | cut -d' ' -f3-) ;;
    esac
done

BODY=""
if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
    BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi

case "$REQUEST_PATH" in
    /snapshot.jpg) ;;
    *) web_log "$METHOD $REQUEST_PATH" ;;
esac

# ============================================================
# HELPERS
# ============================================================

get_setting() {
    VAL=$(grep "^$1=" "$SETTINGS" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '\r')
    [ -z "$VAL" ] && VAL=$(grep "^$1=" "$CONFIG" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
    [ -z "$VAL" ] && VAL="$2"
    echo "$VAL"
}

get_field() { echo "$BODY" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d'=' -f2-; }

urldecode() { printf '%b' "$(echo "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }

html_escape() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&#39;/g'; }

send_headers() { printf "HTTP/1.0 $1\r\nContent-Type: $2\r\nConnection: close\r\n\r\n"; }
send_redirect() { printf "HTTP/1.0 302 Found\r\nLocation: $1\r\nConnection: close\r\n\r\n"; }

update_setting() {
    if grep -q "^$1=" "$SETTINGS" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$SETTINGS"
    else
        echo "$1=$2" >> "$SETTINGS"
    fi
    touch /tmp/buddy_settings_changed
}

# ============================================================
# AUTHENTICATION
# ============================================================

check_auth() {
    WEB_USER=$(get_setting web_username "")
    WEB_PASS=$(get_setting web_password "")
    [ -z "$WEB_USER" ] && return 0

    EXPECTED=$(echo -n "${WEB_USER}:${WEB_PASS}" | uuencode -m - | sed -n '2p')

    if [ "$AUTH_HEADER" != "$EXPECTED" ]; then
        web_log "AUTH FAILED for $METHOD $REQUEST_PATH"
        printf "HTTP/1.0 401 Unauthorized\r\n"
        printf "WWW-Authenticate: Basic realm=\"Buddy3D Camera\"\r\n"
        printf "Content-Type: text/html\r\n"
        printf "Connection: close\r\n\r\n"
        echo "<html><body style='background:#1a1a2e;color:#e0e0e0;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh'><h2>Authentication Required</h2></body></html>"
        exit 0
    fi
}

case "$REQUEST_PATH" in
    /snapshot.jpg) ;;
    *) check_auth ;;
esac

# ============================================================
# AP MODE — serve WiFi setup page only
# ============================================================

if [ -f /tmp/buddy_ap_mode ] && [ "$REQUEST_PATH" != "/save/wifi" ]; then
    printf "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
    SAVED_MSG=""
    case "$QUERY_STRING" in *saved=1) SAVED_MSG='<div style="background:#1a3a1a;border:1px solid #2d5a2d;padding:12px;border-radius:8px;margin-bottom:16px;color:#6fbf73;text-align:center">WiFi credentials saved. Power cycle the camera to connect.</div>' ;; esac
    cat << 'APPAGE'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Buddy3D WiFi Setup</title>
<style>
body { background:#0e1117; color:#c9d1d9; font-family:-apple-system,system-ui,sans-serif; margin:0; padding:20px; }
.card { background:#161b22; border:1px solid #30363d; border-radius:12px; padding:24px; max-width:420px; margin:40px auto; }
h1 { color:#fa6831; font-size:1.4em; margin:0 0 8px 0; text-align:center; }
p { font-size:.9em; color:#8b949e; text-align:center; margin:0 0 20px 0; }
label { display:block; color:#c9d1d9; font-size:.9em; margin-bottom:4px; }
input[type=text], input[type=password] { width:100%; padding:10px; background:#0d1117; border:1px solid #30363d; border-radius:6px; color:#c9d1d9; font-size:1em; margin-bottom:16px; box-sizing:border-box; }
button { width:100%; padding:12px; background:#fa6831; color:#fff; border:none; border-radius:8px; font-size:1em; cursor:pointer; }
button:hover { background:#fb8f67; }
.hint { display:block; font-size:.8em; color:#8b949e; margin-top:20px; text-align:center; }
</style>
</head>
<body>
<div class="card">
<h1>Buddy3D WiFi Setup</h1>
<p>The camera is not connected to WiFi.<br>Enter your network credentials below.</p>
APPAGE
    echo "$SAVED_MSG"
    # WiFi scan in AP mode
    echo '<div style="margin-bottom:16px"><h3 style="color:#c9d1d9;font-size:1em;margin-bottom:8px">Available Networks</h3>'
    echo '<div style="max-height:180px;overflow-y:auto;border:1px solid #30363d;border-radius:6px;padding:4px">'
    iwlist wlan0 scan 2>/dev/null | awk '
        /ESSID:/ { gsub(/.*ESSID:"/, ""); gsub(/".*/, ""); essid=$0 }
        /Quality=/ { split($0, a, "="); split(a[2], q, "/"); qual=int(q[1]); printf "%d\t%s\n", qual, essid }
    ' | sort -rn | awk -F'\t' '!seen[$2]++ && $2 != "" { print "<div style=\"padding:8px;border-bottom:1px solid #30363d;cursor:pointer;font-size:.9em\" onclick=\"document.getElementById('"'"'ap_ssid'"'"').value='"'"'" $2 "'"'"';\"><span style=\"color:#c9d1d9\">" $2 "</span> <span style=\"color:#8b949e;float:right\">" $1 "%</span></div>" }'
    echo '</div><div style="font-size:.8em;color:#8b949e;margin-top:4px">Tap a network to fill it in below.</div></div>'
    cat << 'APPAGE2'
<form method="POST" action="/save/wifi">
<label>WiFi Network Name (SSID)</label>
<input type="text" name="wifi_ssid" id="ap_ssid" placeholder="MyNetwork" required>
<label>WiFi Password</label>
<input type="password" name="wifi_password" id="ap_wifi_pw" placeholder="Enter password" required>
<label style="font-size:.85em;color:#8b949e;margin:8px 0"><input type="checkbox" onclick="var p=document.getElementById('ap_wifi_pw');p.type=this.checked?'text':'password'"> Show password</label>
<button type="submit">Save &amp; Reboot</button>
</form>
<span class="hint">After saving, power cycle the camera to connect to your network.</span>
</div>
</body>
</html>
APPAGE2
    exit 0
fi

# ============================================================
# HTML TEMPLATE
# ============================================================

html_header() {
    ACTIVE="$1"
    TITLE="$2"
    cat << 'CSSEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
CSSEOF
    echo "<title>Buddy3D — ${TITLE}</title>"
    cat << 'CSSEOF'
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#1a1a2e;color:#e0e0e0;padding:0;margin:0}
.wrap{max-width:600px;margin:0 auto;padding:16px 20px 40px}
nav{background:#0f0f23;border-bottom:1px solid #222;padding:0 16px;display:flex;gap:0;overflow-x:auto;-webkit-overflow-scrolling:touch}
nav a{color:#667;text-decoration:none;padding:14px 16px;font-size:.85em;font-weight:500;white-space:nowrap;border-bottom:2px solid transparent;transition:.2s}
nav a:hover{color:#aab}
nav a.active{color:#fa6831;border-bottom-color:#fa6831}
h1{color:#fa6831;font-size:1.3em;margin-bottom:4px}
.subtitle{color:#556;font-size:.78em;margin-bottom:16px}
.card{background:#16213e;border-radius:8px;padding:16px;margin-bottom:12px}
.card h2{font-size:.85em;color:#7889aa;text-transform:uppercase;letter-spacing:1px;margin-bottom:12px;font-weight:600}
.setting{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.04)}
.setting:last-child{border-bottom:none}
.setting label{font-size:.92em;flex:1}
.setting .toggle{flex:0 0 46px}
.hint{font-size:.72em;color:#556;display:block;margin-top:2px}
input[type=text],input[type=password],input[type=number],select{background:#1a1a2e;border:1px solid #2a3050;color:#e0e0e0;padding:7px 10px;border-radius:5px;font-size:.88em;width:180px}
input[type=text]:focus,input[type=password]:focus,input[type=number]:focus,select:focus{border-color:#fa6831;outline:none}
input[type=range]{width:110px;accent-color:#fa6831}
.range-val{display:inline-block;width:32px;text-align:right;color:#fa6831;font-size:.88em;font-weight:500}
.toggle{position:relative;width:46px;height:24px;display:inline-block;flex-shrink:0}
.toggle input{opacity:0;width:0;height:0}
.toggle .sl{position:absolute;top:0;left:0;right:0;bottom:0;background:#2a3050;border-radius:24px;cursor:pointer;transition:.3s}
.toggle .sl:before{content:"";position:absolute;height:18px;width:18px;left:3px;bottom:3px;background:#556;border-radius:50%;transition:.3s}
.toggle input:checked+.sl{background:#fa6831}
.toggle input:checked+.sl:before{transform:translateX(22px);background:#fff}
.btn{display:block;width:100%;background:#fa6831;color:#fff;border:none;padding:11px 24px;border-radius:6px;font-size:.95em;cursor:pointer;font-weight:600;margin-top:12px;text-align:center}
.btn:hover{background:#e05520}
.btn-outline{background:transparent;border:1px solid #334;color:#8899aa;font-weight:500}
.btn-outline:hover{background:#16213e;color:#ccc}
.btn-danger{background:transparent;border:1px solid #643;color:#d98}
.btn-danger:hover{background:#2a1a1a}
.btn-blue{background:transparent;border:1px solid #346;color:#8ad}
.btn-blue:hover{background:#1a1a2a}
.btn-sm{display:inline-block;width:auto;padding:5px 12px;font-size:.8em;margin:0}
.note{background:#16213e;border:1px solid #222;border-radius:6px;padding:10px 12px;margin-top:14px;font-size:.78em;color:#667;line-height:1.5}
.banner{background:#2a1a0a;border:1px solid #fa6831;border-radius:6px;padding:12px 16px;margin-bottom:16px;font-size:.85em;color:#fa6831;line-height:1.5}
.stat-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.stat{background:#1a1a2e;border-radius:6px;padding:10px 12px}
.stat .label{font-size:.72em;color:#556;text-transform:uppercase;letter-spacing:.5px}
.stat .value{font-size:1.05em;color:#ccc;margin-top:2px;font-weight:500}
.stat .value.good{color:#6d8}
.stat .value.warn{color:#db6}
.stat .value.bad{color:#d66}
.log-list{max-height:500px;overflow-y:auto;font-family:"SF Mono",Monaco,Consolas,monospace;font-size:.75em;line-height:1.8}
.log-entry{padding:4px 8px;border-bottom:1px solid rgba(255,255,255,.03)}
.log-entry.warn{color:#db6}
.log-entry.error{color:#d66}
.log-entry .time{color:#556;margin-right:6px}
.preview-img{width:100%;border-radius:6px;background:#111;min-height:200px}
.radio-group{display:flex;gap:12px;align-items:center}
.radio-group label{display:flex;align-items:center;gap:4px;font-size:.88em;cursor:pointer;flex:0}
.radio-group input[type=radio]{accent-color:#fa6831}
.conditional{display:none;margin-top:8px;padding:10px;background:#1a1a2e;border-radius:6px}
.conditional.show{display:block}
.signal-bar{display:inline-flex;align-items:flex-end;gap:2px;height:16px;vertical-align:middle}
.signal-bar span{width:4px;background:#334;border-radius:1px}
.signal-bar span.on{background:#fa6831}
.svc{display:flex;justify-content:space-between;padding:6px 0;font-size:.88em;border-bottom:1px solid rgba(255,255,255,.04)}
.svc:last-child{border-bottom:none}
.svc-on{color:#6d8}
.svc-off{color:#d66}
.log-tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
.log-tabs a{padding:6px 12px;border-radius:4px;font-size:.82em;color:#667;text-decoration:none;border:1px solid #2a3050}
.log-tabs a:hover{color:#aab;border-color:#445}
.log-tabs a.active{color:#fa6831;border-color:#fa6831}
.media-item{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.04);font-size:.88em}
.media-item:last-child{border-bottom:none}
.media-item .name{color:#ccc}
.media-item .meta{color:#556;font-size:.82em}
.media-item .actions{display:flex;gap:6px}
.sep{border:0;border-top:1px solid rgba(255,255,255,.06);margin:12px 0}
</style>
</head>
<body>
<nav>
CSSEOF

    for page in status media settings capture network security logs; do
        LABEL=$(echo "$page" | cut -c1 | tr a-z A-Z)$(echo "$page" | cut -c2-)
        if [ "$page" = "$ACTIVE" ]; then
            echo "<a href=\"/${page}\" class=\"active\">${LABEL}</a>"
        else
            echo "<a href=\"/${page}\">${LABEL}</a>"
        fi
    done

    echo '</nav>'
    echo '<div class="wrap">'

    # Show persistent banner if settings were changed since last boot
    if [ -f /tmp/buddy_settings_changed ]; then
        echo '<div class="banner">Settings have been changed. To apply, power cycle the camera or <form method="POST" action="/reboot" style="display:inline" onsubmit="return confirm('\''Restart the camera now?'\'')"><button type="submit" style="background:none;border:1px solid #fa6831;color:#fa6831;padding:4px 12px;border-radius:4px;cursor:pointer;font-size:.9em">Restart Now</button></form></div>'
    fi
}

html_footer() {
    echo '</div></body></html>'
}

# ============================================================
# ROUTES
# ============================================================

case "$REQUEST_PATH" in

# ---- STATUS PAGE (landing) ----
/|/status|/index.html)
    CAMERA_NAME=$(html_escape "$(get_setting camera_name 'Buddy3D Camera')")
    UPTIME_STR=$(uptime | sed 's/.*up \([^,]*\),.*/\1/')

    TEMP="N/A"
    [ -f /sys/class/thermal/thermal_zone0/temp ] && TEMP="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)" && TEMP="$((TEMP / 1000))°C"

    MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$MEM_TOTAL" ] && MEM_TOTAL=1
    MEM_PCT=$((100 - (MEM_FREE * 100 / MEM_TOTAL)))
    MEM_CLASS="good" ; [ "$MEM_PCT" -gt 70 ] && MEM_CLASS="warn" ; [ "$MEM_PCT" -gt 90 ] && MEM_CLASS="bad"

    SD_AVAIL=$(df -h "$SD" 2>/dev/null | tail -1 | awk '{print $4}')
    SD_PCT=$(df "$SD" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    SD_CLASS="good" ; [ "$SD_PCT" -gt 70 ] && SD_CLASS="warn" ; [ "$SD_PCT" -gt 90 ] && SD_CLASS="bad"

    CONN_COUNT=$(netstat -tn 2>/dev/null | grep ESTABLISHED | wc -l)
    PROC_COUNT=$(ps 2>/dev/null | wc -l)

    # Network info
    CUR_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')
    CUR_MASK=$(ifconfig wlan0 2>/dev/null | grep 'Mask' | sed 's/.*Mask:\([^ ]*\).*/\1/')
    CUR_GW=$(route -n 2>/dev/null | grep '^0.0.0.0' | awk '{print $2}')
    CUR_MAC=$(ifconfig wlan0 2>/dev/null | grep 'HWaddr' | awk '{print $5}')
    SSID=$(get_setting wifi_ssid "")
    [ -z "$SSID" ] && SSID=$(grep 'ssid=' /tmp/config/wpa_supplicant.conf 2>/dev/null | grep -v 'scan_ssid' | head -1 | sed 's/.*ssid="\(.*\)"/\1/' | sed "s/.*ssid='\(.*\)'/\1/" | sed 's/^[[:space:]]*//')
    SSID=$(html_escape "$SSID")

    SIGNAL_RAW=$(cat /proc/net/wireless 2>/dev/null | tail -1 | awk '{print $4}' | tr -d '.')
    [ -z "$SIGNAL_RAW" ] && SIGNAL_RAW=0
    if [ "$SIGNAL_RAW" -gt 0 ] 2>/dev/null; then
        SIGNAL_PCT=$((SIGNAL_RAW * 100 / 70))
        [ "$SIGNAL_PCT" -gt 100 ] && SIGNAL_PCT=100
    else
        SIGNAL_PCT=0
    fi
    SIGNAL_BARS=$((SIGNAL_PCT / 20))

    # Service status
    RTSP_MODE=$(get_setting rtsp_server_mode "2")
    CLOUD_ENABLED=$(get_setting cloud_enabled "0")
    TEL_ENABLED=$(get_setting telnet_enabled "1")
    TL_ENABLED=$(get_setting timelapse_enabled "0")
    PT_ENABLED=$(get_setting pt_enabled "0")

    # Print timelapse status
    PT_STATE="IDLE" PT_PRINT_ID="" PT_FRAMES="0" PT_LAST_Z="0.00" PT_ELAPSED="0"
    if [ -f /tmp/print_timelapse_status ]; then
        PT_STATE=$(grep "^state=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_PRINT_ID=$(grep "^print_id=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_FRAMES=$(grep "^frame_count=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_LAST_Z=$(grep "^last_z=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_ELAPSED=$(grep "^elapsed_seconds=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
    fi
    [ -z "$PT_STATE" ] && PT_STATE="IDLE"

    PT_RUNNING="no"
    ps 2>/dev/null | grep -q "print_timelapse" && PT_RUNNING="yes"

    send_headers "200 OK" "text/html"
    html_header "status" "Status"

    cat << HTMLEOF
<h1>${CAMERA_NAME}</h1>
<div class="subtitle">System overview</div>

<div class="card">
<h2>System</h2>
<div class="stat-grid">
<div class="stat"><div class="label">Uptime</div><div class="value">${UPTIME_STR}</div></div>
<div class="stat"><div class="label">CPU Temp</div><div class="value">${TEMP}</div></div>
<div class="stat"><div class="label">Memory</div><div class="value ${MEM_CLASS}">${MEM_PCT}% used (${MEM_FREE}K free)</div></div>
<div class="stat"><div class="label">SD Card</div><div class="value ${SD_CLASS}">${SD_AVAIL} free (${SD_PCT}% used)</div></div>
<div class="stat"><div class="label">Connections</div><div class="value">${CONN_COUNT} active</div></div>
<div class="stat"><div class="label">Processes</div><div class="value">${PROC_COUNT}</div></div>
</div>
</div>

<div class="card">
<h2>Network</h2>
<div class="stat-grid">
<div class="stat"><div class="label">SSID</div><div class="value">${SSID}</div></div>
<div class="stat"><div class="label">Signal</div><div class="value">
HTMLEOF

    printf '<span class="signal-bar">'
    for i in 1 2 3 4 5; do
        if [ "$i" -le "$SIGNAL_BARS" ]; then
            printf '<span class="on" style="height:%dpx"></span>' $((i * 3))
        else
            printf '<span style="height:%dpx"></span>' $((i * 3))
        fi
    done
    printf '</span> %d%%' "$SIGNAL_PCT"

    cat << HTMLEOF
</div></div>
<div class="stat"><div class="label">IP Address</div><div class="value">${CUR_IP}</div></div>
<div class="stat"><div class="label">Subnet</div><div class="value">${CUR_MASK}</div></div>
<div class="stat"><div class="label">Gateway</div><div class="value">${CUR_GW}</div></div>
<div class="stat"><div class="label">MAC</div><div class="value" style="font-size:.82em">${CUR_MAC}</div></div>
</div>
</div>

<div class="card">
<h2>Services</h2>
HTMLEOF

    echo "<div class='svc'><span>RTSP Streaming</span><span class='$([ "$RTSP_MODE" = "2" ] && echo svc-on || echo svc-off)'>$([ "$RTSP_MODE" = "2" ] && echo On || echo Off)</span></div>"
    echo "<div class='svc'><span>Cloud Access</span><span class='$([ "$CLOUD_ENABLED" = "1" ] && echo svc-on || echo svc-off)'>$([ "$CLOUD_ENABLED" = "1" ] && echo Enabled || echo Blocked)</span></div>"
    echo "<div class='svc'><span>Telnet</span><span class='$([ "$TEL_ENABLED" = "1" ] && echo svc-on || echo svc-off)'>$([ "$TEL_ENABLED" = "1" ] && echo On || echo Off)</span></div>"
    echo "<div class='svc'><span>Timelapse Capture</span><span class='$([ "$TL_ENABLED" = "1" ] && echo svc-on || echo svc-off)'>$([ "$TL_ENABLED" = "1" ] && echo On || echo Off)</span></div>"
    echo "<div class='svc'><span>Print Listener</span><span class='$([ "$PT_RUNNING" = "yes" ] && echo svc-on || echo svc-off)'>$([ "$PT_RUNNING" = "yes" ] && echo Running || echo Stopped)</span></div>"

    echo '</div>'

    # Print timelapse status (if active)
    if [ "$PT_STATE" = "PRINTING" ] || [ "$PT_STATE" = "FINALIZING" ]; then
        PT_STATE_CLASS="warn"
        [ "$PT_STATE" = "FINALIZING" ] && PT_STATE_CLASS="good"
        if [ "$PT_ELAPSED" -gt 0 ] 2>/dev/null; then
            PT_HOURS=$((PT_ELAPSED / 3600))
            PT_MINS=$(( (PT_ELAPSED % 3600) / 60 ))
            PT_SECS=$((PT_ELAPSED % 60))
            PT_TIME_STR=$(printf "%dh %02dm %02ds" $PT_HOURS $PT_MINS $PT_SECS)
        else
            PT_TIME_STR="—"
        fi
        cat << HTMLEOF

<div class="card">
<h2>Active Print</h2>
<div class="stat-grid">
<div class="stat"><div class="label">State</div><div class="value ${PT_STATE_CLASS}">${PT_STATE}</div></div>
<div class="stat"><div class="label">Session</div><div class="value">${PT_PRINT_ID}</div></div>
<div class="stat"><div class="label">Frames</div><div class="value">${PT_FRAMES}</div></div>
<div class="stat"><div class="label">Current Z</div><div class="value">${PT_LAST_Z}mm</div></div>
<div class="stat"><div class="label">Elapsed</div><div class="value">${PT_TIME_STR}</div></div>
</div>
</div>
HTMLEOF
    fi

    # Kernel info
    KERNEL=$(uname -r 2>/dev/null)
    cat << HTMLEOF

<div class="card">
<h2>Network</h2>
<div class="svc"><span>RTSP Stream</span><span style="color:#889"><code>rtsp://${CUR_IP}/live</code></span></div>
<div class="svc"><span>Web UI</span><span style="color:#889"><code>http://${CUR_IP}/</code></span></div>
</div>

<div class="card">
<h2>Firmware</h2>
<div class="svc"><span>Buddy3D Overlay</span><span style="color:#889">v0.1.1</span></div>
<div class="svc"><span>Kernel</span><span style="color:#889">${KERNEL}</span></div>
<div class="svc"><span>System Time</span><span style="color:#889">$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)</span></div>
</div>

<div class="card">
<form method="POST" action="/reboot" onsubmit="return confirm('Restart the camera now?')">
<button type="submit" class="btn btn-outline" style="width:100%">Restart Camera</button>
</form>
</div>
HTMLEOF

    html_footer
    ;;

# ---- SETTINGS PAGE ----
/settings)
    CAMERA_NAME=$(html_escape "$(get_setting camera_name 'Buddy3D Camera')")
    IR_MODE=$(get_setting ir_mode "1")
    RTSP_MODE=$(get_setting rtsp_server_mode "2")
    VIDEO_QUALITY=$(get_setting video_quality "6")
    VOLUME=$(get_setting volume "40")
    UPLOAD_INTERVAL=$(html_escape "$(get_setting snapshot_upload_interval '10000')")
    AUDIO_MODE=$(get_setting audio_announcements "1")

    CLOUD_ENABLED=$(get_setting cloud_enabled "0")

    IR_AUTO="" IR_DAY="" IR_NIGHT=""
    case "$IR_MODE" in 0) IR_DAY="selected";; 1) IR_AUTO="selected";; 2) IR_NIGHT="selected";; *) IR_AUTO="selected";; esac

    RTSP_CHK="" ; [ "$RTSP_MODE" = "2" ] && RTSP_CHK="checked"
    CLOUD_CHK="" ; [ "$CLOUD_ENABLED" = "1" ] && CLOUD_CHK="checked"
    OTA_ENABLED=$(get_setting ota_updates_enabled "1")
    OTA_CHK="" ; [ "$OTA_ENABLED" = "1" ] && OTA_CHK="checked"
    PRUSA_TOKEN=$(html_escape "$(get_setting prusa_token '')")
    SCHED_REBOOT=$(html_escape "$(get_setting scheduled_reboot '')")

    AUD_DEF="" AUD_MUTE="" AUD_DING=""
    case "$AUDIO_MODE" in 0) AUD_MUTE="selected";; 1) AUD_DEF="selected";; 2) AUD_DING="selected";; *) AUD_DEF="selected";; esac

    send_headers "200 OK" "text/html"
    html_header "settings" "Settings"

    cat << HTMLEOF
<h1>Settings</h1>
<div class="subtitle">Camera configuration — saved to SD card</div>

<form method="POST" action="/save/settings">

<div class="card">
<h2>General</h2>
<div class="setting">
<label>Camera Name</label>
<input type="text" name="camera_name" value="${CAMERA_NAME}">
</div>
<div class="setting">
<label>Volume<span class="hint">Speaker volume (0-100)</span></label>
<div><input type="range" name="volume" min="0" max="100" value="${VOLUME}" oninput="this.nextElementSibling.textContent=this.value"><span class="range-val">${VOLUME}</span></div>
</div>
<div class="setting">
<label>Audio Announcements<span class="hint">Voice, muted, or custom sounds</span></label>
<select name="audio_announcements">
<option value="1" ${AUD_DEF}>Default (voice)</option>
<option value="0" ${AUD_MUTE}>Muted</option>
<option value="2" ${AUD_DING}>Custom</option>
</select>
</div>
<div class="note" style="margin-top:6px;line-height:1.7">
<b>Custom sounds:</b> Place WAV files in the <code>sounds/</code> folder on the SD card.
Files must be <b>mono, 16000 Hz, signed 16-bit PCM</b> WAV format.
Name them to match the stock file you want to replace &mdash; unmatched files are ignored,
and any stock sound without a replacement keeps playing normally.<br>
<b>Available filenames:</b><br>
<code style="font-size:.85em">wifi_success.wav, wifi_failed.wav, volume_changed.wav, upgrading.wav,
stop_scanning.wav, start_scanning.wav, rtsp_enable.wav, rtsp_disable.wav,
pairing_successful.wav, pairing_error.wav, night_mode.wav, invalid_qr_code.wav,
factory_reset.wav, di.wav, day_mode.wav, auto_night_mode.wav, as.wav,
application_exit.wav</code>
</div>
</div>

<div class="card">
<h2>Video</h2>
<div class="setting">
<label>IR / Night Mode</label>
<select name="ir_mode">
<option value="1" ${IR_AUTO}>Auto</option>
<option value="0" ${IR_DAY}>Day (off)</option>
<option value="2" ${IR_NIGHT}>Night (on)</option>
</select>
</div>
<div class="setting">
<label>Video Quality<span class="hint">1 = lowest, 10 = highest</span></label>
<div><input type="range" name="video_quality" min="1" max="10" value="${VIDEO_QUALITY}" oninput="this.nextElementSibling.textContent=this.value"><span class="range-val">${VIDEO_QUALITY}</span></div>
</div>
<div class="setting">
<label>RTSP Streaming</label>
<label class="toggle"><input type="checkbox" name="rtsp_server_mode" value="2" ${RTSP_CHK}><span class="sl"></span></label>
</div>
</div>

<div class="card">
<h2>Cloud</h2>
<div class="setting">
<label>Cloud Access<span class="hint">Allow connections to Prusa servers</span></label>
<label class="toggle"><input type="checkbox" name="cloud_enabled" value="1" ${CLOUD_CHK}><span class="sl"></span></label>
</div>
<div class="setting">
<label>Firmware Updates<span class="hint">Allow Prusa OTA firmware updates</span></label>
<label class="toggle"><input type="checkbox" name="ota_updates_enabled" value="1" ${OTA_CHK}><span class="sl"></span></label>
</div>
<div class="setting">
<label>PrusaConnect Token<span class="hint">From PrusaConnect app &gt; Camera &gt; Token</span></label>
<input type="text" name="prusa_token" value="${PRUSA_TOKEN}" placeholder="Paste token here">
</div>
<div class="setting">
<label>Upload Interval<span class="hint">ms between snapshots (if cloud on)</span></label>
<input type="text" name="snapshot_upload_interval" value="${UPLOAD_INTERVAL}">
</div>
</div>

<div class="card">
<h2>Maintenance</h2>
<div class="setting">
<label>Scheduled Daily Reboot<span class="hint">Time in HH:MM (24h), leave blank to disable</span></label>
<input type="text" name="scheduled_reboot" value="${SCHED_REBOOT}" placeholder="04:00">
</div>
</div>

<button type="submit" class="btn">Save Settings</button>
</form>

HTMLEOF
    html_footer
    ;;

# ---- SAVE SETTINGS ----
/save/settings)
    web_log "Saving settings"
    CN=$(urldecode "$(get_field camera_name)")
    update_setting camera_name "$CN"
    update_setting ir_mode "$(get_field ir_mode)"
    update_setting video_quality "$(get_field video_quality)"
    update_setting volume "$(get_field volume)"
    update_setting snapshot_upload_interval "$(get_field snapshot_upload_interval)"
    PT=$(urldecode "$(get_field prusa_token)")
    update_setting prusa_token "$PT"
    SR=$(urldecode "$(get_field scheduled_reboot)")
    update_setting scheduled_reboot "$SR"
    update_setting audio_announcements "$(get_field audio_announcements)"

    # Checkboxes: present in BODY if checked, absent if unchecked
    RTSP_VAL=$(get_field rtsp_server_mode)
    [ -z "$RTSP_VAL" ] && RTSP_VAL=0
    update_setting rtsp_server_mode "$RTSP_VAL"

    CE=$(get_field cloud_enabled)
    [ -z "$CE" ] && CE=0
    update_setting cloud_enabled "$CE"

    OE=$(get_field ota_updates_enabled)
    [ -z "$OE" ] && OE=0
    update_setting ota_updates_enabled "$OE"

    # Apply cloud and OTA hosts
    CLOUD_HOSTS="connect.prusa3d.com camera-signaling.prusa3d.com timezone.prusa3d.com prusa3d.pool.ntp.org"
    OTA_HOST="connect-ota.prusa3d.com"
    mount -o remount,rw / 2>/dev/null
    if [ "$CE" = "1" ]; then
        for h in $CLOUD_HOSTS; do grep -vF "$h" "$HOSTS" > "$HOSTS.tmp" && mv "$HOSTS.tmp" "$HOSTS"; done
    else
        for h in $CLOUD_HOSTS; do grep -qF "$h" "$HOSTS" || echo "127.0.0.1 $h" >> "$HOSTS"; done
    fi
    if [ "$OE" = "1" ]; then
        grep -vF "$OTA_HOST" "$HOSTS" > "$HOSTS.tmp" && mv "$HOSTS.tmp" "$HOSTS"
    else
        grep -qF "$OTA_HOST" "$HOSTS" || echo "127.0.0.1 $OTA_HOST" >> "$HOSTS"
    fi
    mount -o remount,ro / 2>/dev/null

    sync
    send_redirect "/settings?saved=1"
    ;;

# ---- CAPTURE PAGE ----
/capture)
    TL_ENABLED=$(get_setting timelapse_enabled "0")
    TL_INTERVAL=$(get_setting timelapse_interval "60")
    TL_CHK="" ; [ "$TL_ENABLED" = "1" ] && TL_CHK="checked"

    TL_COUNT=0
    [ -d "$SD/timelapse" ] && TL_COUNT=$(find "$SD/timelapse" -name "*.jpg" 2>/dev/null | wc -l)

    SNAP_COUNT=0
    [ -d "$SD/snapshots" ] && SNAP_COUNT=$(find "$SD/snapshots" -name "*.jpg" 2>/dev/null | wc -l)

    SD_FREE=$(df -h "$SD" 2>/dev/null | tail -1 | awk '{print $4}')

    # Print timelapse settings
    PT_ENABLED=$(get_setting pt_enabled "0")
    PT_MODE=$(get_setting pt_capture_mode "layer")
    PT_LAYER=$(html_escape "$(get_setting pt_layer_height '0.2')")
    PT_DEBOUNCE=$(html_escape "$(get_setting pt_debounce_seconds '2.0')")
    PT_INTERVAL_S=$(html_escape "$(get_setting pt_interval_seconds '10.0')")
    PT_PORT=$(html_escape "$(get_setting pt_port '8514')")
    PT_CONFIRM=$(html_escape "$(get_setting pt_confirmation_count '2')")
    PT_STALE=$(html_escape "$(get_setting pt_stale_timeout '120')")

    PT_CHK="" ; [ "$PT_ENABLED" = "1" ] && PT_CHK="checked"
    PT_LAYER_SEL="" PT_INT_SEL=""
    [ "$PT_MODE" = "interval" ] && PT_INT_SEL="selected" || PT_LAYER_SEL="selected"

    # Print timelapse live status
    PT_STATE="IDLE" PT_PRINT_ID="" PT_FRAMES="0" PT_LAST_Z="0.00" PT_ELAPSED="0"
    if [ -f /tmp/print_timelapse_status ]; then
        PT_STATE=$(grep "^state=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_PRINT_ID=$(grep "^print_id=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_FRAMES=$(grep "^frame_count=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_LAST_Z=$(grep "^last_z=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
        PT_ELAPSED=$(grep "^elapsed_seconds=" /tmp/print_timelapse_status 2>/dev/null | cut -d= -f2)
    fi
    [ -z "$PT_STATE" ] && PT_STATE="IDLE"

    if [ "$PT_ELAPSED" -gt 0 ] 2>/dev/null; then
        PT_HOURS=$((PT_ELAPSED / 3600))
        PT_MINS=$(( (PT_ELAPSED % 3600) / 60 ))
        PT_SECS=$((PT_ELAPSED % 60))
        PT_TIME_STR=$(printf "%dh %02dm %02ds" $PT_HOURS $PT_MINS $PT_SECS)
    else
        PT_TIME_STR="—"
    fi

    PT_STATE_CLASS="good"
    [ "$PT_STATE" = "PRINTING" ] && PT_STATE_CLASS="warn"

    PT_RUNNING="no"
    ps 2>/dev/null | grep -q "print_timelapse" && PT_RUNNING="yes"

    PT_SESSIONS=0
    [ -d /mnt/sdcard/timelapse ] && PT_SESSIONS=$(ls -d /mnt/sdcard/timelapse/[0-9]*_[0-9]* 2>/dev/null | wc -l)

    CAM_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')

    send_headers "200 OK" "text/html"
    html_header "capture" "Capture"

    cat << HTMLEOF
<h1>Capture</h1>
<div class="subtitle">Live preview, snapshots, and timelapse</div>

<div class="card">
<h2>Live Preview</h2>
<img id="preview" class="preview-img" src="/snapshot.jpg" alt="Camera preview">
<script>
var img=document.getElementById('preview');
setInterval(function(){
    var t=new Date().getTime();
    img.src='/snapshot.jpg?t='+t;
},5000);
</script>
<div class="note" style="margin-top:8px">Auto-refreshes every 5 seconds. For full video: <b>rtsp://${CAM_IP}/live</b></div>
</div>

<div class="card">
<h2>Snapshot</h2>
<form method="POST" action="/save/snapshot" style="margin:0">
<button type="submit" class="btn btn-outline">Take Snapshot</button>
</form>
<div style="margin-top:8px;font-size:.8em;color:#667">${SNAP_COUNT} snapshots saved | ${SD_FREE} free on SD card</div>
</div>

<div class="card">
<h2>Always-On Timelapse</h2>
<form method="POST" action="/save/timelapse">
<div class="setting">
<label>Enable Timelapse<span class="hint">Auto-capture to SD card at regular intervals</span></label>
<label class="toggle"><input type="checkbox" name="timelapse_enabled" value="1" ${TL_CHK}><span class="sl"></span></label>
</div>
<div class="setting">
<label>Interval<span class="hint">Seconds between captures</span></label>
<select name="timelapse_interval">
HTMLEOF

    for iv in 10 30 60 120 300 600 1800 3600; do
        case "$iv" in
            10) LBL="10 sec";; 30) LBL="30 sec";; 60) LBL="1 min";; 120) LBL="2 min";;
            300) LBL="5 min";; 600) LBL="10 min";; 1800) LBL="30 min";; 3600) LBL="1 hour";;
        esac
        SEL="" ; [ "$TL_INTERVAL" = "$iv" ] && SEL="selected"
        echo "<option value=\"$iv\" $SEL>$LBL</option>"
    done

    cat << HTMLEOF
</select>
</div>
<button type="submit" class="btn btn-outline">Save Timelapse Settings</button>
</form>
<div style="margin-top:8px;font-size:.8em;color:#667">${TL_COUNT} timelapse images captured</div>
</div>

<form method="POST" action="/save/print">
<div class="card">
<h2>Print Timelapse</h2>

<div class="stat-grid">
<div class="stat"><div class="label">State</div><div class="value ${PT_STATE_CLASS}">${PT_STATE}</div></div>
<div class="stat"><div class="label">Listener</div><div class="value$([ "$PT_RUNNING" = "yes" ] && echo ' good' || echo ' bad')">$([ "$PT_RUNNING" = "yes" ] && echo 'Running' || echo 'Stopped')</div></div>
HTMLEOF

    if [ "$PT_STATE" = "PRINTING" ]; then
        cat << HTMLEOF
<div class="stat"><div class="label">Session</div><div class="value">${PT_PRINT_ID}</div></div>
<div class="stat"><div class="label">Frames</div><div class="value">${PT_FRAMES}</div></div>
<div class="stat"><div class="label">Current Z</div><div class="value">${PT_LAST_Z}mm</div></div>
<div class="stat"><div class="label">Elapsed</div><div class="value">${PT_TIME_STR}</div></div>
HTMLEOF
    fi

    cat << HTMLEOF
</div>
<hr class="sep">
<div class="setting">
<label>Enable Print Timelapse<span class="hint">Listen for printer metrics on UDP</span></label>
<label class="toggle"><input type="checkbox" name="pt_enabled" value="1" ${PT_CHK}><span class="sl"></span></label>
</div>
<div class="setting">
<label>Capture Mode</label>
<select name="pt_capture_mode" onchange="document.getElementById('layer-opts').style.display=this.value=='layer'?'block':'none';document.getElementById('int-opts').style.display=this.value=='interval'?'block':'none'">
<option value="layer" ${PT_LAYER_SEL}>Per Layer</option>
<option value="interval" ${PT_INT_SEL}>Timed Interval</option>
</select>
</div>
<div id="layer-opts" style="display:$([ "$PT_MODE" != "interval" ] && echo 'block' || echo 'none')">
<div class="setting"><label>Layer Height<span class="hint">mm — snapshot when Z advances by this amount</span></label><input type="text" name="pt_layer_height" value="${PT_LAYER}"></div>
<div class="setting"><label>Debounce<span class="hint">Seconds Z must be stable (filters Z-hops)</span></label><input type="text" name="pt_debounce_seconds" value="${PT_DEBOUNCE}"></div>
</div>
<div id="int-opts" style="display:$([ "$PT_MODE" = "interval" ] && echo 'block' || echo 'none')">
<div class="setting"><label>Interval<span class="hint">Seconds between snapshots</span></label><input type="text" name="pt_interval_seconds" value="${PT_INTERVAL_S}"></div>
</div>
<div class="setting"><label>UDP Port<span class="hint">Port for printer metrics</span></label><input type="text" name="pt_port" value="${PT_PORT}"></div>
</div>

<details style="margin-top:12px">
<summary style="color:#7889aa;font-size:.85em;cursor:pointer;padding:8px 0">Advanced Settings</summary>
<div class="card" style="margin-top:8px">
<div class="setting"><label>Confirmation Count<span class="hint">Consecutive readings to confirm state change</span></label><input type="text" name="pt_confirmation_count" value="${PT_CONFIRM}"></div>
<div class="setting"><label>Stale Timeout<span class="hint">Seconds without data before ending session</span></label><input type="text" name="pt_stale_timeout" value="${PT_STALE}"></div>
</div>
</details>

<button type="submit" class="btn">Save Print Settings</button>
<div class="note" style="margin-top:8px">Print timelapse changes require a reboot to take effect (restarts the listener).</div>
</form>
HTMLEOF

    # Past sessions
    if [ "$PT_SESSIONS" -gt 0 ]; then
        echo '<div class="card"><h2>Past Print Sessions</h2>'
        ls -1d /mnt/sdcard/timelapse/[0-9]*_[0-9]* 2>/dev/null | sort -r | head -10 | while read dir; do
            SNAME=$(basename "$dir")
            SFRAMES=$(ls "$dir"/frame_*.jpg 2>/dev/null | wc -l)
            HAS_VIDEO="" ; [ -f "$dir/timelapse.mp4" ] && HAS_VIDEO=" + video"
            echo "<div class='setting'><label>${SNAME}<span class='hint'>${SFRAMES} frames${HAS_VIDEO}</span></label></div>"
        done
        echo '</div>'
    fi

    # Setup instructions
    cat << HTMLEOF
<details style="margin-top:12px">
<summary style="color:#fa6831;font-size:.9em;cursor:pointer;padding:8px 0;font-weight:500">Print Timelapse Printer Setup Guide</summary>
<div class="card" style="margin-top:8px">
<h2>PrusaSlicer Configuration</h2>
<p style="font-size:.85em;color:#aab;line-height:1.6;margin-bottom:12px">
Add these lines to the <b>end</b> of your Start G-code in PrusaSlicer
(Printer Settings &rarr; Custom G-code &rarr; Start G-code):
</p>
<pre style="background:#1a1a2e;padding:12px;border-radius:6px;font-size:.82em;color:#ccc;overflow-x:auto;line-height:1.6">; === Camera Timelapse Setup ===
M334 ${CAM_IP} 8514 13514
M331 is_printing
M331 pos_z</pre>
<div class="note" style="margin-top:10px">
First print only: the printer will show a confirmation on the LCD asking you to approve
the metrics destination. Press <b>Yes</b>. This persists across power cycles.
</div>

<h2 style="margin-top:16px">Optional: Clean Snapshots</h2>
<p style="font-size:.85em;color:#aab;line-height:1.6;margin-bottom:12px">
For layer mode: add to <b>After layer change G-code</b> to park the print head during capture:
</p>
<pre style="background:#1a1a2e;padding:12px;border-radius:6px;font-size:.82em;color:#ccc;overflow-x:auto;line-height:1.6">G10
G1 X0 Y210 F9000
G4 P4000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
G11</pre>
<div class="note" style="margin-top:10px">G10/G11 retract and unretract to prevent oozing. The 4-second pause gives the camera time to capture after Z-hops settle. Adds ~5 seconds per layer. Skip this if using interval mode.</div>

<h2 style="margin-top:16px">Video Compilation</h2>
<p style="font-size:.85em;color:#aab;line-height:1.6">
The camera does not have enough RAM to encode video on-device.
To create a timelapse video, pull the SD card and run on your PC
(requires <a href="https://ffmpeg.org" style="color:#fa6831">ffmpeg</a>):
</p>
<div class="note" style="margin-top:10px">
<code style="color:#ccc">cd timelapse/SESSION_FOLDER</code><br>
<code style="color:#ccc">ffmpeg -framerate 30 -i frame_%05d.jpg -c:v libx264 -pix_fmt yuv420p timelapse.mp4</code>
</div>
</div>
</details>
HTMLEOF
    html_footer
    ;;

# ---- SAVE SNAPSHOT ----
/save/snapshot)
    mkdir -p "$SD/snapshots"
    FNAME="$SD/snapshots/$(date +%Y-%m-%d_%H-%M-%S).jpg"
    if cp /tmp/buddy_snapshot.jpg "$FNAME" 2>/dev/null; then
        web_log "Snapshot saved: $FNAME"
    else
        web_log "ERROR: Failed to save snapshot (source missing?)"
    fi
    sync
    send_redirect "/capture"
    ;;

# ---- SAVE TIMELAPSE ----
/save/timelapse)
    web_log "Saving timelapse settings"
    TLE=$(get_field timelapse_enabled)
    TLI=$(get_field timelapse_interval)
    [ -z "$TLE" ] && TLE=0
    [ -z "$TLI" ] && TLI=60
    update_setting timelapse_enabled "$TLE"
    update_setting timelapse_interval "$TLI"
    sync
    send_redirect "/capture?saved=1"
    ;;

# ---- SNAPSHOT IMAGE ----
/snapshot.jpg)
    if [ -f /tmp/buddy_snapshot.jpg ] && [ "$(wc -c < /tmp/buddy_snapshot.jpg 2>/dev/null)" -gt 1000 ]; then
        SIZE=$(wc -c < /tmp/buddy_snapshot.jpg)
        printf "HTTP/1.0 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: ${SIZE}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        cat /tmp/buddy_snapshot.jpg
    else
        send_headers "503 Service Unavailable" "text/plain"
        echo "Snapshot not available — RTSP stream works at rtsp://$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')/live"
    fi
    ;;

# ---- SAVE PRINT SETTINGS ----
/save/print)
    web_log "Saving print timelapse settings"
    for key in pt_enabled pt_capture_mode pt_layer_height pt_debounce_seconds pt_interval_seconds pt_port pt_confirmation_count pt_stale_timeout; do
        VAL=$(get_field "$key")
        [ -z "$VAL" ] && continue
        update_setting "$key" "$VAL"
    done
    # Handle unchecked toggle
    echo "$BODY" | grep -q "pt_enabled=" || update_setting pt_enabled 0
    # Signal the running binary to reload config
    PID=$(ps 2>/dev/null | grep "print_timelapse" | grep -v grep | awk '{print $1}')
    [ -n "$PID" ] && kill -HUP "$PID" 2>/dev/null
    sync
    send_redirect "/capture?saved=1"
    ;;

# ---- NETWORK PAGE ----
/network)
    IP_MODE=$(get_setting ip_mode "dhcp")
    STATIC_IP=$(html_escape "$(get_setting static_ip '')")
    STATIC_MASK=$(html_escape "$(get_setting static_mask '255.255.255.0')")
    STATIC_GW=$(html_escape "$(get_setting static_gateway '')")
    STATIC_DNS=$(html_escape "$(get_setting static_dns '')")
    NTP_SERVER=$(html_escape "$(get_setting ntp_server 'pool.ntp.org')")

    CUR_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*addr:\([^ ]*\).*/\1/')
    CUR_MASK=$(ifconfig wlan0 2>/dev/null | grep 'Mask' | sed 's/.*Mask:\([^ ]*\).*/\1/')
    CUR_GW=$(route -n 2>/dev/null | grep '^0.0.0.0' | awk '{print $2}')
    CUR_MAC=$(ifconfig wlan0 2>/dev/null | grep 'HWaddr' | awk '{print $5}')

    SIGNAL_RAW=$(cat /proc/net/wireless 2>/dev/null | tail -1 | awk '{print $4}' | tr -d '.')
    [ -z "$SIGNAL_RAW" ] && SIGNAL_RAW=0
    if [ "$SIGNAL_RAW" -gt 0 ] 2>/dev/null; then
        SIGNAL_PCT=$((SIGNAL_RAW * 100 / 70))
        [ "$SIGNAL_PCT" -gt 100 ] && SIGNAL_PCT=100
    else
        SIGNAL_PCT=0
    fi
    SIGNAL_BARS=$((SIGNAL_PCT / 20))

    SSID=$(get_setting wifi_ssid "")
    [ -z "$SSID" ] && SSID=$(grep 'ssid=' /tmp/config/wpa_supplicant.conf 2>/dev/null | grep -v 'scan_ssid' | head -1 | sed 's/.*ssid="\(.*\)"/\1/' | sed "s/.*ssid='\(.*\)'/\1/" | sed 's/^[[:space:]]*//')
    SSID=$(html_escape "$SSID")

    DHCP_CHK="" STATIC_CHK=""
    [ "$IP_MODE" = "static" ] && STATIC_CHK="checked" || DHCP_CHK="checked"

    send_headers "200 OK" "text/html"
    html_header "network" "Network"

    cat << HTMLEOF
<h1>Network</h1>
<div class="subtitle">WiFi and network configuration</div>

<div class="card">
<h2>WiFi Status</h2>
<div class="stat-grid">
<div class="stat"><div class="label">SSID</div><div class="value">${SSID}</div></div>
<div class="stat"><div class="label">Signal</div><div class="value">
HTMLEOF

    printf '<span class="signal-bar">'
    for i in 1 2 3 4 5; do
        if [ "$i" -le "$SIGNAL_BARS" ]; then
            printf '<span class="on" style="height:%dpx"></span>' $((i * 3))
        else
            printf '<span style="height:%dpx"></span>' $((i * 3))
        fi
    done
    printf '</span> %d%%' "$SIGNAL_PCT"

    cat << HTMLEOF
</div></div>
<div class="stat"><div class="label">IP Address</div><div class="value">${CUR_IP}</div></div>
<div class="stat"><div class="label">MAC</div><div class="value" style="font-size:.82em">${CUR_MAC}</div></div>
<div class="stat"><div class="label">Subnet</div><div class="value">${CUR_MASK}</div></div>
<div class="stat"><div class="label">Gateway</div><div class="value">${CUR_GW}</div></div>
</div>
</div>

<div class="card">
<h2>Available Networks</h2>
<div class="log-list" style="max-height:200px;overflow-y:auto">
HTMLEOF
    iwlist wlan0 scan 2>/dev/null | awk '
        /ESSID:/ { gsub(/.*ESSID:"/, ""); gsub(/".*/, ""); essid=$0 }
        /Quality=/ { split($0, a, "="); split(a[2], q, "/"); qual=int(q[1]); printf "%d\t%s\n", qual, essid }
    ' | sort -rn | awk -F'\t' '!seen[$2]++ && $2 != "" { print "<div class=\"svc\" style=\"cursor:pointer\" onclick=\"document.getElementById('"'"'wifi_ssid'"'"').value='"'"'" $2 "'"'"';\"><span>" $2 "</span><span style=\"color:#889\">" $1 "%</span></div>" }'
    [ "$SCAN_COUNT" -eq 0 ] && echo '<div style="font-size:.85em;color:#556;padding:8px 0">No networks found. Try again in a moment.</div>'
    cat << HTMLEOF
</div>
<div class="note" style="margin-top:6px">Tap a network name to fill it in below.</div>
</div>

<form method="POST" action="/save/wifi">
<div class="card">
<h2>WiFi Connection</h2>
<div class="setting"><label>SSID<span class="hint">Network name to connect to</span></label><input type="text" name="wifi_ssid" id="wifi_ssid" value="${SSID}" placeholder="MyNetwork"></div>
<div class="setting"><label>Password<span class="hint">Leave blank to keep current password</span></label><input type="password" name="wifi_password" id="wifi_pw" placeholder="Enter WiFi password"></div>
<div class="setting"><label></label><label style="font-size:.85em;color:#889"><input type="checkbox" onclick="var p=document.getElementById('wifi_pw');p.type=this.checked?'text':'password'"> Show password</label></div>
<button type="submit" class="btn btn-outline" onclick="return confirm('Change WiFi network? The camera will disconnect and attempt to connect to the new network. If the new credentials are wrong, the camera will start an AP named Buddy3D-Setup.')">Save WiFi Settings</button>
</div>
</form>

<form method="POST" action="/save/network">

<div class="card">
<h2>IP Configuration</h2>
<div class="setting">
<label>Mode</label>
<div class="radio-group">
<label><input type="radio" name="ip_mode" value="dhcp" ${DHCP_CHK} onclick="document.getElementById('static-fields').className='conditional'"> DHCP</label>
<label><input type="radio" name="ip_mode" value="static" ${STATIC_CHK} onclick="document.getElementById('static-fields').className='conditional show'"> Static</label>
</div>
</div>
<div id="static-fields" class="conditional$([ "$IP_MODE" = "static" ] && echo ' show')">
<div class="setting"><label>IP Address</label><input type="text" name="static_ip" value="${STATIC_IP}" placeholder="192.168.1.100"></div>
<div class="setting"><label>Subnet Mask</label><input type="text" name="static_mask" value="${STATIC_MASK}" placeholder="255.255.255.0"></div>
<div class="setting"><label>Gateway</label><input type="text" name="static_gateway" value="${STATIC_GW}" placeholder="192.168.1.1"></div>
<div class="setting"><label>DNS Server</label><input type="text" name="static_dns" value="${STATIC_DNS}" placeholder="8.8.8.8"></div>
</div>
</div>

<div class="card">
<h2>Time Sync</h2>
<div class="setting">
<label>NTP Server<span class="hint">Time synchronization server</span></label>
<input type="text" name="ntp_server" value="${NTP_SERVER}">
</div>
</div>

<button type="submit" class="btn">Save Network Settings</button>
</form>
HTMLEOF
    html_footer
    ;;

# ---- SAVE NETWORK ----
/save/network)
    web_log "Saving network settings"
    for key in ip_mode static_ip static_mask static_gateway static_dns ntp_server; do
        VAL=$(get_field "$key")
        VAL=$(urldecode "$VAL")
        [ -z "$VAL" ] && continue
        update_setting "$key" "$VAL"
    done
    sync
    send_redirect "/network?saved=1"
    ;;

# ---- SAVE WIFI ----
/save/wifi)
    web_log "Saving WiFi settings"
    W_SSID=$(urldecode "$(get_field wifi_ssid)")
    W_PASS=$(urldecode "$(get_field wifi_password)")
    if [ -n "$W_SSID" ]; then
        # Save to buddy_settings (persists across reboots)
        update_setting wifi_ssid "$W_SSID"
        [ -n "$W_PASS" ] && update_setting wifi_password "$W_PASS"
        # Update the live wpa_supplicant config
        WPA_CONF="/tmp/config/wpa_supplicant.conf"
        if [ -n "$W_PASS" ]; then
            cat > "$WPA_CONF" << WPAEOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	scan_ssid=1
	ssid="${W_SSID}"
	psk="${W_PASS}"
	key_mgmt=WPA-PSK
}
WPAEOF
        else
            # Keep existing password — only update SSID
            if [ -f "$WPA_CONF" ]; then
                sed -i "s|ssid=.*|ssid=\"${W_SSID}\"|" "$WPA_CONF"
            fi
        fi
        # Also update xhr_config.ini so lp_app regenerates correct config on boot
        XHR=/userdata/xhr_config.ini
        if [ -f "$XHR" ]; then
            sed -i "s|^ssid=.*|ssid=${W_SSID}|" "$XHR"
            if [ -n "$W_PASS" ]; then
                # Store password base64-encoded (same format lp_app expects)
                ENC_PASS=$(echo -n "$W_PASS" | uuencode -m - | sed -n '2p')
                sed -i "s|^pwd=.*|pwd=${ENC_PASS}|" "$XHR"
            fi
        fi
        web_log "WiFi config updated — SSID: $W_SSID"
        # Reconfigure wpa_supplicant live (skip in AP mode — no wpa_supplicant running)
        [ ! -f /tmp/buddy_ap_mode ] && wpa_cli -i wlan0 reconfigure 2>/dev/null
    fi
    sync
    if [ -f /tmp/buddy_ap_mode ]; then
        send_redirect "/?saved=1"
    else
        send_redirect "/network?saved=1"
    fi
    ;;

# ---- SECURITY PAGE ----
/security)
    WEB_USER=$(html_escape "$(get_setting web_username '')")
    TEL_ENABLED=$(get_setting telnet_enabled "1")
    TEL_CHK="" ; [ "$TEL_ENABLED" = "1" ] && TEL_CHK="checked"
    HAS_AUTH="" ; [ -n "$WEB_USER" ] && HAS_AUTH="yes"

    send_headers "200 OK" "text/html"
    html_header "security" "Security"

    cat << HTMLEOF
<h1>Security</h1>
<div class="subtitle">Access control and authentication</div>

<div class="card">
<h2>Web UI Password</h2>
HTMLEOF

    if [ -n "$HAS_AUTH" ]; then
        echo '<div style="font-size:.85em;color:#6d8;margin-bottom:10px">Password protection is active (user: '"$WEB_USER"')</div>'
    else
        echo '<div style="font-size:.85em;color:#db6;margin-bottom:10px">No password set — anyone on your network can access settings</div>'
    fi

    cat << HTMLEOF
<form method="POST" action="/save/webauth">
<div class="setting"><label>Username</label><input type="text" name="web_username" value="${WEB_USER}" placeholder="admin"></div>
<div class="setting"><label>Password</label><input type="password" name="web_password" placeholder="Enter new password"></div>
<button type="submit" class="btn btn-outline">Set Password</button>
</form>
HTMLEOF

    if [ -n "$HAS_AUTH" ]; then
        echo '<form method="POST" action="/save/webauth"><input type="hidden" name="web_username" value=""><input type="hidden" name="web_password" value=""><button type="submit" class="btn btn-outline" style="margin-top:6px">Remove Password</button></form>'
    fi

    cat << HTMLEOF
</div>

<div class="card">
<h2>Telnet Remote Access</h2>
<form method="POST" action="/save/security">
<div class="setting">
<label>Telnet Access<span class="hint">Remote shell on port 23 (root access)</span></label>
<label class="toggle"><input type="checkbox" name="telnet_enabled" value="1" ${TEL_CHK}><span class="sl"></span></label>
</div>
<button type="submit" class="btn btn-outline">Save Telnet Setting</button>
</form>

</div>
HTMLEOF
    html_footer
    ;;

# ---- SAVE WEB AUTH ----
/save/webauth)
    web_log "Updating web authentication"
    WU=$(urldecode "$(get_field web_username)")
    WP=$(urldecode "$(get_field web_password)")
    update_setting web_username "$WU"
    update_setting web_password "$WP"
    sync
    send_redirect "/security?saved=1"
    ;;

# ---- SAVE SECURITY (telnet) ----
/save/security)
    web_log "Saving security settings"
    TE=$(get_field telnet_enabled)
    [ -z "$TE" ] && TE=0
    update_setting telnet_enabled "$TE"
    sync
    send_redirect "/security?saved=1"
    ;;


# ---- LOGS PAGE ----
/logs)
    LOG_SEL=$(echo "$QUERY_STRING" | tr '&' '\n' | grep '^file=' | head -1 | cut -d= -f2)
    [ -z "$LOG_SEL" ] && LOG_SEL="boot"

    case "$LOG_SEL" in
        boot) LOG_PATH="$SD/logs/buddy_boot.log"; LOG_TITLE="Boot Log" ;;
        web) LOG_PATH="$SD/logs/web_access.log"; LOG_TITLE="Web Access Log" ;;
        print) LOG_PATH="$SD/logs/print_timelapse.log"; LOG_TITLE="Print Timelapse Log" ;;
        camera) LOG_PATH=$(ls -1 "$SD/logs/" 2>/dev/null | grep '\.log$' | grep -v buddy_boot | grep -v web_access | grep -v print_timelapse | sort -r | head -1); [ -n "$LOG_PATH" ] && LOG_PATH="$SD/logs/$LOG_PATH"; LOG_TITLE="Camera Log" ;;
        *) LOG_PATH="$SD/logs/buddy_boot.log"; LOG_TITLE="Boot Log"; LOG_SEL="boot" ;;
    esac

    send_headers "200 OK" "text/html"
    html_header "logs" "Logs"

    cat << HTMLEOF
<h1>Logs</h1>
<div class="subtitle">System and application logs</div>

<div class="log-tabs">
HTMLEOF

    for tab in boot web print camera; do
        case "$tab" in
            boot) TLBL="Boot";; web) TLBL="Web";; print) TLBL="Print";; camera) TLBL="Camera";;
        esac
        if [ "$tab" = "$LOG_SEL" ]; then
            echo "<a href=\"/logs?file=${tab}\" class=\"active\">${TLBL}</a>"
        else
            echo "<a href=\"/logs?file=${tab}\">${TLBL}</a>"
        fi
    done

    cat << HTMLEOF
</div>

<div class="card">
<h2>${LOG_TITLE}</h2>
<div class="log-list">
HTMLEOF

    if [ -n "$LOG_PATH" ] && [ -f "$LOG_PATH" ] && [ -s "$LOG_PATH" ]; then
        tail -100 "$LOG_PATH" | while IFS= read -r line; do
            ESC_LINE=$(echo "$line" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            case "$line" in
                *ERROR*|*error*|*Error*) echo "<div class='log-entry error'>${ESC_LINE}</div>" ;;
                *WARNING*|*WARN*|*warn*) echo "<div class='log-entry warn'>${ESC_LINE}</div>" ;;
                *) echo "<div class='log-entry'>${ESC_LINE}</div>" ;;
            esac
        done
    else
        echo '<div class="log-entry" style="color:#556">Log file is empty or not found</div>'
    fi

    cat << HTMLEOF
</div>
</div>

<a href="/logs?file=${LOG_SEL}" class="btn btn-outline" style="text-decoration:none">Refresh</a>
HTMLEOF

    html_footer
    ;;

# ---- MEDIA PAGE ----
/media)
    send_headers "200 OK" "text/html"
    html_header "media" "Media"

    cat << 'HTMLEOF'
<h1>Media</h1>
<div class="subtitle">Snapshots and timelapse videos</div>
HTMLEOF

    # Snapshots section — use ls on directory (not glob) for BusyBox compatibility
    SNAP_COUNT=0
    [ -d "$SD/snapshots" ] && SNAP_COUNT=$(ls -1 "$SD/snapshots/" 2>/dev/null | grep -c '\.jpg$')

    echo '<div class="card"><h2>Snapshots ('"$SNAP_COUNT"')</h2>'
    if [ "$SNAP_COUNT" -gt 0 ]; then
        ls -1 "$SD/snapshots/" 2>/dev/null | grep '\.jpg$' | sort -r | head -30 | while read FNAME; do
            # Format: 2026-03-30_14-30-00.jpg → 2026-03-30 14:30:00
            DISPLAY=$(echo "$FNAME" | sed 's/\.jpg$//; s/_/ /' | awk -F- '{if(NF>=5) printf "%s-%s-%s %s:%s:%s",$1,$2,$3,$4,$5,$6; else print $0}')
            echo "<div class='media-item'><span class='name'>${DISPLAY}</span><span class='actions'><a href='/file/snapshots/${FNAME}' class='btn btn-outline btn-sm' target='_blank'>View</a></span></div>"
        done
        if [ "$SNAP_COUNT" -gt 30 ]; then
            echo "<div style='font-size:.8em;color:#556;padding:8px 0'>Showing 30 of ${SNAP_COUNT} snapshots</div>"
        fi
    else
        echo '<div style="font-size:.85em;color:#556;padding:8px 0">No snapshots yet. Use the Capture page to take some.</div>'
    fi
    echo '</div>'

    # Print timelapse sessions — list timelapse dir, filter for session-format names (YYYYMMDD_HHMMSS)
    PT_COUNT=0
    [ -d "$SD/timelapse" ] && PT_COUNT=$(ls -1 "$SD/timelapse/" 2>/dev/null | grep -c '^[0-9]*_[0-9]')
    echo '<div class="card"><h2>Print Timelapses ('"$PT_COUNT"')</h2>'
    if [ "$PT_COUNT" -gt 0 ]; then
        ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9]*_[0-9]' | sort -r | head -20 | while read SNAME; do
            SDIR="$SD/timelapse/$SNAME"
            SFRAMES=$(ls -1 "$SDIR/" 2>/dev/null | grep -c 'frame_.*\.jpg$')
            echo "<div class='media-item'><div><span class='name'>${SNAME}</span><br><span class='meta'>${SFRAMES} frames</span></div><span class='actions'><a href='/download/timelapse/${SNAME}' class='btn btn-outline btn-sm'>Download .tar</a></span></div>"
        done
    else
        echo '<div style="font-size:.85em;color:#556;padding:8px 0">No print timelapse sessions yet.</div>'
    fi
    echo '</div>'

    # Regular timelapse dates — filter for date-format names (YYYY-MM-DD)
    TL_COUNT=0
    [ -d "$SD/timelapse" ] && TL_COUNT=$(ls -1 "$SD/timelapse/" 2>/dev/null | grep -c '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$')
    echo '<div class="card"><h2>Timelapse Captures ('"$TL_COUNT"')</h2>'
    if [ "$TL_COUNT" -gt 0 ]; then
        ls -1 "$SD/timelapse/" 2>/dev/null | grep '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' | sort -r | head -20 | while read DNAME; do
            DDIR="$SD/timelapse/$DNAME"
            DFRAMES=$(ls -1 "$DDIR/" 2>/dev/null | grep -c '\.jpg$')
            echo "<div class='media-item'><div><span class='name'>${DNAME}</span><br><span class='meta'>${DFRAMES} frames</span></div><span class='actions'><a href='/download/timelapse/${DNAME}' class='btn btn-outline btn-sm'>Download .tar</a></span></div>"
        done
    else
        echo '<div style="font-size:.85em;color:#556;padding:8px 0">No timelapse captures yet. Enable timelapse on the Capture page.</div>'
    fi
    echo '</div>'

    cat << 'HTMLEOF'
<div class="note" style="line-height:1.8">
<b>Compiling videos:</b> The camera does not have enough RAM to encode video on-device.
To create a timelapse video, pull the SD card and run on your PC (requires <a href="https://ffmpeg.org" style="color:#fa6831">ffmpeg</a>):<br>
<code style="font-size:.95em;color:#ccc">cd timelapse/SESSION_FOLDER</code><br>
<b>Print timelapses</b> (numbered frames):<br>
<code style="font-size:.95em;color:#ccc">ffmpeg -framerate 30 -i frame_%05d.jpg -c:v libx264 -pix_fmt yuv420p timelapse.mp4</code><br>
<b>Regular timelapses</b> (timestamped frames):<br>
<code style="font-size:.95em;color:#ccc">ffmpeg -framerate 30 -pattern_type glob -i "*.jpg" -c:v libx264 -pix_fmt yuv420p timelapse.mp4</code><br>
Copy the resulting <code>timelapse.mp4</code> back to the session folder on the SD card to view it here.
</div>
HTMLEOF

    html_footer
    ;;

# ---- SERVE MEDIA FILES ----
/file/*)
    REL=$(echo "$REQUEST_PATH" | sed 's|^/file/||')
    # Security: prevent path traversal
    REL=$(urldecode "$REL")
    case "$REL" in
        *..*|/* ) send_headers "403 Forbidden" "text/plain"; echo "Forbidden"; exit 0 ;;
    esac
    FILE="$SD/$REL"
    if [ -f "$FILE" ]; then
        case "$FILE" in
            *.jpg) CT="image/jpeg" ;;
            *.mp4) CT="video/mp4" ;;
            *.log) CT="text/plain" ;;
            *) CT="application/octet-stream" ;;
        esac
        SIZE=$(wc -c < "$FILE")
        printf "HTTP/1.0 200 OK\r\nContent-Type: ${CT}\r\nContent-Length: ${SIZE}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        cat "$FILE"
    else
        send_headers "404 Not Found" "text/plain"
        echo "File not found"
    fi
    ;;

# ---- DOWNLOAD TIMELAPSE TAR ----
/download/timelapse/*)
    SESSION=$(echo "$REQUEST_PATH" | sed 's|^/download/timelapse/||')
    SESSION=$(urldecode "$SESSION")
    case "$SESSION" in *..*|/*|"" ) send_headers "403 Forbidden" "text/plain"; echo "Forbidden"; exit 0 ;; esac
    DIR="$SD/timelapse/$SESSION"
    if [ -d "$DIR" ]; then
        TARNAME="${SESSION}.tar"
        printf "HTTP/1.0 200 OK\r\nContent-Type: application/x-tar\r\nContent-Disposition: attachment; filename=\"${TARNAME}\"\r\nConnection: close\r\n\r\n"
        tar cf - -C "$SD/timelapse" "$SESSION" 2>/dev/null
    else
        send_headers "404 Not Found" "text/plain"
        echo "Session not found"
    fi
    ;;

# ---- LEGACY REDIRECTS ----
/camera|/print)
    send_redirect "/capture"
    ;;

/system)
    send_redirect "/status"
    ;;

# ---- REBOOT ----
/reboot)
    web_log "REBOOT requested via web UI"
    send_headers "200 OK" "text/html"
    cat << 'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Rebooting</title>
<style>body{font-family:-apple-system,sans-serif;background:#1a1a2e;color:#e0e0e0;display:flex;justify-content:center;align-items:center;height:100vh;text-align:center}.m{max-width:300px}.m h2{color:#fa6831;margin-bottom:12px}.m p{color:#667;font-size:.9em;line-height:1.5}</style>
</head><body><div class="m"><h2>Rebooting...</h2><p>The camera is restarting. This page will refresh in 30 seconds.</p></div>
<script>setTimeout(function(){window.location='/'},30000)</script></body></html>
EOF
    sync
    sleep 1
    reboot -f &
    ;;

# ---- FACTORY RESET ----
/reset)
    web_log "FACTORY RESET requested via web UI"
    rm -f "$SETTINGS"
    sync
    send_headers "200 OK" "text/html"
    cat << 'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Reset</title>
<style>body{font-family:-apple-system,sans-serif;background:#1a1a2e;color:#e0e0e0;display:flex;justify-content:center;align-items:center;height:100vh;text-align:center}.m{max-width:300px}.m h2{color:#fa6831;margin-bottom:12px}.m p{color:#667;font-size:.9em;line-height:1.5}</style>
</head><body><div class="m"><h2>Settings Reset</h2><p>All settings have been cleared. Reboot the camera for factory defaults.</p><br><a href="/settings" style="color:#fa6831">Back to Settings</a></div></body></html>
EOF
    ;;

# ---- 404 ----
*)
    send_headers "404 Not Found" "text/html"
    echo '<!DOCTYPE html><html><head><style>body{font-family:sans-serif;background:#1a1a2e;color:#e0e0e0;display:flex;justify-content:center;align-items:center;height:100vh}</style></head><body><h2>404 — Not Found</h2></body></html>'
    ;;

esac
