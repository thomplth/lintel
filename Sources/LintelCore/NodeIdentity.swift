/// A child view node paired with an identity that survives its siblings being added, removed or reordered.
public struct KeyedNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let offset: Int
    public let element: ViewNode
}

extension ViewNode {
    /// Props that name what a node stands for, most specific first. Displayed values such as a text's `value` are left
    /// out, so a clock's text keeps its identity while it ticks.
    static let identifyingProps = ["key", "url", "payload", "title", "label"]

    var identityBase: String {
        let name = Self.identifyingProps.lazy.compactMap { self.props[$0].map(\.text) }.first ?? ""
        return component.rawValue + "|" + name
    }
}

extension Array where Element == ViewNode {
    public var keyed: [KeyedNode] {
        var seen: [String: Int] = [:]
        return enumerated().map { offset, node in
            let base = node.identityBase
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return KeyedNode(id: base + "#\(occurrence)", offset: offset, element: node)
        }
    }
}

extension ViewNode {
    /// Changes when a node is added, removed or moved, or a tone changes anywhere in the tree, and not when a value
    /// such as a clock's text ticks, so animating on it moves rows and recolours badges without redrawing every tick.
    public var motionSignature: [String] {
        var signature: [String] = []
        appendSignature(path: "", to: &signature)
        return signature
    }

    private func appendSignature(path: String, to signature: inout [String]) {
        signature.append(path + tones)
        for child in children.keyed {
            child.element.appendSignature(path: path + "/" + child.id, to: &signature)
        }
    }

    private var tones: String {
        props.keys.sorted().compactMap { name in
            let value = props[name]!
            if name.lowercased().hasSuffix("tone") { return "\(name)=\(value.text)" }
            guard let entries = value.array else { return nil }
            return "\(name)=" + entries.map { $0["tone"].text }.joined(separator: ",")
        }.map { "|" + $0 }.joined()
    }
}
