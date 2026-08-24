import SwiftUI

enum ODTheme {
    static let background = Color(red: 13/255, green: 17/255, blue: 23/255)
    static let panel = Color(red: 22/255, green: 27/255, blue: 34/255)
    static let accent = Color(red: 47/255, green: 129/255, blue: 247/255)
    static let good = Color(red: 63/255, green: 185/255, blue: 80/255)
    static let warn = Color(red: 210/255, green: 153/255, blue: 34/255)
    static let warning = warn
    static let muted = Color(red: 139/255, green: 148/255, blue: 158/255)
    static let grid = Color(red: 48/255, green: 54/255, blue: 61/255)
    static let mapLand = Color(red: 44/255, green: 74/255, blue: 99/255)
    static let passElevationMid = Color(red: 0.23, green: 0.36, blue: 0.65)
    static let globeOcean = Color(red: 0.04, green: 0.10, blue: 0.17)
}

extension View {
    func odPanel() -> some View {
        self
            .padding(14)
            .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ODTheme.grid, lineWidth: 1)
            )
    }
}

/// A themed text-field treatment: a filled, hairline-bordered box so any field
/// that accepts typed input reads as obviously editable against the dark panels,
/// while staying visually quiet.
struct ODFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ODTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ODTheme.grid, lineWidth: 1)
            )
    }
}

extension TextFieldStyle where Self == ODFieldStyle {
    static var odField: ODFieldStyle { ODFieldStyle() }
}

struct MetricRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(ODTheme.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// The majority of call sites pass label and value positionally. Declaring the
// convenience initializer in an extension keeps the compiler-synthesized
// memberwise `init(label:value:valueColor:)` available for the call sites that
// use it.
extension MetricRow {
    init(_ label: String, _ value: String, valueColor: Color = .primary) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(ODTheme.accent)
            Divider().overlay(ODTheme.grid)
            content
        }
        .odPanel()
    }
}

