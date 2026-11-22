import Foundation

/// How a surface is drawn: the theme's material names, as modules see them.
public enum Look: String, CaseIterable, Sendable {
    case halo, glass, solid, none
}

public struct ResolvedTone: Equatable, Sendable {
    public var tone: Tone
    /// True when the module named this tone for the current look, so the renderer draws it exactly as named.
    public var isChosenForLook: Bool

    public init(tone: Tone, isChosenForLook: Bool) {
        self.tone = tone
        self.isChosenForLook = isChosenForLook
    }
}

/// A tone for every look, or a different tone per look with `otherwise` covering the rest.
public struct ToneChoice: Equatable, Sendable {
    public static let otherwiseKey = "otherwise"
    public static let keys = Look.allCases.map(\.rawValue) + [otherwiseKey]

    public var byLook: [Look: Tone]
    public var otherwise: Tone?

    public init(_ tone: Tone) {
        byLook = [:]
        otherwise = tone
    }

    public init(byLook: [Look: Tone], otherwise: Tone? = nil) {
        self.byLook = byLook
        self.otherwise = otherwise
    }

    public init?(_ value: JSONValue) {
        if let name = value.string {
            guard let tone = Tone(name: name) else { return nil }
            self.init(tone)
            return
        }
        guard let entries = value.object else { return nil }
        var byLook: [Look: Tone] = [:]
        for (key, entry) in entries {
            if let look = Look(rawValue: key), let tone = entry.string.flatMap(Tone.init(name:)) { byLook[look] = tone }
        }
        self.init(byLook: byLook, otherwise: entries[Self.otherwiseKey]?.string.flatMap(Tone.init(name:)))
    }

    public var json: JSONValue {
        guard !byLook.isEmpty else { return otherwise.map { .string($0.rawValue) } ?? .null }
        var entries = Dictionary(uniqueKeysWithValues: byLook.map { ($0.key.rawValue, JSONValue.string($0.value.rawValue)) })
        entries[Self.otherwiseKey] = otherwise.map { .string($0.rawValue) }
        return .object(entries)
    }

    public func resolved(for look: Look) -> ResolvedTone? {
        if let tone = byLook[look] { return ResolvedTone(tone: tone, isChosenForLook: true) }
        return otherwise.map { ResolvedTone(tone: $0, isChosenForLook: false) }
    }

    /// Why a module's tone value cannot be drawn, one message per problem; empty when it is valid.
    public static func problems(in value: JSONValue, prop: String) -> [String] {
        let toneHint = "a tone (\(Tone.semantic.map(\.rawValue).joined(separator: ", ")) or a colour name such as blue)"
        if let name = value.string {
            return Tone(name: name) == nil
                ? ["\(prop) must be \(toneHint) or { look: tone }; raw colours like \(value.text.prefix(20)) are not allowed"] : []
        }
        guard let entries = value.object else { return ["\(prop) must be \(toneHint) or { look: tone }"] }
        guard !entries.isEmpty else { return ["\(prop) names no look; give { \(keys.joined(separator: ", ")) } with a tone each"] }
        return entries.sorted { $0.key < $1.key }.compactMap { key, entry in
            guard keys.contains(key) else {
                return "\(prop) has no look named '\(key)'; looks are \(keys.joined(separator: ", "))"
            }
            guard entry.string.flatMap(Tone.init(name:)) != nil else {
                return "\(prop).\(key) must be \(toneHint); raw colours like \(entry.text.prefix(20)) are not allowed"
            }
            return nil
        }
    }
}

extension Theme {
    public var idleLook: Look {
        idleMaterial == "adaptive" ? .glass : (Look(rawValue: idleMaterial) ?? .halo)
    }

    public var activeLook: Look {
        switch activeMaterial {
        case "solid": .solid
        case "plain": .halo
        default: .glass
        }
    }
}
