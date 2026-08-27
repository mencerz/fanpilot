import Foundation
import os
import IOKit

private let frequencyLog = Logger(subsystem: "com.oleksii.baliuk.fanpilot.app", category: "frequency")

struct ClusterFrequency: Equatable, Sendable {
    let name: String
    /// Average frequency while the cluster was actually running, the same
    /// figure powermetrics calls "HW active frequency".
    let megahertz: Double
    let maximumMegahertz: Double

    var loadRatio: Double {
        maximumMegahertz > 0 ? min(megahertz / maximumMegahertz, 1) : 0
    }
}

/// Apple Silicon publishes no frequency counter, but it does publish how long
/// each cluster spent in each DVFS state (IOReport) and what those states run
/// at (the pmgr voltage tables). Combining the two gives the real clock.
///
/// IOReport is unexported C API reached through dlsym: every step degrades to
/// nil rather than trapping, so a future macOS that moves it just turns the
/// frequency charts off.
final class CPUFrequencyReader: @unchecked Sendable {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let channelName: ChannelString
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency

    private let subscription: OpaquePointer
    private let subscribedChannels: CFMutableDictionary
    private let frequencyTables: [String: [Double]]
    private var previousSample: CFDictionary?

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            frequencyLog.error("dlopen(libIOReport) failed: \(reason, privacy: .public)")
            return nil
        }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(library, name) }
        guard let copyGroupSymbol = symbol("IOReportCopyChannelsInGroup"),
              let createSubscriptionSymbol = symbol("IOReportCreateSubscription"),
              let createSamplesSymbol = symbol("IOReportCreateSamples"),
              let createSamplesDeltaSymbol = symbol("IOReportCreateSamplesDelta"),
              let channelNameSymbol = symbol("IOReportChannelGetChannelName"),
              let stateCountSymbol = symbol("IOReportStateGetCount"),
              let stateNameSymbol = symbol("IOReportStateGetNameForIndex"),
              let stateResidencySymbol = symbol("IOReportStateGetResidency") else {
            frequencyLog.error("IOReport symbols missing")
            return nil
        }

        let copyChannelsInGroup = unsafeBitCast(copyGroupSymbol, to: CopyChannelsInGroup.self)
        let createSubscription = unsafeBitCast(createSubscriptionSymbol, to: CreateSubscription.self)
        createSamples = unsafeBitCast(createSamplesSymbol, to: CreateSamples.self)
        createSamplesDelta = unsafeBitCast(createSamplesDeltaSymbol, to: CreateSamplesDelta.self)
        channelName = unsafeBitCast(channelNameSymbol, to: ChannelString.self)
        stateCount = unsafeBitCast(stateCountSymbol, to: StateCount.self)
        stateName = unsafeBitCast(stateNameSymbol, to: StateName.self)
        stateResidency = unsafeBitCast(stateResidencySymbol, to: StateResidency.self)

        guard let channels = copyChannelsInGroup(
            "CPU Stats" as CFString,
            "CPU Complex Performance States" as CFString,
            0, 0, 0
        )?.takeRetainedValue() else {
            frequencyLog.error("No channels in CPU Complex Performance States")
            return nil
        }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribed, 0, nil),
              let subscribedChannels = subscribed?.takeRetainedValue() else {
            frequencyLog.error("IOReport subscription failed")
            return nil
        }
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels

        let tables = Self.readFrequencyTables()
        guard !tables.isEmpty else {
            frequencyLog.error("pmgr voltage tables unavailable")
            return nil
        }
        frequencyTables = tables
        frequencyLog.notice("Frequency reader ready: \(tables.keys.sorted().joined(separator: ", "), privacy: .public)")
    }

    /// Returns one entry per cluster for the interval since the previous call;
    /// the first call only primes the baseline.
    func read() -> [ClusterFrequency] {
        guard let current = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else { return [] }
        defer { previousSample = current }
        guard let previous = previousSample,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            frequencyLog.debug("No delta channels yet")
            return []
        }

        return channels.compactMap { channel -> ClusterFrequency? in
            let dictionary = channel as CFDictionary
            guard let name = channelName(dictionary)?.takeUnretainedValue() as String?,
                  let table = frequencyTables[name] else { return nil }

            // A negative count would make the range below trap, which this
            // file's whole contract is to avoid.
            let count = max(Int(stateCount(dictionary)), 0)
            var weighted = 0.0
            var total = 0.0
            for index in 0..<count {
                let state = stateName(dictionary, Int32(index))?.takeUnretainedValue() as String? ?? ""
                guard !state.hasPrefix("IDLE"), !state.hasPrefix("DOWN"), !state.hasPrefix("OFF") else { continue }
                let residency = Double(stateResidency(dictionary, Int32(index)))
                guard residency > 0, index < table.count else { continue }
                weighted += residency * table[index]
                total += residency
            }
            guard total > 0 else {
                return ClusterFrequency(name: name, megahertz: 0, maximumMegahertz: table.max() ?? 0)
            }
            return ClusterFrequency(
                name: name,
                megahertz: weighted / total,
                maximumMegahertz: table.max() ?? 0
            )
        }
    }

    /// pmgr stores one table per cluster, in kHz, paired with the voltage.
    private static func readFrequencyTables() -> [String: [Double]] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var tables: [String: [Double]] = [:]
        for (channel, key) in [("ECPU", "voltage-states1-sram"), ("PCPU", "voltage-states5-sram")] {
            guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
                  let data = property.takeRetainedValue() as? Data else { continue }
            var frequencies: [Double] = []
            var offset = 0
            while offset + 8 <= data.count {
                let kilohertz = data.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
                frequencies.append(Double(kilohertz) / 1000)
                offset += 8
            }
            if !frequencies.isEmpty { tables[channel] = frequencies }
        }
        return tables
    }
}
