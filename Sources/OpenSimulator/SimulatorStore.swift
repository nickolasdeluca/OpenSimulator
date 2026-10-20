import AppKit
import Combine
import SimBridge
import SimulatorCore

/// The app's single source of truth for simulators. Device state comes from CoreSimulator's own
/// change notifications, so nothing polls while nothing changes.
@MainActor
final class SimulatorStore: ObservableObject {
    struct RuntimeGroup: Identifiable {
        let id: String
        let name: String
        let devices: [DeviceSnapshot]
    }

    let core: CoreSimulator
    let simctl: Simctl

    @Published private(set) var devices: [DeviceSnapshot] = []
    @Published private(set) var runtimes: [SimRuntimeInfo] = []
    @Published private(set) var deviceTypes: [SimDeviceTypeInfo] = []
    @Published private(set) var usage: [String: ResourceUsage] = [:]
    /// UDIDs with a lifecycle command in flight, so the UI can show a spinner and refuse repeats.
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: String?

    private var observerToken: UInt = 0
    private var refreshScheduled = false
    private let monitor = ResourceMonitor()
    private var monitorTimer: Timer?
    private var monitorClients = 0
    private var applyingServices: Set<String> = []

    init(core: CoreSimulator, simctl: Simctl) {
        self.core = core
        self.simctl = simctl
        observerToken = core.addDeviceObserver { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        refresh()
        Task { await loadCatalog() }
    }

    func device(_ udid: String) -> DeviceSnapshot? {
        devices.first { $0.udid == udid }
    }

    var groups: [RuntimeGroup] {
        let grouped = Dictionary(grouping: devices.filter(\.isAvailable)) { $0.runtimeIdentifier }
        return grouped
            .map { key, value in
                RuntimeGroup(
                    id: key,
                    name: value.first?.runtimeName ?? key,
                    devices: value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                )
            }
            // Newest runtime first, as Xcode lists them.
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    var unavailableDevices: [DeviceSnapshot] { devices.filter { !$0.isAvailable } }
    var bootedDevices: [DeviceSnapshot] { devices.filter { $0.state == .booted } }

    // MARK: Refresh

    /// CoreSimulator sends a burst of notifications for one boot, so they are folded into one read.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        devices = core.devices()
        NotificationCenter.default.post(name: .simulatorDevicesChanged, object: self)
        applyPendingServices()
    }

    func loadCatalog() async {
        do {
            async let runtimes = simctl.runtimes()
            async let types = simctl.deviceTypes()
            self.runtimes = try await runtimes.filter(\.isAvailable)
            self.deviceTypes = try await types
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Device types a runtime can run, as the runtime itself reports them.
    func deviceTypes(for runtime: SimRuntimeInfo) -> [SimDeviceTypeInfo] {
        runtime.supportedDeviceTypes ?? deviceTypes
    }

    // MARK: Resource usage

    /// Starts sampling while at least one client (a visible window) wants numbers.
    func beginMonitoring() {
        monitorClients += 1
        guard monitorTimer == nil else { return }
        sampleUsage()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleUsage() }
        }
        monitorTimer?.tolerance = 1
    }

    func endMonitoring() {
        monitorClients = max(monitorClients - 1, 0)
        guard monitorClients == 0 else { return }
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    private func sampleUsage() {
        let udids = Set(bootedDevices.map(\.udid))
        let monitor = monitor
        Task.detached(priority: .utility) {
            let sample = monitor.sample(udids: udids)
            await MainActor.run { [weak self] in self?.usage = sample }
        }
    }

    var totalUsage: ResourceUsage {
        usage.values.reduce(.zero) { total, next in
            ResourceUsage(
                residentBytes: total.residentBytes + next.residentBytes,
                footprintBytes: total.footprintBytes + next.footprintBytes,
                cpuPercent: total.cpuPercent + next.cpuPercent,
                processCount: total.processCount + next.processCount
            )
        }
    }

    // MARK: Actions

    /// Runs a lifecycle command for a device, reporting failure in `lastError`.
    @discardableResult
    func perform(_ udid: String?, _ action: @escaping (Simctl) async throws -> Void) async -> Bool {
        if let udid {
            guard !busy.contains(udid) else { return false }
            busy.insert(udid)
        }
        defer {
            if let udid { busy.remove(udid) }
            refresh()
        }
        do {
            try await action(simctl)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func boot(_ udid: String) async -> Bool {
        await perform(udid) { try await $0.waitUntilBooted(udid) }
    }

    func shutdown(_ udid: String) async {
        await perform(udid) { try await $0.shutdown(udid) }
    }

    func shutdownAll() async {
        await perform(nil) { try await $0.shutdownAll() }
    }

    func erase(_ udid: String) async {
        willErase(udid)
        let wasBooted = device(udid)?.state == .booted
        await perform(udid) { simctl in
            if wasBooted { try await simctl.shutdown(udid) }
            try await simctl.erase(udid)
        }
    }

    func delete(_ udid: String) async {
        let deleted = await perform(udid) { simctl in
            // Fails harmlessly when the device is already shut down.
            _ = try? await simctl.shutdown(udid)
            try await simctl.delete(udid)
        }
        if deleted {
            Preferences.setDisabledServiceGroups([], for: udid)
            Preferences.servicesToApply.remove(udid)
        }
    }

    func rename(_ udid: String, to name: String) async {
        await perform(udid) { try await $0.rename(udid, to: name) }
    }

    /// `disabledServices` are applied on the device's first boot.
    func create(
        name: String, deviceType: String, runtime: String, disabledServices: Set<ServiceGroup> = []
    ) async -> String? {
        var created: String?
        await perform(nil) { created = try await $0.create(name: name, deviceType: deviceType, runtime: runtime) }
        if let created, !disabledServices.isEmpty {
            setDisabledServiceGroups(disabledServices, for: created)
        }
        return created
    }

    // MARK: Lightweight

    func disabledServiceGroups(for udid: String) -> Set<ServiceGroup> {
        Preferences.disabledServiceGroups(for: udid)
    }

    /// Records the choice and applies it now if the device is running, otherwise at its next boot.
    /// Turned-off services stop right away; turned-on ones start at the next boot.
    func setDisabledServiceGroups(_ groups: Set<ServiceGroup>, for udid: String) {
        Preferences.setDisabledServiceGroups(groups, for: udid)
        Preferences.servicesToApply.insert(udid)
        applyPendingServices()
    }

    /// Erasing clears the device's launchd overrides, so the choice is applied again on next boot.
    func willErase(_ udid: String) {
        if !disabledServiceGroups(for: udid).isEmpty { Preferences.servicesToApply.insert(udid) }
    }

    private func applyPendingServices() {
        let pending = Preferences.servicesToApply
        for device in bootedDevices
        where pending.contains(device.udid) && !busy.contains(device.udid) && !applyingServices.contains(device.udid) {
            let udid = device.udid
            let groups = disabledServiceGroups(for: udid)
            applyingServices.insert(udid)
            Task {
                do {
                    try await simctl.waitUntilBooted(udid)
                    try await simctl.applyServiceGroups(udid, disabled: groups)
                    if disabledServiceGroups(for: udid) == groups { Preferences.servicesToApply.remove(udid) }
                } catch {
                    // A device shut down mid-way just tries again at its next boot.
                    if self.device(udid)?.state == .booted {
                        lastError = "Background services weren't changed: \(error.localizedDescription)"
                    }
                }
                applyingServices.remove(udid)
                // The choice changed while this ran.
                if disabledServiceGroups(for: udid) != groups { applyPendingServices() }
            }
        }
    }
}

extension Notification.Name {
    static let simulatorDevicesChanged = Notification.Name("OpenSimulator.devicesChanged")
}

extension DeviceState {
    var title: String {
        switch self {
        case .creating: "Creating"
        case .shutdown: "Shut Down"
        case .booting: "Booting"
        case .booted: "Booted"
        case .shuttingDown: "Shutting Down"
        @unknown default: "Unknown"
        }
    }
}

extension DeviceSnapshot: @retroactive Identifiable {
    public var id: String { udid }
}
