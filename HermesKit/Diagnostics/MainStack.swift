// [diagnostics] What the main thread was running during a stall that MainTrail's spans don't name (the Mac's 1–2 s
// "nothing traced" stalls just after a return, Oct 29; the Mac gets no iOS hang reports). HangWatch's timer thread
// stops the main thread for a moment, reads its registers, walks its chain of frame records and lets it go. The
// return addresses become `main.hang.frame` events in the form of iOS's own hang frames (binary, offset into it), so
// hqn-logs.py names the app's own with atos and the build's dSYM. Only addresses are read, and nothing is allocated or
// locked while the main thread is stopped.

import Darwin
import Foundation
import MachO

nonisolated enum MainStack {
    static let limit = 48
    nonisolated(unsafe) private static var main: thread_act_t = 0

    /// Called once, on the main thread (HangWatch.install).
    static func install() {
        guard Thread.isMainThread, main == 0 else { return }
        main = mach_thread_self()
    }

    /// The main thread's return addresses, innermost first (the first is where it is now). Nil before `install`, on the
    /// main thread itself, or when the thread can't be stopped or read.
    static func sample() -> [UInt]? {
        let thread = main
        guard thread != 0, !Thread.isMainThread else { return nil }
        var addresses = [UInt](repeating: 0, count: limit)
        let count = addresses.withUnsafeMutableBufferPointer { buffer -> Int in
            guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
            let count = walk(thread, into: buffer)
            _ = thread_resume(thread)
            return count
        }
        return count > 0 ? Array(addresses.prefix(count)) : nil
    }

    /// Fills `out` while the thread is stopped: the program counter, the link register (arm64), then each frame
    /// record's return address. A record is read with vm_read_overwrite, which fails instead of crashing on a broken
    /// chain.
    private static func walk(_ thread: thread_act_t, into out: UnsafeMutableBufferPointer<UInt>) -> Int {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount) }
        }
        guard read == KERN_SUCCESS else { return 0 }
        let pc = UInt(state.__pc), firstFrame = UInt(state.__fp)
        let strip: UInt = 0x0000_000F_FFFF_FFFF   // system libraries sign their saved return addresses (arm64e)
        // A function that calls nothing (objc_msgSend, swift_retain, a small helper in a busy loop) keeps no frame
        // record: its caller is only in the link register. Without it the app's own looping function goes missing
        // (the Mac's -HQHangTest, Oct 29). When the function did save a record, the link register is that record's
        // return address and is dropped below; otherwise it may repeat the function the thread is in.
        let link = UInt(state.__lr) & strip
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) { thread_get_state(thread, x86_THREAD_STATE64, $0, &stateCount) }
        }
        guard read == KERN_SUCCESS else { return 0 }
        let pc = UInt(state.__rip), firstFrame = UInt(state.__rbp)
        let strip = UInt.max
        let link: UInt = 0
        #endif
        guard out.count > 1, pc != 0 else { return 0 }
        out[0] = pc & strip
        var count = 1
        if link != 0 {
            out[1] = link
            count = 2
        }
        var frame = firstFrame
        var record: (caller: UInt, returnAddress: UInt) = (0, 0)
        var first = true
        while count < out.count, frame != 0, frame & 7 == 0 {
            var size: vm_size_t = 0
            let copied = withUnsafeMutablePointer(to: &record) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: pointer)), &size)
            }
            guard copied == KERN_SUCCESS, record.returnAddress != 0 else { break }
            let returnAddress = record.returnAddress & strip
            if !(first && returnAddress == link) {   // the link register was this record's return address: already in
                out[count] = returnAddress
                count += 1
            }
            first = false
            guard record.caller > frame else { break }   // the stack grows down: each caller's record sits higher
            frame = record.caller
        }
        return count
    }

    struct Frame: Equatable, Sendable {
        var binary: String
        var offset: Int64
        var symbol: String?
    }

    /// Each address as its binary and offset into it (the app's own, for atos), with the nearest exported symbol for a
    /// system binary's (the app's own are named on the computer, against the dSYM).
    static func frames(_ addresses: [UInt]) -> [Frame] {
        addresses.enumerated().map { index, address in
            var info = Dl_info()
            // A return address is just past its call: one byte back is inside the calling function.
            let inside = index == 0 ? address : address &- 1
            guard let pointer = UnsafeRawPointer(bitPattern: inside), dladdr(pointer, &info) != 0, let base = info.dli_fbase else {
                return Frame(binary: "?", offset: Int64(bitPattern: UInt64(address)), symbol: nil)
            }
            let binary = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let symbol = LoadedImages.isApp(binary) ? nil : info.dli_sname.map { String(cString: $0) }
            return Frame(binary: binary, offset: Int64(address) - Int64(UInt(bitPattern: base)), symbol: symbol)
        }
    }

    /// The first few frames on one line for the app's own log ("UIKitCore -[UIView layoutSubviews] ← Hermes HQ +0x1a2b").
    static func summary(_ frames: [Frame], count: Int = 8) -> String {
        frames.prefix(count).map { frame in
            frame.symbol.map { "\(frame.binary) \($0)" } ?? "\(frame.binary) +0x\(String(frame.offset, radix: 16))"
        }.joined(separator: " ← ")
    }
}
