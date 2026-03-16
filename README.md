# clicktrack

Low-latency, background mouse click tracker. Records every click with sub-millisecond precision and exports to CSV for analysis in R, Python, Excel, or any graphing tool.

## CSV output format

```
id,timestamp_ms,hold_time_ms,interval_ms,button
1,1710000000123.456789,87.234,                ,left
2,1710000000523.891011,92.111,313.199         ,left
3,1710000001004.567890,45.678,388.566         ,right
```

| Column | Description |
|--------|-------------|
| `id` | Sequential click number |
| `timestamp_ms` | Unix epoch milliseconds of the **press** (6 decimal places ≈ nanosecond source) |
| `hold_time_ms` | Duration the button was held down (press → release) |
| `interval_ms` | Time since the **previous release** to this press (empty for the first click) |
| `button` | `left`, `right`, `middle`, or `other` |

CSV was chosen because it's the universal import format — works directly with R (`read.csv`), Python pandas (`pd.read_csv`), Excel, Google Sheets, LibreOffice Calc, MATLAB, and every graphing tool.

## Building

Requires [Zig](https://ziglang.org/download/) ≥ 0.13.

```bash
# Native build (builds for your current OS)
zig build -Doptimize=ReleaseFast

# Cross-compile
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos
```

Binary goes to `zig-out/bin/clicktrack` (or `.exe` on Windows).

## Usage

```bash
# Default output: clicks.csv in current directory
./clicktrack

# Custom output path
./clicktrack ~/data/session1.csv

# Linux: optionally specify the input device
./clicktrack clicks.csv /dev/input/event5
```

Press **Ctrl+C** to stop. The CSV is flushed on every click, so no data is lost.

## Platform details

### Windows
Uses **Raw Input API** with `RIDEV_INPUTSINK` on a message-only window. This is a passive listener — it receives a *copy* of mouse events without inserting into the hook chain, so it adds **zero latency** to the mouse pipeline. Thread priority is elevated to minimize message queue delay.

### macOS
Uses **CGEventTap** at `kCGHIDEventTap` (the earliest interception point in the HID event path) with `kCGEventTapOptionListenOnly`. Passive — no latency added.

**Required:** Grant Accessibility permissions:
```
System Settings → Privacy & Security → Accessibility → enable clicktrack
```

### Linux
Reads directly from `/dev/input/eventN` (**evdev**). Events are timestamped by the kernel at interrupt time — the most accurate source possible. Auto-detects the mouse device, or you can specify one manually.

**Required:** Read permission on the input device:
```bash
# Option 1: run as root
sudo ./clicktrack

# Option 2: add yourself to the input group (persistent)
sudo usermod -aG input $USER
# then log out and back in
```

## Latency model

The only unavoidable delay is the mouse's USB polling interval (typically 1ms at 1000 Hz, 8ms at 125 Hz). clicktrack's overhead on top of that:

| Platform | API | Added latency |
|----------|-----|---------------|
| Windows | Raw Input (INPUTSINK) | ~0 (passive copy) |
| macOS | CGEventTap (ListenOnly) | ~0 (passive tap) |
| Linux | evdev read() | ~0 (kernel timestamp) |

## Analysis examples

### Python (pandas + matplotlib)
```python
import pandas as pd
import matplotlib.pyplot as plt

df = pd.read_csv("clicks.csv")
left = df[df.button == "left"]

# Bell curve of hold times
left.hold_time_ms.hist(bins=50, edgecolor="black")
plt.xlabel("Hold time (ms)")
plt.title("Click hold time distribution")
plt.show()

# Inter-click interval distribution
left.interval_ms.dropna().hist(bins=50, edgecolor="black")
plt.xlabel("Interval since last release (ms)")
plt.title("Click interval distribution")
plt.show()
```

### R
```r
df <- read.csv("clicks.csv")
left <- df[df$button == "left", ]

hist(left$hold_time_ms, breaks=50, main="Hold time distribution", xlab="ms")
hist(left$interval_ms[!is.na(left$interval_ms)], breaks=50,
     main="Inter-click interval", xlab="ms")

# Shapiro-Wilk normality test
shapiro.test(left$hold_time_ms)
```

## License

Public domain / CC0. Do whatever you want with it.
