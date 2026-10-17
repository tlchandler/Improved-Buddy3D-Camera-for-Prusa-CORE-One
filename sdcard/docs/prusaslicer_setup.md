# PrusaSlicer Setup Guide — Camera Timelapse via Printer Metrics

This guide walks you through configuring PrusaSlicer and your Prusa Core One
so that your camera automatically captures timelapse snapshots during every print.

## How It Works

Your Prusa Core One has a built-in metrics system that can stream printer data
over your local network as UDP packets. PrusaSlicer supplies explicit lifecycle
markers, so the camera can:

- Begin a fresh session when it receives `BUDDY_TIMELAPSE_START`
- Capture each completed layer when it receives `BUDDY_TIMELAPSE_LAYER`
- Capture at a timed interval between the start and completion markers
- Capture the finished model and close the session when it receives
  `BUDDY_TIMELAPSE_COMPLETE`
- Supersede an unfinished session when the next start marker arrives
- Store the resulting frames for later timelapse video compilation

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

This points metrics at the camera and sends an unambiguous session-start event.

1. Open **PrusaSlicer**
2. Go to **Printer Settings** (click the tab at the top)
3. Scroll down to the **Custom G-code** section
4. Find the **Start G-code** text box
5. Add the following lines **at the very end**, after all existing start G-code:

```gcode
; === Camera Timelapse Start ===
M334 192.168.1.100 8514 13514
M331 gcode
M118 BUDDY_TIMELAPSE_START:{input_filename_base}
G4 P100
M118 BUDDY_TIMELAPSE_START:{input_filename_base}
M332 gcode
```

6. **Replace `192.168.1.100`** with your camera's actual IP address

### What each line does

| Line | Purpose |
|------|---------|
| `M334 192.168.1.100 8514 13514` | Tells the printer to send metrics to your camera on UDP port 8514 (metrics) and 13514 (logs) |
| `M331 gcode` | Temporarily exposes the following G-code commands as metrics |
| `M118 BUDDY_TIMELAPSE_START:{input_filename_base}` | Starts a session named for the source model; the second copy protects against UDP loss |
| `M332 gcode` | Stops the high-volume G-code metric immediately after the marker window |

The camera combines its current timestamp with the model name, producing a
session directory such as `20260918_143027_gearbox-cover`. It sanitizes the
name for safe storage and falls back to the timestamp when no usable name is
provided. The camera supplies the timestamp at print time, so repeated prints
of the same G-code still receive distinct session names.

> **Note:** The first time you use a new metrics destination, the printer will
> ask you to approve it. The `M334` destination is saved in the printer and
> persists across power cycles. Selections made with `M331` and `M332` are
> runtime state; every marker block therefore enables and disables `gcode`
> locally instead of depending on persistent metric state.

> **Upgrading from the older Z-based setup:** If the printer has not been
> rebooted since a profile ran `M331 pos_z`, run `M332 pos_z` once to stop that
> high-frequency stream. Alternatively, reboot the printer. The new profile
> does not enable `pos_z`.

## Step 3 — Add the Completion Marker

Add the following at the **very beginning** of **End G-code**, before the
profile's existing shutdown commands. Do not replace those existing commands.

```gcode
; === Camera Timelapse Complete ===
G10
G90
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+1, max_print_height)} F720{endif}
G1 X0 Y210 F9000
M400
G4 P500
M331 gcode
M118 BUDDY_TIMELAPSE_COMPLETE:{total_layer_count}
G4 P100
M118 BUDDY_TIMELAPSE_COMPLETE:{total_layer_count}
M332 gcode
G4 P5000
```

This retracts, lifts, parks, captures a final image, and closes the session.
This five-second dwell happens once at completion, not after every layer. The
camera records `{total_layer_count}` as the final completed-layer count. The
following original End G-code can then shut down and park the printer as usual.
A cancelled or power-interrupted print cannot send this marker; its session
remains open, but the next `START` always closes it and begins a new uniquely
named session.

## Step 4 — Add the Lightweight After-Layer Marker

In **Printer Settings > Custom G-code > After layer change G-code**, add:

```gcode
; === Camera Timelapse Layer Capture ===
M400
M331 gcode
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
G4 P100
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
M332 gcode
```

This is all that layer mode requires. `M400` waits for the completed layer's
queued motion before sending the marker. The two identical markers make a lost
UDP datagram less likely to cost a frame, while `{layer_num}` lets the camera
deduplicate them. The G-code metric is disabled again immediately.

This minimal version does **not** wait for the camera. The printer can start the
next layer while the fresh snapshot is being acquired, so the print head may be
visible or moving in the resulting frame.

### Parked Layer Capture

If consistent head-free frames matter more than the added print time, replace
the minimal block above with:

```gcode
; === Camera Timelapse Layer Capture with Parking ===
G10
G1 X0 Y210 F9000
M400
G4 P500
M331 gcode
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
G4 P100
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
M332 gcode
G4 P5000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
G11
```

This version retracts, parks the head, waits 500 ms for vibration to settle,
and holds the position for five seconds while the camera captures. The
`G4 P5000` dwell is optional: shorten or remove it to trade composition
consistency for faster printing.

## Step 5 — Save as a Printer Profile

So you don't have to re-enter this every time:

1. After adding the G-code, click the **save icon** next to the printer profile dropdown
2. Give it a descriptive name like `Core One + Camera Timelapse`
3. Click **OK**

You can now select this profile for any print that should trigger timelapse capture.

## Step 6 — Verify It's Working

1. Slice any model and start a print
2. If this metrics destination has not been approved yet, the printer's LCD
   will ask whether it may send metrics to the camera's IP. Tap **Yes**.
3. Check the camera's Capture page. It should change to **PRINTING** as soon as
   the `START` marker arrives, before the first layer is printed.
4. The first capture is triggered at the transition to layer 2, after the first
   layer completes. With the minimal block, the image may also catch early
   second-layer motion. The completion marker adds the finished-model frame.

### Troubleshooting

| Problem | Solution |
|---------|----------|
| Camera isn't receiving data | Make sure the printer and camera are on the same network/subnet. Try pinging the camera's IP from another device. |
| Printer shows no confirmation prompt | The metrics destination may already be configured from a previous session. This is fine — it means it's already working. |
| Wrong IP address entered | Re-run `M334` with the correct IP. You can do this from the printer's terminal/console or by starting a new print with the corrected Start G-code. |
| Print stays IDLE | Verify the Start G-code contains `M331 gcode` before both `START` markers and `M332 gcode` after them. |
| Print is active but Frames stays at 0 | Check **Capture Phase**. If it says "Waiting for layer marker," verify the after-layer block is present and uses `M331 gcode` before `M118`. |
| Last Capture shows an error | Open the print timelapse log. The camera skips failed fresh captures instead of copying a stale preview image. |
| Print head is visible or moving | This is expected with the minimal marker block. Use the optional parked-head block for more consistent frames, and adjust its X/Y coordinate for your camera position. |
| A cancelled print still appears active | This is expected with marker-only state. The next print's `START` closes that session and begins a fresh one; frames are never merged or overwritten. |

If you use **interval mode**, omit the entire after-layer block. Interval mode
still requires the `START` and `COMPLETE` blocks, but cannot coordinate captures
with a parked head. If a print is interrupted without `COMPLETE`, timed captures
continue until the next `START`, listener restart, or feature disable. The
optional parked-head layer block is recommended when keeping the print head out
of every frame matters.

## Optional — Verify Metrics with M333

Send `M333` via the printer's terminal to see which metrics are enabled:

```
Send: M333
Response:
...
gcode 0
...
```

At rest, `gcode` should be disabled. Each marker block enables it only long
enough to transmit two copies of its marker.

## Quick Reference

### Start G-code (add at end)
```gcode
; === Camera Timelapse Start ===
M334 <camera_ip> 8514 13514
M331 gcode
M118 BUDDY_TIMELAPSE_START:{input_filename_base}
G4 P100
M118 BUDDY_TIMELAPSE_START:{input_filename_base}
M332 gcode
```

### End G-code (add at beginning)
```gcode
; === Camera Timelapse Complete ===
G10
G90
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+1, max_print_height)} F720{endif}
G1 X0 Y210 F9000
M400
G4 P500
M331 gcode
M118 BUDDY_TIMELAPSE_COMPLETE:{total_layer_count}
G4 P100
M118 BUDDY_TIMELAPSE_COMPLETE:{total_layer_count}
M332 gcode
G4 P5000
```

### After layer change G-code (lightweight)
```gcode
; === Camera Timelapse Layer Capture ===
M400
M331 gcode
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
G4 P100
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
M332 gcode
```

### After layer change G-code (parked-head replacement)
```gcode
; === Camera Timelapse Layer Capture with Parking ===
G10
G1 X0 Y210 F9000
M400
G4 P500
M331 gcode
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
G4 P100
M118 BUDDY_TIMELAPSE_LAYER:{layer_num}
M332 gcode
G4 P5000
G1 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} F9000
G11
```

### One-time action
Approve the metrics destination when prompted on the printer's LCD (first print only).
