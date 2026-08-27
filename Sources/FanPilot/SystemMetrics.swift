import Foundation
import IOKit

enum ThermalPressure: Int, CaseIterable, Codable, Sendable {
    case nominal = 0, fair = 1, serious = 2, critical = 3

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }
}

struct SystemMetrics: Equatable, Sendable {
    var cpuUsage: Double = 0
    var memoryUsage: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var diskUsage: Double = 0
    var diskFreeBytes: Int64 = 0
    var diskTotalBytes: Int64 = 0
    /// Absent on Macs whose accelerator does not publish utilisation.
    var gpuUsage: Double?
    /// Apple Silicon exposes no frequency or speed-limit counter; this four
    /// level pressure signal is what the system actually reports.
    var thermalPressure: ThermalPressure = .nominal
    /// Bytes in and out across every non-loopback interface over the last
    /// minute, plus the busiest minute seen so far to scale the ring against.
    var networkBytesPerMinute: UInt64 = 0
    var networkPeakBytesPerMinute: UInt64 = 0
    /// Empty when IOReport is unavailable; otherwise one entry per CPU cluster.
    var clusterFrequencies: [ClusterFrequency] = []

    var eCoreMHz: Double? { clusterFrequencies.first { $0.name == "ECPU" }?.megahertz }
    var pCoreMHz: Double? { clusterFrequencies.first { $0.name == "PCPU" }?.megahertz }
    var pCoreMaxMHz: Double? { clusterFrequencies.first { $0.name == "PCPU" }?.maximumMegahertz }
}

/// Samples the same counters Activity Monitor reports. Everything here is a
/// cheap host statistics call; the IOKit accelerator lookup is the only walk
/// through the registry, so its result is reused between refreshes.
/// Only the disk cache is touched from another thread, and a lock guards it.
final class SystemMetricsReader: @unchecked Sendable {
    private var previousTicks: host_cpu_load_info?
    private var lastCPUUsage: Double = 0
    private var cachedGPUUsage: Double?
    private var lastGPUReadAt: Date?

    // Free space has to be computed, not just read: on APFS it walks purgeable
    // space and can take hundreds of milliseconds, which must never happen on
    // the main thread every couple of seconds.
    private let diskQueue = DispatchQueue(label: "com.oleksii.baliuk.fanpilot.disk", qos: .utility)
    private let diskLock = NSLock()
    private var cachedDisk: (free: Int64, capacity: Int64)?
    private var lastDiskReadAt: Date?
    private var diskReadInFlight = false
    private let diskInterval: TimeInterval = 60

    private lazy var frequencyReader = CPUFrequencyReader()
    private var trafficSamples: [(date: Date, bytes: UInt64)] = []
    private var networkPeak: UInt64 = 0
    private let trafficWindow: TimeInterval = 60

    func read() -> SystemMetrics {
        var metrics = SystemMetrics()
        metrics.cpuUsage = readCPUUsage()

        let total = ProcessInfo.processInfo.physicalMemory
        metrics.memoryTotalBytes = total
        if let used = readMemoryUsed(), total > 0 {
            metrics.memoryUsedBytes = used
            metrics.memoryUsage = min(Double(used) / Double(total), 1)
        }
        metrics.swapUsedBytes = readSwapUsed()

        if let (free, capacity) = diskSnapshot(), capacity > 0 {
            metrics.diskFreeBytes = free
            metrics.diskTotalBytes = capacity
            metrics.diskUsage = min(Double(capacity - free) / Double(capacity), 1)
        }
        metrics.gpuUsage = readGPUUsage()
        metrics.thermalPressure = ThermalPressure(ProcessInfo.processInfo.thermalState)

        metrics.clusterFrequencies = frequencyReader?.read() ?? []

        let traffic = readTrafficInWindow()
        metrics.networkBytesPerMinute = traffic
        networkPeak = max(networkPeak, traffic)
        metrics.networkPeakBytesPerMinute = networkPeak
        return metrics
    }

    /// Interface counters are cumulative and reset when an interface is
    /// reconfigured, so the delta is taken defensively.
    private func readTrafficInWindow() -> UInt64 {
        let now = Date()
        let total = readInterfaceBytes()
        trafficSamples.append((now, total))

        // Keep one sample older than the window so a full minute can be spanned.
        if let index = trafficSamples.lastIndex(where: { now.timeIntervalSince($0.date) > trafficWindow }), index > 0 {
            trafficSamples.removeFirst(index)
        }
        guard let oldest = trafficSamples.first, oldest.bytes <= total else {
            trafficSamples = [(now, total)]
            return 0
        }
        let elapsed = now.timeIntervalSince(oldest.date)
        guard elapsed > 1 else { return 0 }
        let delta = Double(total - oldest.bytes)
        return UInt64(delta * (trafficWindow / min(elapsed, trafficWindow)))
    }

    private func readInterfaceBytes() -> UInt64 {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return 0 }
        defer { freeifaddrs(addresses) }

        var total: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard !String(cString: interface.ifa_name).hasPrefix("lo") else { continue }
            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            total += UInt64(data.pointee.ifi_ibytes) + UInt64(data.pointee.ifi_obytes)
        }
        return total
    }

    /// Returns whatever was measured last and refreshes in the background when
    /// it goes stale, so the caller is never blocked by the volume.
    private func diskSnapshot() -> (free: Int64, capacity: Int64)? {
        diskLock.lock()
        let cached = cachedDisk
        let isStale = lastDiskReadAt.map { Date().timeIntervalSince($0) >= diskInterval } ?? true
        let shouldRead = isStale && !diskReadInFlight
        if shouldRead { diskReadInFlight = true }
        diskLock.unlock()

        guard shouldRead else { return cached }
        diskQueue.async { [weak self] in
            guard let self else { return }
            let measured = self.readDisk()
            self.diskLock.lock()
            if let measured { self.cachedDisk = measured }
            self.lastDiskReadAt = .now
            self.diskReadInFlight = false
            self.diskLock.unlock()
        }
        return cached
    }

    private func readCPUUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastCPUUsage }
        defer { previousTicks = info }
        guard let previous = previousTicks else { return 0 }

        let user = Double(info.cpu_ticks.0) - Double(previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1) - Double(previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2) - Double(previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3) - Double(previous.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return lastCPUUsage }
        lastCPUUsage = min(max(busy / total, 0), 1)
        return lastCPUUsage
    }

    private func readMemoryUsed() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Activity Monitor's "Memory Used": app memory, wired and compressed.
        // sysconf reports the same kernel page size the counters are in, and
        // unlike vm_kernel_page_size it is not shared mutable state.
        let pageSize = UInt64(max(sysconf(_SC_PAGESIZE), 4096))
        let application = UInt64(statistics.internal_page_count)
            .subtractingReportingOverflow(UInt64(statistics.purgeable_count))
        let applicationPages = application.overflow ? 0 : application.partialValue
        let pages = applicationPages
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        return pages * pageSize
    }

    private func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func readDisk() -> (free: Int64, capacity: Int64)? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]) else { return nil }
        guard let capacity = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return (free, Int64(capacity))
    }

    private func readGPUUsage() -> Double? {
        if let lastGPUReadAt, Date().timeIntervalSince(lastGPUReadAt) < 4 { return cachedGPUUsage }
        lastGPUReadAt = .now
        cachedGPUUsage = nil

        // The registry exposes more than one accelerator entry and only one of
        // them carries the active figure, so the busiest wins.
        var readings: [Double] = []
        for serviceClass in ["IOAccelerator", "IOGPU"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(serviceClass),
                &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dictionary = properties?.takeRetainedValue() as? [String: Any],
                      let statistics = dictionary["PerformanceStatistics"] as? [String: Any] else { continue }

                let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]
                if let utilization = keys.compactMap({ statistics[$0] as? Int }).first {
                    readings.append(min(max(Double(utilization) / 100, 0), 1))
                }
            }
        }
        cachedGPUUsage = readings.max()
        return cachedGPUUsage
    }
}
