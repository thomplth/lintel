import Foundation

public struct ChatReply: Equatable, Sendable {
    public var say: String?
    public var theme: [String: JSONValue]?
    public var moduleSource: String?
    public var layout: BarLayout?
    public var menuBarApps: [String: Bool]
    public var inspectURL: String?
    public var remove: [String]
    public var add: [String]

    public enum ParseError: Error, Equatable {
        case noJSONObject
        case malformed(String)
    }

    public static func parse(_ text: String) throws -> ChatReply {
        guard let object = outermostObject(in: text) else { throw ParseError.noJSONObject }
        guard let value = try? JSONValue.parse(object), value.object != nil else {
            throw ParseError.malformed("the reply is not one valid JSON object")
        }
        var layout: BarLayout?
        if value["layout"].object != nil {
            guard let decoded = try? JSONDecoder().decode(BarLayout.self, from: Data(value["layout"].text.utf8)) else {
                throw ParseError.malformed("layout must be {rows, hidden, pinned, symbols}")
            }
            layout = decoded
        }
        let source = value["module"]["source"].string ?? value["module"].string
        return ChatReply(
            say: value["say"].string,
            theme: value["theme"].object,
            moduleSource: source?.isEmpty == false ? source : nil,
            layout: layout,
            menuBarApps: (value["menuBarApps"].object ?? [:]).compactMapValues(\.bool),
            inspectURL: value["inspect"]["url"].string ?? value["inspect"].string,
            remove: (value["remove"].array ?? []).compactMap(\.string),
            add: (value["add"].array ?? []).compactMap(\.string)
        )
    }

    /// Models wrap JSON in prose or code fences; module source inside it contains braces of its own.
    static func outermostObject(in text: String) -> String? {
        let characters = Array(text)
        guard let start = characters.firstIndex(of: "{") else { return nil }
        var depth = 0, isInString = false, isEscaped = false
        for index in start..<characters.count {
            let character = characters[index]
            if isInString {
                if isEscaped { isEscaped = false } else if character == "\\" { isEscaped = true } else if character == "\"" { isInString = false }
                continue
            }
            switch character {
            case "\"": isInString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(characters[start...index]) }
            default: break
            }
        }
        return nil
    }
}

/// A module as it travels between people: the code, what it asks for, and the request that produced it.
public struct ModuleBundle: Equatable, Codable, Sendable {
    public static let fileExtension = "lintelmodule"

    public var format = 1
    public var id: String
    public var title: String
    public var permissions: [String]
    public var prompt: String?
    public var source: String

    public init(id: String, title: String, permissions: [String], prompt: String?, source: String) {
        self.id = id
        self.title = title
        self.permissions = permissions
        self.prompt = prompt
        self.source = source
    }
}
