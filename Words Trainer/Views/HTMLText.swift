import SwiftUI
/// Renders a small HTML fragment (Anki fields: `<b>`, `<br>`, etc.).
struct HTMLText: View {
    let html: String
    var foregroundColor: Color?
    var font: Font?
    /// Цвет для выделенного (`<b>`/`<strong>`) текста. Если nil — общий цвет.
    var emphasisColor: Color?

    var body: some View {
        if let styled = Self.cachedStyled(
            from: html,
            foregroundColor: foregroundColor,
            emphasisColor: emphasisColor
        ) {
            // Один шрифт на весь Text; жирный/курсив — через inlinePresentationIntent.
            // ВАЖНО: Text(AttributedString), где есть курсив и НЕТ жирного, в SwiftUI
            // недомеряет высоту многострочного текста и обрезает его («…»). Смешанная
            // разметка (есть <b>) меряется нормально. Поэтому в контенте эмфазу в notes
            // делаем <b>, а не только <i>. См. docs/card-generation-format.md.
            Text(styled)
                .font(font)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(html)
                .foregroundStyle(foregroundColor ?? .primary)
                .font(font)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private struct StyleCacheKey: Hashable {
        let html: String
        let foregroundColor: Color?
        let emphasisColor: Color?
    }

    /// Кэш разобранных строк: одни и те же карточки перерисовываются много раз
    /// (анимации переворота, выбор в «Колонках»), а вход неизменен — без кэша
    /// парсер гонялся бы на каждом пересчёте body.
    @MainActor
    private static var styledCache: [StyleCacheKey: AttributedString?] = [:]
    private static let styledCacheLimit = 256

    @MainActor
    private static func cachedStyled(
        from html: String,
        foregroundColor: Color?,
        emphasisColor: Color?
    ) -> AttributedString? {
        let key = StyleCacheKey(html: html, foregroundColor: foregroundColor, emphasisColor: emphasisColor)
        if let cached = styledCache[key] {
            return cached
        }
        if styledCache.count >= styledCacheLimit {
            styledCache.removeAll(keepingCapacity: true)
        }
        let styled = styled(from: html, foregroundColor: foregroundColor, emphasisColor: emphasisColor)
        styledCache[key] = styled
        return styled
    }

    private static func styled(
        from html: String,
        foregroundColor: Color?,
        emphasisColor: Color?
    ) -> AttributedString? {
        let runs = htmlRuns(from: html)
        guard !runs.isEmpty else { return nil }

        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isBold { intent.insert(.stronglyEmphasized) }
            if run.isItalic { intent.insert(.emphasized) }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
            }
            if run.isBold, let emphasisColor {
                piece.foregroundColor = emphasisColor
            } else if let foregroundColor {
                piece.foregroundColor = foregroundColor
            }
            result.append(piece)
        }
        return result
    }

    private struct HTMLRun {
        var text: String
        var isBold: Bool
        var isItalic: Bool
    }

    private static func htmlRuns(from html: String) -> [HTMLRun] {
        var runs: [HTMLRun] = []
        var buffer = ""
        var boldDepth = 0
        var italicDepth = 0
        var index = html.startIndex

        func flush() {
            let text = decodeEntities(buffer)
            if !text.isEmpty {
                runs.append(HTMLRun(text: text, isBold: boldDepth > 0, isItalic: italicDepth > 0))
            }
            buffer = ""
        }

        while index < html.endIndex {
            if html[index] == "<",
               let end = html[index...].firstIndex(of: ">") {
                flush()
                let rawTag = html[html.index(after: index)..<end]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let tagName = rawTag.split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init) ?? rawTag

                if rawTag.hasPrefix("/") {
                    if tagName == "b" || tagName == "strong" {
                        boldDepth = max(0, boldDepth - 1)
                    } else if tagName == "i" || tagName == "em" {
                        italicDepth = max(0, italicDepth - 1)
                    }
                } else if tagName == "b" || tagName == "strong" {
                    boldDepth += 1
                } else if tagName == "i" || tagName == "em" {
                    italicDepth += 1
                } else if tagName == "br" {
                    buffer.append("\n")
                }
                index = html.index(after: end)
            } else {
                buffer.append(html[index])
                index = html.index(after: index)
            }
        }

        flush()
        trimTrailingWhitespace(from: &runs)
        return runs
    }

    private static func trimTrailingWhitespace(from runs: inout [HTMLRun]) {
        while let last = runs.last {
            let trimmed = last.text.trimmingTrailingWhitespaceAndNewlines()
            if trimmed.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = trimmed
                return
            }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

private extension String {
    func trimmingTrailingWhitespaceAndNewlines() -> String {
        var result = self
        while let last = result.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            result.removeLast()
        }
        return result
    }
}
