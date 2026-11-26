import SimulatorCore
import SwiftUI

/// Create a simulator from an installed runtime and one of the device types it supports.
struct NewDeviceSheet: View {
    @ObservedObject var store: SimulatorStore
    let created: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var runtimeID = ""
    @State private var deviceTypeID = ""
    /// Empty until the person types one. The device type's name is shown as the hint and used
    /// when it stays empty, so the hint follows the device picker.
    @State private var name = ""
    @State private var isCreating = false
    @State private var disabledServices: Set<ServiceGroup> = []

    private var runtime: SimRuntimeInfo? { store.runtimes.first { $0.identifier == runtimeID } }
    private var types: [SimDeviceTypeInfo] { runtime.map(store.deviceTypes(for:)) ?? [] }
    private var suggestedName: String { types.first { $0.identifier == deviceTypeID }?.name ?? "" }
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? suggestedName : typed
    }

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
                    TextField("Name", text: $name, prompt: Text(suggestedName))
                    Toggle("Lightweight", isOn: Binding(
                        get: { !disabledServices.isEmpty },
                        set: { disabledServices = $0 ? Set(ServiceGroup.allCases) : [] }
                    ))
                    .help("Turn off background services most apps don't use, to save memory and CPU")
                }
                .frame(width: 360)

                if !disabledServices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turned off on first boot. Change it later with Background Services in the device's menu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            ServiceGroupsPicker(disabled: $disabledServices)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 260)
                    }
                    .frame(width: 360)
                }
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || runtime == nil || deviceTypeID.isEmpty
                              || effectiveName.isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: chooseDefaults)
        .onChange(of: runtimeID) { _, _ in
            if !types.contains(where: { $0.identifier == deviceTypeID }) {
                deviceTypeID = types.first?.identifier ?? ""
            }
        }
    }

    private func chooseDefaults() {
        if runtimeID.isEmpty { runtimeID = store.runtimes.first?.identifier ?? "" }
        if deviceTypeID.isEmpty { deviceTypeID = types.first?.identifier ?? "" }
    }

    private func create() {
        isCreating = true
        let name = effectiveName
        Task {
            let udid = await store.create(
                name: name, deviceType: deviceTypeID, runtime: runtimeID, disabledServices: disabledServices
            )
            isCreating = false
            if let udid {
                created(udid)
                dismiss()
            }
        }
    }
}
