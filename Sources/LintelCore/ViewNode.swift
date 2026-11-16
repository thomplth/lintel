import Foundation

public struct ChartSeries: Equatable, Sendable {
    public var label: String
    public var values: [Double]
    public var tone: Tone?
}

public struct ViewNode: Equatable, Sendable {
    public var component: Component
    public var props: [String: JSONValue]
    public var children: [ViewNode]

    public init(_ component: Component, _ props: [String: JSONValue] = [:], _ children: [ViewNode] = []) {
        self.component = component
        self.props = props
        self.children = children
    }

    public func string(_ name: String) -> String? { props[name]?.string }
    public func number(_ name: String) -> Double? { props[name]?.number }
    public func bool(_ name: String) -> Bool { props[name]?.bool ?? false }
    public func tone(_ name: String = "tone") -> Tone? { props[name]?.string.flatMap(Tone.init(name:)) }
    public func numbers(_ name: String) -> [Double] { props[name]?.array?.compactMap(\.number) ?? [] }
    public func strings(_ name: String) -> [String] { props[name]?.array?.compactMap(\.string) ?? [] }

    public var series: [ChartSeries] {
        if let series = props["series"]?.array {
            return series.map { entry in
                ChartSeries(
                    label: entry["label"].string ?? "",
                    values: entry["values"].array?.compactMap(\.number) ?? [],
                    tone: entry["tone"].string.flatMap(Tone.init(name:))
                )
            }
        }
        let values = numbers("values")
        return values.isEmpty ? [] : [ChartSeries(label: "", values: values, tone: tone())]
    }

    public var descendants: [ViewNode] {
        [self] + children.flatMap(\.descendants)
    }
}

public struct ViewProblem: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: Sendable { case error, warning }

    public var severity: Severity
    public var message: String

    public var description: String { message }

    public static func error(_ message: String) -> ViewProblem { ViewProblem(severity: .error, message: message) }
    public static func warning(_ message: String) -> ViewProblem { ViewProblem(severity: .warning, message: message) }
}

public struct ParsedView: Equatable, Sendable {
    public var node: ViewNode?
    public var problems: [ViewProblem]

    public var errors: [String] { problems.filter { $0.severity == .error }.map(\.message) }
}

extension ViewNode {
    /// Builds a tree from what a module returned, repairing what is safe to repair and reporting the rest.
    public static func parse(_ value: JSONValue) -> ParsedView {
        var problems: [ViewProblem] = []
        let node = build(value, problems: &problems)
        return ParsedView(node: node, problems: problems)
    }

    public static func parse(json: String) -> ParsedView {
        guard let value = try? JSONValue.parse(json) else {
            return ParsedView(node: nil, problems: [.error("the view is not valid JSON")])
        }
        return parse(value)
    }

    private static func build(_ value: JSONValue, problems: inout [ViewProblem]) -> ViewNode? {
        if case .array(let entries) = value {
            let children = entries.compactMap { build($0, problems: &problems) }
            return ViewNode(.column, [:], children)
        }
        if let text = value.string, value.object == nil {
            return ViewNode(.text, ["value": .string(text)])
        }
        guard let object = value.object else {
            if !value.isNull { problems.append(.error("a view must be built with the component functions, got \(value.text.prefix(40))")) }
            return nil
        }
        guard let type = object["type"]?.string else {
            problems.append(.error("a view must be built with the component functions; a plain object has no type"))
            return nil
        }
        guard let component = Component(rawValue: type) else {
            problems.append(.error("there is no component named '\(type)'. Components: \(Component.allCases.map(\.rawValue).joined(separator: ", "))"))
            return nil
        }
        let spec = Catalog.spec(component)
        var props: [String: JSONValue] = [:]
        for (name, raw) in object where name != "type" && name != "children" {
            guard let prop = spec.prop(name) else {
                problems.append(.warning("\(type) has no option '\(name)'; it was ignored"))
                continue
            }
            if raw.isNull { continue }
            if let coerced = coerce(raw, to: prop.type, component: type, name: name, problems: &problems) {
                props[name] = coerced
            }
        }
        for prop in spec.props where prop.isRequired && props[prop.name] == nil {
            if component == .progress || (component == .chart && prop.name == "values") { continue }
            problems.append(.error("\(spec.signature): '\(prop.name)' is missing"))
        }
        if component == .chart, props["values"] == nil, props["series"] == nil {
            problems.append(.error("chart needs numbers or series"))
        }

        var children: [ViewNode] = []
        if spec.hasChildren {
            guard let entries = object["children"]?.array else {
                problems.append(.error("\(spec.signature): children must be an array"))
                return ViewNode(component, props, [])
            }
            children = flatten(entries).compactMap { build($0, problems: &problems) }
        } else if let entries = object["children"]?.array, !entries.isEmpty {
            problems.append(.warning("\(type) takes no children; they were ignored"))
        }
        return ViewNode(component, props, children)
    }

    private static func flatten(_ entries: [JSONValue]) -> [JSONValue] {
        entries.flatMap { entry -> [JSONValue] in
            if case .array(let nested) = entry { return flatten(nested) }
            return entry.isNull || entry == .bool(false) ? [] : [entry]
        }
    }

    private static func coerce(
        _ raw: JSONValue, to type: PropType, component: String, name: String, problems: inout [ViewProblem]
    ) -> JSONValue? {
        func reject(_ expectation: String) -> JSONValue? {
            problems.append(.error("\(component).\(name) must be \(expectation), got \(raw.text.prefix(40))"))
            return nil
        }
        switch type {
        case .string, .action, .symbol, .url:
            guard let text = raw.string else { return reject("a string") }
            return .string(text)
        case .number:
            guard let number = raw.number else { return reject("a number") }
            return .number(number)
        case .fraction:
            guard let number = raw.number else { return reject("a number from 0 to 1") }
            if number > 1.0001 || number < -0.0001 {
                problems.append(.warning("\(component).\(name) is a fraction from 0 to 1; \(number) was clamped"))
            }
            return .number(min(max(number, 0), 1))
        case .bool:
            guard let flag = raw.bool else { return reject("true or false") }
            return .bool(flag)
        case .numbers:
            guard let entries = raw.array else { return reject("an array of numbers") }
            return .array(entries.compactMap(\.number).map(JSONValue.number))
        case .strings:
            guard let entries = raw.array else { return reject("an array of strings") }
            return .array(entries.compactMap(\.string).map(JSONValue.string))
        case .token(let options):
            guard let text = raw.string, options.contains(text) else {
                problems.append(.warning("\(component).\(name) must be one of \(options.joined(separator: ", ")); \(raw.text.prefix(30)) was ignored"))
                return nil
            }
            return .string(text)
        case .tone:
            guard let text = raw.string, let tone = Tone(name: text) else {
                problems.append(.error("\(component).\(name) must be a tone (\(Tone.semantic.map(\.rawValue).joined(separator: ", ")) or a colour name such as blue); raw colours like \(raw.text.prefix(20)) are not allowed"))
                return nil
            }
            return .string(tone.rawValue)
        case .series:
            guard let entries = raw.array, entries.allSatisfy({ $0["values"].array != nil }) else {
                return reject("an array of { label, values, tone }")
            }
            return raw
        case .any:
            return raw
        }
    }
}
