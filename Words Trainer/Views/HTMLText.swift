import SwiftUI

/// Renders a small HTML fragment (Anki fields: `<b>`, `<br>`, etc.).
struct HTMLText: View {
    let html: String
    var foregroundColor: Color?

    var body: some View {
        if let attributed = Self.attributedString(from: html) {
            Text(Self.applyingStyle(to: attributed, foregroundColor: foregroundColor))
        } else {
            Text(html)
                .foregroundStyle(foregroundColor ?? .primary)
        }
    }

    private static func attributedString(from html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return AttributedString(ns)
    }

    private static func applyingStyle(to attributedString: AttributedString, foregroundColor: Color?) -> AttributedString {
        var attributedString = attributedString
        attributedString.font = nil
        attributedString.foregroundColor = foregroundColor
        return attributedString
    }
}
