import SwiftUI

/// Renders a small HTML fragment (Anki fields: `<b>`, `<br>`, etc.).
struct HTMLText: View {
    let html: String
    var foregroundColor: Color?
    var font: Font?

    var body: some View {
        if let attributed = Self.attributedString(from: html) {
            Text(Self.applyingStyle(to: attributed, foregroundColor: foregroundColor, font: font))
        } else {
            Text(html)
                .foregroundStyle(foregroundColor ?? .primary)
                .font(font)
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

    private static func applyingStyle(
        to attributedString: AttributedString,
        foregroundColor: Color?,
        font: Font?
    ) -> AttributedString {
        var result = attributedString
        for run in result.runs {
            if let foregroundColor {
                result[run.range].foregroundColor = foregroundColor
            }
            if let font {
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                    result[run.range].font = font.weight(.bold)
                } else {
                    result[run.range].font = font
                }
            }
        }
        return result
    }
}
