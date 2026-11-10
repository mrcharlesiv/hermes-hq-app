#!/usr/bin/env python3
"""Cold-launch cost before app code runs (docs/spec/3x-intents.md A5, S8): terminates the app, starts it with
-HQLaunchTime and reads its `[Launch] preMain <ms>` line: the time from the kernel's start of the process to the first
line of app code (dyld loading and binding every linked framework, static initialisers, UIApplicationMain's setup).

  python3 scripts/fixture-support/launch-time.py <udid> [bundle id] [runs] [extra launch arguments…]
Prints each run in ms, then the median. Touches only the simulator it is given.
"""
import re, statistics, subprocess, sys, time

udid = sys.argv[1]
bundle = sys.argv[2] if len(sys.argv) > 2 else 'com.charlesmcdowell.hermeshq.native'
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 5
extra = sys.argv[4:]
values = []
for run in range(runs + 1):                      # the first run warms the caches and is not counted
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, bundle], capture_output=True)
    time.sleep(1.5)
    started = time.time()
    process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', udid, bundle,
                                '-HQLaunchTime'] + extra, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    stamp, deadline = None, time.time() + 30
    while time.time() < deadline:
        line = process.stdout.readline()
        if not line: break
        match = re.search(r'\[Launch\] preMain ([0-9.]+) ms', line)
        if match:
            stamp = float(match.group(1))
            break
    process.terminate()
    if stamp is None:
        print(f'run {run}: no [Launch] preMain line'); continue
    ms = stamp
    if run: values.append(ms)
    print(f'run {run}: {ms:.0f} ms' + ('' if run else ' (warm-up, not counted)'))
subprocess.run(['xcrun', 'simctl', 'terminate', udid, bundle], capture_output=True)
if values: print(f'median {statistics.median(values):.0f} ms over {len(values)} runs (min {min(values):.0f}, max {max(values):.0f})')
