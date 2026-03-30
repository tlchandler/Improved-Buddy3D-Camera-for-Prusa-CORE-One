# Buddy3D Camera Custom Firmware Overlay

A set of SD card files that replace the cloud-dependent behavior of the **Prusa Buddy3D Camera** (Core One) with a fully local, self-hosted system. The camera hardware is untouched -- all modifications live on a removable microSD card. Remove the card and reboot to restore factory behavior.

> **Disclaimer:** This project is provided as-is, with no warranty of any kind. Modifying your camera's behavior carries risk, including the possibility of rendering it temporarily or permanently non-functional. By using these files, you accept full responsibility for any consequences. The authors disclaim all liability for damage to hardware, lost data, or voided warranties.

## Features

- **Local web UI** -- configure camera settings, view live snapshots, manage media, all from your browser
- **RTSP streaming** -- view the live feed in VLC, Home Assistant, or any RTSP client at `rtsp://<camera-ip>/live`
- **Cloud blocking** -- optionally block all Prusa cloud endpoints so the camera operates fully offline
- **Print timelapse** -- automatically capture snapshots during prints by listening for printer metrics over UDP
- **Regular timelapse** -- scheduled interval captures independent of printing
- **Snapshot capture** -- on-demand JPEG snapshots via the web UI
- **Custom sounds** -- replace the stock voice announcements with your own audio files
- **NTP time sync** -- accurate timestamps for logs and file naming
- **Web UI password** -- optional HTTP Basic Auth to protect settings
- **No permanent changes** -- every boot restores factory config first, then applies your settings on top

## Hardware

| Component | Detail |
|-----------|--------|
| Camera | Prusa Buddy3D for Core One (OEM: Niceboy Guardian PR1) |
| SoC | Rockchip RV1103 (ARM Cortex-A7, single core) |
| OS | Linux 5.10.110, BusyBox 1.27.2 |
| RAM | 34 MB total (~7 MB free at runtime) |
| Flash | Winbond W25N01GV 128 MB SPI NAND |
| Sensor | JX-F37P 2MP CMOS (1920x1080) |
| WiFi | Realtek RTL8188FU (USB, 802.11n 2.4 GHz) |

## Quick Start

### 1. Prepare the SD Card

- Use a microSD card (any size, 1 GB is plenty)
- **Format as FAT32** (important -- the camera cannot read exFAT or NTFS)

### 2. Copy Files

Copy the contents of the `sdcard/` directory to the **root** of the SD card:

```
SD card root (e.g., D:\)
+-- lp_app.sh
+-- web/
|   +-- server.sh
|   +-- handler.sh
+-- bin/
|   +-- print_timelapse
|   +-- snapshot_grabber
+-- tools/
|   +-- compile_timelapse.sh
+-- docs/
|   +-- prusaslicer_setup.md
+-- sounds/
    +-- (your custom .wav files, if any)
```

### 3. Insert and Boot

Insert the SD card into the camera and power cycle it. The camera's init system detects `lp_app.sh` and runs it instead of launching the stock app directly. Your settings file (`buddy_settings.ini`) is created automatically on first boot.

### 4. Access the Web UI

Open `http://<camera-ip>/` in your browser. The camera gets its IP from DHCP -- check your router's device list to find it.

### WiFi AP Fallback

If the camera cannot connect to WiFi within 40 seconds of booting, it automatically creates its own wireless access point:

| Setting | Value |
|---------|-------|
| SSID | `Buddy3D-Setup` |
| Password | None (open network) |
| Camera IP | `192.168.4.1` |
| DHCP range | `192.168.4.100` - `192.168.4.200` |

Connect to the `Buddy3D-Setup` network from your phone or laptop, then open `http://192.168.4.1/` to access the web UI and configure your WiFi credentials. Once saved, reboot the camera and it will connect to your network normally.

## Removing the SD Card

Eject the SD card and reboot the camera. It will return to full factory behavior:

- Cloud connectivity is restored
- All settings revert to Prusa defaults
- RTSP, telnet, web UI, and timelapse are no longer active
- No trace of the custom firmware remains on the camera's flash

This works because `lp_app.sh` restores factory configuration files every boot before applying custom settings. With no SD card present, there is nothing to apply, and the factory config (restored on the last SD card boot) remains in place.

## Web UI Pages

| Page | Description |
|------|-------------|
| **Status** | System dashboard -- uptime, temperature, memory, disk usage, network, services, active print |
| **Media** | Browse and download snapshots, timelapse frames, and print timelapse sessions |
| **Settings** | Camera name, volume, audio mode, IR/night mode, video quality, RTSP, cloud toggle |
| **Capture** | Live JPEG preview, take snapshots, configure timelapse intervals, print timelapse settings |
| **Network** | WiFi signal, SSID, IP info, DHCP/static toggle, NTP server |
| **Security** | Web UI password, telnet toggle |
| **Logs** | Log viewer for boot, web, print timelapse, and camera logs |

## Print Timelapse

The camera can automatically capture a snapshot at every layer change (or at a timed interval) during a print. This works by listening for UDP metrics that the Prusa Core One can stream over your local network.

### How It Works

1. You add a few lines of G-code to your PrusaSlicer printer profile
2. When a print starts, the printer streams `is_printing` and `pos_z` metrics to the camera
3. The `print_timelapse` binary detects print start/end and layer changes
4. Snapshots are saved as numbered JPEG frames in a session folder on the SD card

### PrusaSlicer Setup

Add the following to the **end** of your **Start G-code** in PrusaSlicer (Printer Settings > Custom G-code):

```gcode
; === Camera Timelapse Setup ===
M334 <camera_ip> 8514 13514
M331 is_printing
M331 pos_z
```

Replace `<camera_ip>` with your camera's IP address.

The first time you print, the printer's LCD will ask you to approve the metrics destination. Tap **Yes**. This only happens once.

### Optional: Clean Layer Snapshots

For unobstructed photos at each layer change, add this to your **After layer change G-code**:

```gcode
G1 X0 Y210 F9000
G4 P2000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
```

This parks the print head, waits 2 seconds for the camera to capture, then returns. Adds ~3 seconds per layer.

See [`sdcard/docs/prusaslicer_setup.md`](sdcard/docs/prusaslicer_setup.md) for the full setup guide.

## Compiling Timelapse Videos

The camera has only ~7 MB of free RAM at runtime, which is not enough to run a video encoder. Timelapse frames are saved as individual JPEG files and must be compiled into video on your PC.

### Using the included script

```bash
./tools/compile_timelapse.sh /path/to/sdcard/timelapse/SESSION_FOLDER
```

### Manual ffmpeg command

```bash
# Print timelapse (numbered frames)
ffmpeg -framerate 30 -i frame_%05d.jpg -c:v libx264 -pix_fmt yuv420p timelapse.mp4

# Regular timelapse (timestamped frames)
ffmpeg -framerate 30 -pattern_type glob -i "*.jpg" -c:v libx264 -pix_fmt yuv420p timelapse.mp4
```

Copy the resulting `timelapse.mp4` back to the session folder on the SD card to view it in the web UI's Media page.

## Custom Sounds

The camera plays voice announcements for events like WiFi connection, pairing, and mode changes. You can replace these with your own audio files.

1. Set **Audio Announcements** to **Custom** in the web UI settings
2. Place your WAV files in the `sounds/` folder on the SD card
3. Name each file to match the stock file you want to replace

### Audio Format Requirements

Files **must** be:

- **Mono** (1 channel)
- **16000 Hz** sample rate
- **Signed 16-bit PCM**
- **WAV** format

The camera's audio player (`simple_ao`) has no resampling capability. Files in the wrong format will play at the wrong speed or sound distorted.

### Replaceable Sound Files

| Filename | Event |
|----------|-------|
| `wifi_success.wav` | WiFi connected |
| `wifi_failed.wav` | WiFi connection failed |
| `volume_changed.wav` | Volume adjusted |
| `upgrading.wav` | Firmware update in progress |
| `stop_scanning.wav` | QR scanning stopped |
| `start_scanning.wav` | QR scanning started |
| `rtsp_enable.wav` | RTSP stream enabled |
| `rtsp_disable.wav` | RTSP stream disabled |
| `pairing_successful.wav` | Pairing complete |
| `pairing_error.wav` | Pairing failed |
| `night_mode.wav` | Night mode activated |
| `invalid_qr_code.wav` | Invalid QR code scanned |
| `factory_reset.wav` | Factory reset triggered |
| `di.wav` | Generic beep |
| `day_mode.wav` | Day mode activated |
| `auto_night_mode.wav` | Auto night mode activated |
| `as.wav` | Generic announcement |
| `application_exit.wav` | Camera app exiting |

Any stock sound without a matching file in `sounds/` plays normally.

## Network Access

| Service | Address | Notes |
|---------|---------|-------|
| Web UI | `http://<camera-ip>/` | Settings, snapshots, system dashboard |
| RTSP | `rtsp://<camera-ip>/live` | Live video (VLC, Home Assistant, etc.) |
| Telnet | `telnet <camera-ip>` port 23 | Root shell (disabled by default) |

## SD Card File Layout (at runtime)

```
SD card root
+-- lp_app.sh                     # Boot script (entry point)
+-- buddy_settings.ini            # User settings (auto-created on first boot)
+-- hosts.factory                  # Backup of original /etc/hosts
+-- xhr_config.ini.factory         # Backup of original camera config
+-- web/
|   +-- server.sh                 # HTTP server launcher (inetd)
|   +-- handler.sh                # HTTP request router + page generator
+-- bin/
|   +-- print_timelapse            # UDP listener for printer metrics
|   +-- snapshot_grabber           # JPEG capture from video pipeline
+-- tools/
|   +-- compile_timelapse.sh       # PC-side ffmpeg wrapper for video compilation
+-- docs/
|   +-- prusaslicer_setup.md       # PrusaSlicer configuration guide
+-- sounds/                        # Custom WAV files (optional)
+-- snapshots/                     # On-demand snapshots (auto-created)
+-- timelapse/                     # Timelapse frames (auto-created)
|   +-- 2026-03-30/                # Regular timelapse (daily folders)
|   +-- 20260330_143022/           # Print timelapse (per-session folders)
+-- logs/
    +-- buddy_boot.log             # Boot script log
    +-- web_access.log             # HTTP request log
    +-- print_timelapse.log        # Print listener log
```

## Building from Source

The `src/` directory contains the C source code for the two ARM binaries. These are pre-compiled in `sdcard/bin/` -- you only need to rebuild if you modify the source.

### print_timelapse

Statically linked, standard ARM cross-compile. No external dependencies.

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "C:/path/to/src:/src" \
  -w /src gcc:12 \
  bash build_print_timelapse.sh
```

### snapshot_grabber

Dynamically linked against the Rockchip MPI library (`librockit.so`). Requires the `rkmpi_example` headers and libraries from the [Luckfox Pico SDK](https://github.com/LuckfoxTECH/luckfox-pico).

```bash
MSYS_NO_PATHCONV=1 docker run --rm \
  -v "C:/path/to/src:/build/src" \
  -v "C:/path/to/rkmpi_example:/build/rkmpi" \
  -w /build/src \
  gcc:12 bash build_snapshot_grabber.sh
```

## How It Works (Technical)

The camera's init system (`/oem/usr/bin/RkLunch.sh`) checks for `/mnt/sdcard/lp_app.sh` on boot. If present, it runs that script instead of launching the stock camera app directly.

`lp_app.sh` does the following on every boot:

1. **Backs up** factory config (first boot only)
2. **Restores** factory config (clean slate)
3. **Applies** custom settings from `buddy_settings.ini`
4. **Blocks** cloud endpoints in `/etc/hosts` (if cloud disabled)
5. **Syncs** system clock via NTP
6. **Starts** background services (web server, snapshot capture, timelapse, print listener)
7. **Launches** the stock `lp_app` camera binary (which handles RTSP, video encoding, WiFi)

The web UI is a shell-script HTTP server -- `server.sh` configures BusyBox `inetd` to listen on port 80 and spawn `handler.sh` per connection. No external web server or runtime is needed.

## Known Limitations

- **No on-device video encoding** -- the RV1103 has only ~7 MB free RAM, not enough for ffmpeg
- **Single-threaded web server** -- inetd spawns one handler per connection, sequentially
- **No HTTPS** -- all traffic is plaintext (local network only)
- **FAT32 only** -- the camera cannot read exFAT or NTFS SD cards
- **No execute bit on FAT32** -- all scripts are invoked via `sh /path/to/script.sh`; binaries are copied to `/tmp` and `chmod +x`'d at runtime

## License

This project is not affiliated with or endorsed by Prusa Research. "Prusa" and "Core One" are trademarks of Prusa Research a.s.

This project is released under the [MIT License](LICENSE).
