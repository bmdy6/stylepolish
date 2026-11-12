import SwiftUI

enum PolishTheme {
    static let ink = Color(red: 29/255, green: 29/255, blue: 36/255)
    static let sub = Color(red: 107/255, green: 107/255, blue: 120/255)
    static let line = Color(red: 227/255, green: 227/255, blue: 234/255)
    static let indigo = Color(red: 79/255, green: 70/255, blue: 229/255)
    static let soft = Color(red: 238/255, green: 237/255, blue: 253/255)
    static let green = Color(red: 22/255, green: 163/255, blue: 74/255)
}
struct PolishButton: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 12 : 13, weight: .semibold)).padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 4 : 8)
            .foregroundColor(primary ? .white : PolishTheme.ink)
            .background(primary ? PolishTheme.indigo : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? PolishTheme.indigo : PolishTheme.line))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct PolishSegments<Value: Hashable>: View {
    var values: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    Text(title(value)).font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 4).padding(.horizontal, 4)
                        .foregroundColor(selection == value ? .white : PolishTheme.ink)
                        .background(selection == value ? PolishTheme.indigo : .white)
                }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }.clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(PolishTheme.line))
    }
}
