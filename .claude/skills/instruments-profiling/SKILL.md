---
name: instruments-profiling
description: Profile the YouTrek macOS app for CPU hotspots, UI hangs, memory leaks, and allocations using Instruments (xctrace) and lightweight CLI tools (sample, leaks, spindump). Use when investigating performance, freezes, or memory issues, or to measure before/after impact of a change.
---

# Profiling YouTrek with Instruments

## Build for profiling

Time-profiling a Debug build exaggerates Swift overhead. Use Release for CPU/hang work; Debug is fine for leaks and allocations.

```bash
xcodebuild -scheme YouTrek -configuration Release -destination platform=macOS \
  -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Release/YouTrek.app
BIN=$APP/Contents/MacOS/YouTrek
```

(Debug products land in `build/DerivedData/Build/Products/Debug/`; `./youtrek.sh` builds Debug and opens the app.)

The app needs a YouTrack token to show real data — run `scripts/prefill_token.sh` first if profiling data-driven flows (issue switching, list scrolling). Without credentials the app still launches to the setup screen, which is enough for launch-time profiling only.

## Quick CLI checks (prefer these first — no trace parsing needed)

```bash
# CPU sampling of a running app for 10s (find main-thread hotspots)
sample YouTrek 10 -file /tmp/youtrek-sample.txt
# Then look for deep stacks under "Main Thread" / thread 0

# Detect an active hang / beachball: capture what every thread is doing
spindump YouTrek 5 -file /tmp/youtrek-spindump.txt

# Memory leaks in a running process
leaks YouTrek

# Leaks at exit (launch under leaks; needs malloc stack logging for backtraces)
MallocStackLogging=1 leaks --atExit -- "$BIN"

# Memory footprint breakdown
footprint YouTrek
heap YouTrek | head -50
```

## Full Instruments traces (xctrace)

Templates that matter here: `Time Profiler` (CPU + hangs), `Allocations`, `Leaks`, `Animation Hitches`, `App Launch`. List all: `xcrun xctrace list templates`.

```bash
# Record a launch under Time Profiler, stop after 30s
xcrun xctrace record --template 'Time Profiler' --time-limit 30s \
  --output /tmp/youtrek-cpu.trace --launch -- "$BIN"

# Attach to an already-running app instead (interact with the UI while recording)
xcrun xctrace record --template 'Time Profiler' --time-limit 20s \
  --output /tmp/youtrek-cpu.trace --attach YouTrek

# Launch-time analysis
xcrun xctrace record --template 'App Launch' --time-limit 15s \
  --output /tmp/youtrek-launch.trace --launch -- "$BIN"
```

While attached, drive the UI to reproduce the scenario (e.g. switch between issues repeatedly). AppleScript/`osascript` key events or accessibility clicks work for scripted repro.

## Reading a .trace from the CLI

```bash
# 1. See what tables the trace contains
xcrun xctrace export --input /tmp/youtrek-cpu.trace --toc

# 2. Export a table by schema (from the TOC), e.g. time-profile samples
xcrun xctrace export --input /tmp/youtrek-cpu.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > /tmp/youtrek-cpu.xml
```

The XML is large; extract the hot frames rather than reading it whole:

```bash
grep -o '<frame[^>]*name="[^"]*"' /tmp/youtrek-cpu.xml | \
  sed 's/.*name="//' | sort | uniq -c | sort -rn | head -30
```

Hang detection: the Time Profiler template includes the Hangs instrument — in the TOC look for a `hang` schema table and export it the same way. Any row there is a main-thread stall >250ms with its duration.

## Before/after measurement protocol

1. Record the scenario on the unmodified build; save the trace and the top-frames summary.
2. Apply the change, rebuild the same configuration, record the identical scenario (same duration, same interactions).
3. Compare: hang table row counts/durations, and weight of the previously-hot frames. Report both numbers — never claim a perf win from one uncompared trace.

## Cleanup

Traces are big; delete `/tmp/*.trace` when done. Kill any app instance you launched (`pkill -x YouTrek`) before recording a fresh run.
