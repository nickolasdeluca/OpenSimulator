import SimBridge
import SimulatorCore
import SwiftUI

/// One checkbox per service group, checked when the group is turned off.
struct ServiceGroupsPicker: View {
    @Binding var disabled: Set<ServiceGroup>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ServiceGroup.allCases) { group in
                Toggle(isOn: Binding(
                    get: { disabled.contains(group) },
                    set: { if $0 { disabled.insert(group) } else { disabled.remove(group) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.title)
                        Text("Breaks: \(group.breaks)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

/// Changes which service groups an existing simulator runs.
struct BackgroundServicesSheet: View {
    @ObservedObject var store: SimulatorStore
    let device: DeviceSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var disabled: Set<ServiceGroup> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background Services for \(device.name)").font(.headline)
            Text("Checked services are turned off. Apps that use them won't work on this simulator.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                ServiceGroupsPicker(disabled: $disabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)

            Text(device.state == .booted
                 ? "Services you turn off stop now. Services you turn back on start when the simulator restarts."
                 : "Changes apply the next time the simulator boots.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(disabled.count == ServiceGroup.allCases.count ? "Turn All On" : "Turn All Off") {
                    disabled = disabled.count == ServiceGroup.allCases.count ? [] : Set(ServiceGroup.allCases)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    store.setDisabledServiceGroups(disabled, for: device.udid)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled == store.disabledServiceGroups(for: device.udid))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { disabled = store.disabledServiceGroups(for: device.udid) }
    }
}
