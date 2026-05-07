import SwiftUI
import Combine
import AppKit

struct MenuBarContentView: View {
    @ObservedObject var store: AircraftStore
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 360)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        if store.aircraft.isEmpty {
            emptyOrErrorView
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.aircraft, id: \.hex) { ac in
                        AircraftRow(aircraft: ac, fields: settings.dropdownFields)
                            .opacity(store.isStale ? 0.5 : 1.0)
                            .contentShape(Rectangle())
                            .onTapGesture { open(aircraft: ac) }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if store.lastError != nil, store.aircraft.isEmpty {
            Text("Cannot reach adsb.lol")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("No aircraft within \(formatRadius()) radius.")
                    .foregroundStyle(.secondary)
                if let last = store.lastFetchAt {
                    Text("Updated \(secondsAgo(last)) s ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formatRadius() -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.maximumFractionDigits = 1
        let s = f.string(from: NSNumber(value: settings.radiusKm)) ?? "\(settings.radiusKm)"
        return "\(s) km"
    }

    private func secondsAgo(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date)))
    }

    private func open(aircraft: Aircraft) {
        let url: URL?
        if let cs = aircraft.callsign, !cs.isEmpty {
            url = URL(string: "https://www.flightradar24.com/\(cs)")
        } else {
            url = URL(string: "https://globe.adsb.lol/?icao=\(aircraft.hex)")
        }
        if let url { NSWorkspace.shared.open(url) }
    }
}

private struct AircraftRow: View {
    let aircraft: Aircraft
    let fields: Set<DisplayField>

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(aircraft.identifier)
                    .font(.system(size: 13, weight: .semibold))
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if fields.contains(.distance), let distance = aircraft.formattedValue(for: .distance) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(distance)
                        .font(.system(size: 13, weight: .medium))
                    if fields.contains(.heading), let heading = aircraft.formattedValue(for: .heading) {
                        Text(heading)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Left-side fields (everything except distance and heading, which render right).
    private var secondaryLine: String? {
        let leftSideFields: [DisplayField] = [.airline, .route, .aircraftType, .altitude, .speed]
        let parts = leftSideFields
            .filter { fields.contains($0) }
            .compactMap { aircraft.formattedValue(for: $0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
