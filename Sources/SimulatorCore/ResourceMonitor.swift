import Darwin
import Foundation

/// What one booted simulator costs the Mac right now: every process under its `launchd_sim`,
/// which is where the guest's apps and daemons all run as ordinary host processes.
public struct ResourceUsage: Sendable, Equatable {
    /// RAM the processes occupy right now.
    public var residentBytes: UInt64
    /// Physical footprint, the figure Activity Monitor calls Memory. It counts compressed pages at
    /// their uncompressed size, so it can far exceed what the Mac actually holds.
    public var footprintBytes: UInt64
    /// Percent of one core, so 250 means two and a half cores busy.
    public var cpuPercent: Double
    public var processCount: Int

    public init(residentBytes: UInt64, footprintBytes: UInt64, cpuPercent: Double, processCount: Int) {
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.cpuPercent = cpuPercent
        self.processCount = processCount
    }

    public static let zero = ResourceUsage(residentBytes: 0, footprintBytes: 0, cpuPercent: 0, processCount: 0)
}

/// Samples simulator processes with libproc. Cheap enough to run every few seconds, and only runs
/// while something is showing the numbers.
public final class ResourceMonitor: @unchecked Sendable {
    private struct Totals {
        var cpuNanoseconds: UInt64
        var at: UInt64
    }

    private var previous: [String: Totals] = [:]
    private let lock = NSLock()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public init() {}

    /// Usage keyed by UDID, for whichever of `udids` currently has a running `launchd_sim`.
    public func sample(udids: Set<String>) -> [String: ResourceUsage] {
        guard !udids.isEmpty else { return [:] }
        let processes = Self.allProcesses()
        var children: [pid_t: [pid_t]] = [:]
        for process in processes { children[process.ppid, default: []].append(process.pid) }

        let upperUDIDs = Set(udids.map { $0.uppercased() })
        var result: [String: ResourceUsage] = [:]
        var seen = Set<String>()
        let now = mach_absolute_time()

        lock.lock()
        defer { lock.unlock() }

        for process in processes where process.name == "launchd_sim" {
            guard let udid = Self.deviceUDID(of: process.pid, among: upperUDIDs) else { continue }
            var resident: UInt64 = 0
            var footprint: UInt64 = 0
            var cpuTicks: UInt64 = 0
            var count = 0
            var stack = [process.pid]
            while let pid = stack.popLast() {
                if let usage = Self.rusage(pid) {
                    resident += usage.ri_resident_size
                    footprint += usage.ri_phys_footprint
                    cpuTicks += usage.ri_user_time + usage.ri_system_time
                    count += 1
                }
                stack.append(contentsOf: children[pid] ?? [])
            }

            let cpuNanoseconds = cpuTicks * timebase.numer / timebase.denom
            var percent = 0.0
            if let last = previous[udid], now > last.at, cpuNanoseconds >= last.cpuNanoseconds {
                let elapsed = Double((now - last.at) * timebase.numer / timebase.denom)
                percent = Double(cpuNanoseconds - last.cpuNanoseconds) / elapsed * 100
            }
            previous[udid] = Totals(cpuNanoseconds: cpuNanoseconds, at: now)
            seen.insert(udid)
            result[udid] = ResourceUsage(
                residentBytes: resident, footprintBytes: footprint, cpuPercent: percent, processCount: count)
        }
        previous = previous.filter { seen.contains($0.key) }
        return result
    }

    // MARK: libproc

    struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let name: String
    }

    static func allProcesses() -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var entries: [ProcessEntry] = []
        entries.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            entries.append(ProcessEntry(pid: pid, ppid: pid_t(info.pbi_ppid), name: name))
        }
        return entries
    }

    static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// `launchd_sim`'s arguments and environment name the device's data directory, which contains
    /// its UDID.
    static func deviceUDID(of pid: pid_t, among udids: Set<String>) -> String? {
        guard let text = arguments(of: pid) else { return nil }
        return matchUDID(in: text, among: udids)
    }

    static func matchUDID(in text: String, among udids: Set<String>) -> String? {
        let upper = text.uppercased()
        return udids.first { upper.contains($0) }
    }

    static func arguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // NUL separated, so turn the separators into newlines and read it as one string.
        return String(decoding: buffer.prefix(size).map { $0 == 0 ? 10 : $0 }, as: UTF8.self)
    }
}
