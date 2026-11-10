// How long this process has been alive, from the kernel's record of when it started (`-HQLaunchTime` prints it as the
// app's first line of code runs: the cost of everything linked into the app, docs/spec/3x-intents.md A5).

import Darwin
import Foundation

nonisolated enum LaunchClock {
    static func millisecondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return (Double(now.tv_sec - started.tv_sec) * 1_000_000 + Double(now.tv_usec - started.tv_usec)) / 1000
    }
}
