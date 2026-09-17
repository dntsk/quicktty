import Foundation

enum CommandPaletteMatcher {
    static func matches(_ items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else {
            return items.sorted(by: stableOrder)
        }

        let tokens = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.compactMap { item -> (CommandPaletteItem, Int)? in
            let title = normalize(item.title)
            let fields =
                [title, normalize(item.subtitle ?? ""), item.stableSortKey]
                + item.aliases.map(normalize)
            var score = title == normalizedQuery ? 4_000 : 0
            if title.hasPrefix(normalizedQuery) {
                score += 2_000 - min(1_000, title.count - normalizedQuery.count)
            }
            for token in tokens {
                guard let tokenScore = fields.compactMap({ matchScore(token, in: $0) }).max()
                else { return nil }
                score += tokenScore
            }
            return (item, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return stableOrder(lhs.0, rhs.0)
        }
        .map(\.0)
    }

    static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchScore(_ token: String, in field: String) -> Int? {
        guard !field.isEmpty else { return nil }
        if field == token { return 1_200 }
        if field.hasPrefix(token) { return 1_000 - min(400, field.count - token.count) }
        if field.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(token) }) {
            return 850
        }
        if let range = field.range(of: token) {
            return 700 - min(300, field.distance(from: field.startIndex, to: range.lowerBound))
        }
        return subsequenceScore(token, in: field)
    }

    private static func subsequenceScore(_ token: String, in field: String) -> Int? {
        var fieldIndex = field.startIndex
        var firstOffset: Int?
        var previousOffset: Int?
        var gaps = 0

        for character in token {
            guard let match = field[fieldIndex...].firstIndex(of: character) else { return nil }
            let offset = field.distance(from: field.startIndex, to: match)
            if firstOffset == nil { firstOffset = offset }
            if let previousOffset { gaps += max(0, offset - previousOffset - 1) }
            previousOffset = offset
            fieldIndex = field.index(after: match)
        }

        return 500 - min(300, gaps * 8 + (firstOffset ?? 0) * 4)
    }

    private static func stableOrder(_ lhs: CommandPaletteItem, _ rhs: CommandPaletteItem) -> Bool {
        if lhs.category.rawValue != rhs.category.rawValue {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        return lhs.stableSortKey < rhs.stableSortKey
    }
}
