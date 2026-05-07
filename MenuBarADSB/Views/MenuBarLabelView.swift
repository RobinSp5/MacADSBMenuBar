import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var store: AircraftStore
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "airplane")
            if let featured = settings.menuBarSelection.selectFeatured(from: store.aircraft) {
                Text(label(for: featured))
                    .font(.system(size: 12))
            }
        }
    }

    private func label(for aircraft: Aircraft) -> String {
        var parts: [String] = [aircraft.identifier]
        for field in DisplayField.canonicalOrder where settings.menuBarFields.contains(field) {
            if let value = aircraft.formattedValue(for: field) {
                parts.append(value)
            }
        }
        return parts.joined(separator: " · ")
    }
}
