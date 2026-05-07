import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Radius") {
                VStack(alignment: .leading) {
                    Slider(value: $settings.radiusKm, in: 1...50, step: 0.5)
                    Text(formatRadius())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Update interval") {
                VStack(alignment: .leading) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.updateIntervalSec) },
                            set: { settings.updateIntervalSec = Int($0) }
                        ),
                        in: 5...60, step: 1
                    )
                    Text("every \(settings.updateIntervalSec) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Toggle("Notify on new aircraft", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, newValue in
                        if newValue {
                            Task { await NotificationService().requestAuthorizationIfNeeded() }
                        }
                    }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        LaunchAtLoginService.setEnabled(newValue)
                    }
            }

            Section("Menu bar selection") {
                Picker("Featured", selection: $settings.menuBarSelection) {
                    ForEach(MenuBarSelection.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section("Menu bar display") {
                Label("Identifier (always on)", systemImage: "checkmark.square.fill")
                    .foregroundStyle(.secondary)
                Toggle("Airline", isOn: menuBarBinding(for: .airline))
                Toggle("Route", isOn: menuBarBinding(for: .route))
                Toggle("Aircraft type", isOn: menuBarBinding(for: .aircraftType))
                Toggle("Altitude", isOn: menuBarBinding(for: .altitude))
                Toggle("Speed", isOn: menuBarBinding(for: .speed))
                Toggle("Distance", isOn: menuBarBinding(for: .distance))
                Toggle("Heading", isOn: menuBarBinding(for: .heading))
            }

            Section("Dropdown list") {
                Label("Identifier (always on)", systemImage: "checkmark.square.fill")
                    .foregroundStyle(.secondary)
                Toggle("Airline", isOn: dropdownBinding(for: .airline))
                Toggle("Route", isOn: dropdownBinding(for: .route))
                Toggle("Aircraft type", isOn: dropdownBinding(for: .aircraftType))
                Toggle("Altitude", isOn: dropdownBinding(for: .altitude))
                Toggle("Speed", isOn: dropdownBinding(for: .speed))
                Toggle("Distance", isOn: dropdownBinding(for: .distance))
                Toggle("Heading", isOn: dropdownBinding(for: .heading))
            }

            Section("Data sources") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aircraft positions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("adsb.lol", destination: URL(string: "https://www.adsb.lol")!)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Airline & route (callsign lookup)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("adsbdb.com", destination: URL(string: "https://www.adsbdb.com")!)
                            .font(.caption)
                    }
                    Text("Data is fetched live from the public APIs above. Nothing is stored locally.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 540)
    }

    private func menuBarBinding(for field: DisplayField) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarFields.contains(field) },
            set: { isOn in
                if isOn { settings.menuBarFields.insert(field) }
                else    { settings.menuBarFields.remove(field) }
            }
        )
    }

    private func dropdownBinding(for field: DisplayField) -> Binding<Bool> {
        Binding(
            get: { settings.dropdownFields.contains(field) },
            set: { isOn in
                if isOn { settings.dropdownFields.insert(field) }
                else    { settings.dropdownFields.remove(field) }
            }
        )
    }

    private func formatRadius() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        let s = f.string(from: NSNumber(value: settings.radiusKm)) ?? "\(settings.radiusKm)"
        return "\(s) km"
    }
}
