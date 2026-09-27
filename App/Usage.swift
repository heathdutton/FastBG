import Darwin
import Foundation
import IOKit

/// How much of the Mac FastBG itself is using. Work done for FastBG elsewhere, like WebKit's web content processes,
/// isn't counted. The Neural Engine is only in use or not: macOS doesn't account its time per app.
struct Usage: Equatable, Sendable {
    /// Share of all the CPU cores together, so 100 is every core flat out.
    var cpu: Double
    /// Share of the GPU's time.
    var gpu: Double
    /// Whether FastBG has work on the Neural Engine, which macOS doesn't measure per app. Filled in by the model.
    var neural = false

    /// Counters since the process started, in nanoseconds.
    private struct Sample {
        let cpu: UInt64, gpu: UInt64, at: UInt64
    }

    private nonisolated(unsafe) static var last: Sample?
    private static let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Usage since the previous call, or nil for the first.
    @MainActor
    static func measure() -> Usage? {
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // The counters tick in Mach time, 125/3 ns a tick on Apple silicon, not nanoseconds.
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        func ns(_ ticks: UInt64) -> UInt64 { ticks * UInt64(base.numer) / UInt64(base.denom) }
        let now = Sample(cpu: ns(info.cpu_energy.total_user + info.cpu_energy.total_system), gpu: gpuTime(),
                         at: ns(mach_absolute_time()))
        defer { last = now }
        guard let last, now.at > last.at else { return nil }
        let span = Double(now.at - last.at)
        // A GPU connection that closed took its time with it.
        let gpu = now.gpu >= last.gpu ? Double(now.gpu - last.gpu) : 0
        return Usage(cpu: Double(now.cpu &- last.cpu) / span / cores * 100, gpu: min(100, gpu / span * 100))
    }

    /// The GPU time of every connection this process holds to the GPU, in nanoseconds, the count Activity Monitor
    /// shows. The task's own GPU counter, beside the CPU's, stays at zero on Apple silicon.
    private static func gpuTime() -> UInt64 {
        let me = "pid \(getpid()),"
        var total: UInt64 = 0
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators)
            == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String, creator.hasPrefix(me),
                      let uses = property(client, "AppUsage") as? [[String: Any]] else { continue }
                for use in uses {
                    total += (use["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                }
            }
        }
        return total
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
