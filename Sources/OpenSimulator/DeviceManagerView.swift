import AppKit
import SimBridge
import SimulatorCore
import SwiftUI

/// Every simulator, grouped by iOS version, with what each running one costs the Mac.
struct DeviceManagerView: View {
    @ObservedObject var store: SimulatorStore
    @ObservedObject var updates: UpdateController
    let open: (String) -> Void

    @State private var selection: String?
    @State private var showingNewDevice = false
    @State private var renaming: DeviceSnapshot?
    @State private var newName = ""
    @State private var confirming: Confirmation?
    @State private var editingServices: DeviceSnapshot?

    struct Confirmation: Identifiable {
        enum Kind { case erase, delete }
        let kind: Kind
        let device: DeviceSnapshot
        var id: String { "\(kind)-\(device.udid)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let banner = updates.banner {
                UpdateBanner(state: banner, updates: updates)
                Divider()
            }
            if store.devices.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 320)
        .toolbar {
            ToolbarItemGroup {
                Button { showingNewDevice = true } label: { Label("New Simulator", systemImage: "plus") }
                    .help("Create a simulator")
                Button { Task { await store.shutdownAll() } } label: { Label("Shut Down All", systemImage: "power") }
                    .help("Shut down every running simulator")
                    .disabled(store.bootedDevices.isEmpty)
            }
        }
        .sheet(isPresented: $showingNewDevice) {
            NewDeviceSheet(store: store) { udid in
                selection = udid
            }
        }
        .sheet(item: $renaming) { device in
            renameSheet(device)
        }
        .sheet(item: $editingServices) { device in
            BackgroundServicesSheet(store: store, device: device)
        }
        .alert(item: $confirming) { confirmation in
            confirmationAlert(confirmation)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewSimulator)) { _ in
            showingNewDevice = true
        }
        .onAppear { store.beginMonitoring() }
        .onDisappear { store.endMonitoring() }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.groups) { group in
                Section(group.name) {
                    ForEach(group.devices, id: \.udid) { device in
                        DeviceRow(
                            device: device,
                            usage: store.usage[device.udid],
                            isBusy: store.busy.contains(device.udid),
                            open: { open(device.udid) },
                            shutdown: { Task { await store.shutdown(device.udid) } }
                        )
                        .tag(device.udid)
                        .contextMenu { menu(for: device) }
                    }
                }
            }
            if !store.unavailableDevices.isEmpty {
                Section("Unavailable (runtime not installed)") {
                    ForEach(store.unavailableDevices, id: \.udid) { device in
                        DeviceRow(device: device, usage: nil, isBusy: store.busy.contains(device.udid), open: {}, shutdown: {})
                            .tag(device.udid)
                            .contextMenu { menu(for: device) }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { udids in
            udids.forEach(open)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No simulators yet")
                .font(.headline)
            Text("Create one to get started. Simulators are shared with Xcode.")
                .foregroundStyle(.secondary)
            Button("New Simulator…") { showingNewDevice = true }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 16) {
            let booted = store.bootedDevices.count
            Text(booted == 0 ? "Nothing running" : "\(booted) running")
            if booted > 0 {
                let total = store.totalUsage
                Label(Format.memory(total.residentBytes), systemImage: "memorychip")
                    .help("RAM used by all running simulators. Footprint: \(Format.memory(total.footprintBytes)), counting compressed memory at full size")
                Label(Format.cpu(total.cpuPercent), systemImage: "cpu")
                    .help("CPU used by all running simulators, where 100% is one core")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func menu(for device: DeviceSnapshot) -> some View {
        if device.isAvailable {
            Button("Open") { open(device.udid) }
            if device.state == .booted {
                Button("Shut Down") { Task { await store.shutdown(device.udid) } }
            } else if device.state == .shutdown {
                Button("Boot Without Window") { Task { await store.boot(device.udid) } }
            }
            Divider()
            Button("Rename…") {
                newName = device.name
                renaming = device
            }
            Button("Background Services…") { editingServices = device }
            Button("Erase All Content and Settings…") { confirming = Confirmation(kind: .erase, device: device) }
        }
        Button("Copy Identifier") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.udid, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { confirming = Confirmation(kind: .delete, device: device) }
    }

    private func renameSheet(_ device: DeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Simulator").font(.headline)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    renaming = nil
                    guard !name.isEmpty else { return }
                    Task { await store.rename(device.udid, to: name) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func confirmationAlert(_ confirmation: Confirmation) -> Alert {
        let device = confirmation.device
        switch confirmation.kind {
        case .erase:
            return Alert(
                title: Text("Erase \(device.name)?"),
                message: Text("Every app, file and setting on this simulator will be removed."),
                primaryButton: .destructive(Text("Erase")) { Task { await store.erase(device.udid) } },
                secondaryButton: .cancel()
            )
        case .delete:
            return Alert(
                title: Text("Delete \(device.name)?"),
                message: Text("The simulator and everything on it will be removed. Xcode will no longer list it."),
                primaryButton: .destructive(Text("Delete")) { Task { await store.delete(device.udid) } },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceSnapshot
    let usage: ResourceUsage?
    let isBusy: Bool
    let open: () -> Void
    let shutdown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.deviceTypeIdentifier.contains("iPad") ? "ipad" : "iphone")
                .font(.title2)
                .foregroundStyle(device.state == .booted ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body)
                HStack(spacing: 8) {
                    StateBadge(state: device.state)
                    if let usage, device.state == .booted {
                        Text("\(Format.memory(usage.residentBytes)) · \(Format.cpu(usage.cpuPercent)) CPU")
                            .monospacedDigit()
                            .help("Footprint: \(Format.memory(usage.footprintBytes)), counting compressed memory at full size")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isBusy || device.state == .booting || device.state == .shuttingDown {
                ProgressView().controlSize(.small)
            } else if device.isAvailable {
                if device.state == .booted {
                    Button("Shut Down", action: shutdown)
                        .controlSize(.small)
                }
                Button(device.state == .booted ? "Show" : "Open", action: open)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct StateBadge: View {
    let state: DeviceState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state == .booted ? Color.green : state == .shutdown ? Color.secondary.opacity(0.5) : Color.orange)
                .frame(width: 6, height: 6)
            Text(state.title)
        }
    }
}

enum Format {
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func cpu(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }
}

/// Offers a newer release above the device list, and reports how installing it went.
private struct UpdateBanner: View {
    let state: UpdateController.State
    let updates: UpdateController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isFailure ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .available, .failed:
                Button("Release Notes") { NSWorkspace.shared.open(Updates.releasesPage) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                Button("Later") { updates.dismiss() }
                    .controlSize(.small)
                Button(isFailure ? "Try Again" : "Update") { updates.install() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            case .installing:
                ProgressView().controlSize(.small)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private var icon: String {
        isFailure ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill"
    }

    private var title: String {
        switch state {
        case .available(let manifest): "OpenSimulator \(manifest.version) is available"
        case .installing(let manifest): "Installing OpenSimulator \(manifest.version)…"
        case .failed(let manifest, _): "OpenSimulator \(manifest.version) couldn't be installed"
        case .idle: ""
        }
    }

    private var detail: String {
        switch state {
        case .available: "You have \(UpdateController.currentVersion). Running simulators keep running while it restarts."
        case .installing: "OpenSimulator restarts when it's done."
        case .failed(_, let message): message
        case .idle: ""
        }
    }
}
