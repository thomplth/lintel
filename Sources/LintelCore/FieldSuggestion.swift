public struct FieldSuggestion: Equatable, Sendable, Identifiable {
    public static let limit = 6

    public let title: String
    public let subtitle: String?
    public let value: String

    public var id: String { value + "\u{0}" + title }

    public init(title: String, subtitle: String?, value: String) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }

    public static func list(from reply: JSONValue) -> [FieldSuggestion] {
        let entries = reply.array ?? []
        return entries.lazy.compactMap(suggestion(from:)).prefix(limit).map { $0 }
    }

    private static func suggestion(from entry: JSONValue) -> FieldSuggestion? {
        if case .string(let title) = entry {
            return title.isEmpty ? nil : FieldSuggestion(title: title, subtitle: nil, value: title)
        }
        guard let title = entry["title"].string, !title.isEmpty else { return nil }
        return FieldSuggestion(title: title, subtitle: entry["subtitle"].string, value: entry["value"].string ?? title)
    }
}
