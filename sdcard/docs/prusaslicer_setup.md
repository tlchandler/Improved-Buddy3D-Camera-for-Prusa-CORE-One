# PrusaSlicer Setup Guide — Camera Timelapse via Printer Metrics

This guide walks you through configuring PrusaSlicer and your Prusa Core One
so that your camera automatically captures timelapse snapshots during every print.

## How It Works

Your Prusa Core One has a built-in metrics system that can stream printer data
(temperatures, positions, print state) over your local network as UDP packets.
By enabling two specific metrics and pointing them at your camera's IP address,
the camera can:

- Detect when a print starts and ends (via the `is_printing` metric)
- Track layer changes in real time (via the `pos_z` metric)
- Capture a snapshot at each layer or at a timed interval
- Store frames for later timelapse video compilation

No plugins, no OctoPrint, no cloud services — just your printer talking
directly to your camera on your local network.

## Prerequisites

- Prusa Core One connected to your local network (Wi-Fi or Ethernet)
- Camera on the same network, with the Print Timelapse feature enabled
- Know your camera's IP address (check the camera's web UI at http://<camera-ip>/)

## Step 1 — Find Your Camera's IP Address

Check your camera's web UI or your router's device list. It will look
something like `192.168.1.100`.

> **Important:** The printer's metrics host field is limited to 20 characters,
> so use the IP address directly rather than a hostname.

## Step 2 — Add Printer Start G-code in PrusaSlicer

This tells the printer to stream metrics to your camera every time a print begins.

1. Open **PrusaSlicer**
2. Go to **Printer Settings** (click the tab at the top)
3. Scroll down to the **Custom G-code** section
4. Find the **Start G-code** text box
5. Add the following lines **at the very end**, after all existing start G-code:

```gcode
; === Camera Timelapse Setup ===
; Point metrics stream at camera and enable print tracking
M334 192.168.1.100 8514 13514
M331 is_printing
M331 pos_z
```

6. **Replace `192.168.1.100`** with your camera's actual IP address

### What each line does

| Line | Purpose |
|------|---------|
| `M334 192.168.1.100 8514 13514` | Tells the printer to send metrics to your camera on UDP port 8514 (metrics) and 13514 (logs) |
| `M331 is_printing` | Enables the print-state metric (reports `1` or `0` every ~5 seconds) |
| `M331 pos_z` | Enables the Z-position metric (reports current height every ~11ms) |

> **Note:** The very first time you print after adding this, your printer will
> show a confirmation prompt on its LCD screen asking you to approve the metrics
> destination. Press **Yes** on the printer's screen. This only happens once —
> the setting is saved to the printer's memory and persists across prints and
> power cycles.

## Step 3 — Save as a Printer Profile

So you don't have to re-enter this every time:

1. After adding the G-code, click the **save icon** next to the printer profile dropdown
2. Give it a descriptive name like `Core One + Camera Timelapse`
3. Click **OK**

You can now select this profile for any print that should trigger timelapse capture.

## Step 4 — Verify It's Working

1. Slice any model and start a print
2. On the first print only: the printer's LCD will show a confirmation dialog
   asking you to approve sending metrics to your camera's IP. Tap **Yes**.
3. Check your camera's web UI (Print tab) — it should show state change to
   PRINTING once it detects `is_printing = 1`

### Troubleshooting

| Problem | Solution |
|---------|----------|
| Camera isn't receiving data | Make sure the printer and camera are on the same network/subnet. Try pinging the camera's IP from another device. |
| Printer shows no confirmation prompt | The metrics destination may already be configured from a previous session. This is fine — it means it's already working. |
| Wrong IP address entered | Re-run `M334` with the correct IP. You can do this from the printer's terminal/console or by starting a new print with the corrected Start G-code. |
| Camera captures too many/few frames in layer mode | Adjust the layer_height setting on the camera to match your slicer's layer height. |
| Snapshots look blurry from motion | See the optional pause step below. |

## Optional — Pause for Clean Snapshots (Layer Mode Only)

If you're using the camera in **layer mode** and want the print head out of
the frame for cleaner snapshots:

1. In PrusaSlicer, go to **Printer Settings > Custom G-code**
2. Find the **After layer change G-code** text box
3. Add:

```gcode
; === Timelapse Snapshot Pause ===
; Park head for clean photo, then return
G1 X0 Y210 F9000
G4 P2000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
```

This adds ~3 seconds per layer. On a 200-layer print, that's about 10 extra
minutes. The benefit is every frame has a clean, unobstructed view of the print.

**If you're using interval mode on the camera, skip this step.**

## Optional — Verify Metrics with M333

Send `M333` via the printer's terminal to see which metrics are enabled:

```
Send: M333
Response:
...
is_printing 1
pos_z 1
...
```

Both should show `1`.

## Quick Reference

### Start G-code (add at end)
```gcode
M334 <camera_ip> 8514 13514
M331 is_printing
M331 pos_z
```

### After layer change G-code (optional, layer mode only)
```gcode
G1 X0 Y210 F9000
G4 P2000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
```

### One-time action
Approve the metrics destination when prompted on the printer's LCD (first print only).
