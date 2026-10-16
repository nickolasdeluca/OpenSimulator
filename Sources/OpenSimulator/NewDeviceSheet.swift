import SimulatorCore
import SwiftUI

/// Create a simulator from an installed runtime and one of the device types it supports.
struct NewDeviceSheet: View {
    @ObservedObject var store: SimulatorStore
    let created: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runtimeID = ""
    @State private var deviceTypeID = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var isCreating = false

    private var runtime: SimRuntimeInfo? { store.runtimes.first { $0.identifier == runtimeID } }
    private var types: [SimDeviceTypeInfo] { runtime.map(store.deviceTypes(for:)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Simulator").font(.headline)

            if store.runtimes.isEmpty {
                Text("No simulator runtimes are installed. Add one in Xcode › Settings › Components.")
                    .foregroundStyle(.secondary)
                    .frame(width: 340, alignment: .leading)
            } else {
                Form {
                    Picker("OS Version", selection: $runtimeID) {
                        ForEach(store.runtimes) { Text($0.name).tag($0.identifier) }
                    }
                    Picker("Device", selection: $deviceTypeID) {
                        ForEach(types) { Text($0.name).tag($0.identifier) }
                    }
                    TextField("Name", text: Binding(
                        get: { name },
                        set: { name = $0; nameEdited = true }
                    ))
                }
                .frame(width: 360)
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || runtime == nil || deviceTypeID.isEmpty
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: chooseDefaults)
        .onChange(of: runtimeID) { _, _ in
            if !types.contains(where: { $0.identifier == deviceTypeID }) {
                deviceTypeID = types.first?.identifier ?? ""
            }
        }
        .onChange(of: deviceTypeID) { _, newValue in
            if !nameEdited { name = types.first { $0.identifier == newValue }?.name ?? "" }
        }
    }

    private func chooseDefaults() {
        if runtimeID.isEmpty { runtimeID = store.runtimes.first?.identifier ?? "" }
        if deviceTypeID.isEmpty { deviceTypeID = types.first?.identifier ?? "" }
        if name.isEmpty { name = types.first { $0.identifier == deviceTypeID }?.name ?? "" }
    }

    private func create() {
        isCreating = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            let udid = await store.create(name: trimmed, deviceType: deviceTypeID, runtime: runtimeID)
            isCreating = false
            if let udid {
                created(udid)
                dismiss()
            }
        }
    }
}
