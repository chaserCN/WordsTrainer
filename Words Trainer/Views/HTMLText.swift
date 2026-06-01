import SwiftUI
import UIKit

/// Renders a small HTML fragment (Anki fields: `<b>`, `<br>`, etc.).
struct HTMLText: View {
    let html: String
    var foregroundColor: Color?
    var font: Font?
    /// Цвет для выделенного (`<b>`/`<strong>`) текста. Если nil — общий цвет.
    var emphasisColor: Color?

    var body: some View {
        if let styled = Self.styled(
            from: html,
            foregroundColor: foregroundColor,
            font: font,
            emphasisColor: emphasisColor
        ) {
            Text(styled)
        } else {
            Text(html)
                .foregroundStyle(foregroundColor ?? .primary)
                .font(font)
        }
    }

    private static func styled(
        from html: String,
        foregroundColor: Color?,
        font: Font?,
        emphasisColor: Color?
    ) -> AttributedString? {
        guard let data = html.data(using: .utf8),
              let ns = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              )
        else { return nil }

        // HTML-парсер добавляет завершающий перенос строки — убираем хвостовые пробелы/переносы.
        let mutable = NSMutableAttributedString(attributedString: ns)
        while mutable.length > 0,
              let scalar = mutable.string.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        }

        var result = AttributedString()
        mutable.enumerateAttributes(in: NSRange(location: 0, length: mutable.length)) { attrs, range, _ in
            var piece = AttributedString(mutable.attributedSubstring(from: range).string)
            // Жирность HTML хранится как трейт UIFont, а не inlinePresentationIntent.
            let isBold = (attrs[.font] as? UIFont)?
                .fontDescriptor.symbolicTraits.contains(.traitBold) ?? false

            if let font {
                piece.font = isBold ? font.weight(.bold) : font
            }
            if isBold, let emphasisColor {
                piece.foregroundColor = emphasisColor
            } else if let foregroundColor {
                piece.foregroundColor = foregroundColor
            }
            result.append(piece)
        }
        return result
    }
}
