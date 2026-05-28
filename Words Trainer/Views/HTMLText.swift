import SwiftUI

/// Renders a small HTML fragment (Anki fields: `<b>`, `<br>`, etc.).
struct HTMLText: View {
    let html: String

    var body: some View {
        if let attributed = Self.attributedString(from: html) {
            Text(attributed)
        } else {
            Text(html)
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
}
