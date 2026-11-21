import Foundation

public enum Surface: String, Sendable, CaseIterable {
    case chip
    case panel
}

public enum Tone: String, Sendable, CaseIterable {
    case primary, secondary, tertiary, accent, good, warn, bad, info
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    public static let semantic: [Tone] = [.primary, .secondary, .tertiary, .accent, .good, .warn, .bad, .info]

    /// Whether the tone is a colour of its own rather than a shade of the text colour.
    public var isColoured: Bool { ![.primary, .secondary, .tertiary].contains(self) }

    public init?(name: String) {
        let aliases = [
            "success": "good", "ok": "good", "positive": "good", "warning": "warn", "caution": "warn",
            "error": "bad", "danger": "bad", "negative": "bad", "critical": "bad", "muted": "secondary",
            "dim": "tertiary", "grey": "gray", "default": "primary", "tint": "accent",
        ]
        let lowered = name.lowercased()
        self.init(rawValue: aliases[lowered] ?? lowered)
    }
}

public enum Component: String, Sendable, CaseIterable {
    case text, icon, dot, badge, gauge, ring, sparkline, row, spacer
    case column, split, section, grid, stat, meter, chart, list, item, keyValue, button, toggle, segmented, slider, field
    case divider, note, progress, image, empty, web, app
}

public enum PropType: Equatable, Sendable {
    case string
    case number
    case fraction
    case bool
    case numbers
    case strings
    case token([String])
    case tone
    case symbol
    case action
    case url
    case series
    case any
}

public struct PropSpec: Sendable {
    public let name: String
    public let type: PropType
    public let isRequired: Bool

    public init(_ name: String, _ type: PropType, required: Bool = false) {
        self.name = name
        self.type = type
        self.isRequired = required
    }
}

public struct ComponentSpec: Sendable {
    public let component: Component
    public let surfaces: Set<Surface>
    public let props: [PropSpec]
    public let hasChildren: Bool
    public let signature: String
    public let doc: String

    public func prop(_ name: String) -> PropSpec? {
        props.first { $0.name == name }
    }
}

public enum Catalog {
    public static let spacingTokens = ["none", "tight", "normal", "loose"]
    public static let alignTokens = ["leading", "center", "trailing"]
    public static let textRoles = ["value", "label", "caption", "title", "display"]
    public static let weights = ["light", "regular", "medium", "semibold", "bold"]
    public static let heights = ["small", "medium", "large"]
    public static let priorityTokens = ["essential", "supporting", "detail"]

    public static func spec(_ component: Component) -> ComponentSpec {
        byComponent[component]!
    }

    public static let chipComponents: [Component] = all.filter { $0.surfaces.contains(.chip) }.map(\.component)

    private static let byComponent = Dictionary(uniqueKeysWithValues: all.map { ($0.component, $0) })

    private static let both: Set<Surface> = [.chip, .panel]
    private static let panel: Set<Surface> = [.panel]

    public static let all: [ComponentSpec] = [
        ComponentSpec(
            component: .text, surfaces: both,
            props: [
                PropSpec("value", .string, required: true), PropSpec("role", .token(textRoles)), PropSpec("tone", .tone),
                PropSpec("weight", .token(weights)), PropSpec("mono", .bool), PropSpec("lines", .number),
            ],
            hasChildren: false,
            signature: "text(value, { role?, tone?, weight?, mono?, lines? })",
            doc: "A run of text. role: 'value' (default, the bar's own size) | 'label' | 'caption' | 'title' | 'display' (large number). mono: true keeps digits the same width so changing numbers do not jitter; use it for every number that updates. lines: wrap up to N lines (panel only; default 1)."
        ),
        ComponentSpec(
            component: .icon, surfaces: both,
            props: [PropSpec("name", .symbol, required: true), PropSpec("tone", .tone), PropSpec("size", .token(heights))],
            hasChildren: false,
            signature: "icon(sfSymbolName, { tone?, size? })",
            doc: "An SF Symbol. The name must exist; pick from the symbol list below when unsure."
        ),
        ComponentSpec(
            component: .dot, surfaces: both, props: [PropSpec("tone", .tone)], hasChildren: false,
            signature: "dot(tone)",
            doc: "A small status dot. Use for up/down, online/offline, pass/fail."
        ),
        ComponentSpec(
            component: .badge, surfaces: both,
            props: [PropSpec("value", .string, required: true), PropSpec("tone", .tone)], hasChildren: false,
            signature: "badge(value, { tone? })",
            doc: "A short count or state in a tinted capsule, e.g. badge(3, { tone: 'bad' })."
        ),
        ComponentSpec(
            component: .gauge, surfaces: both,
            props: [
                PropSpec("value", .fraction, required: true),
                PropSpec("tone", .tone),
                PropSpec("secondary", .fraction),
                PropSpec("secondaryTone", .tone),
            ], hasChildren: false,
            signature: "gauge(fraction0to1, { tone?, secondary?, secondaryTone? })",
            doc: "A tiny horizontal level bar; pass secondary (0..1, optional secondaryTone) to stack a second bar underneath."
        ),
        ComponentSpec(
            component: .ring, surfaces: both,
            props: [PropSpec("value", .fraction, required: true), PropSpec("tone", .tone)], hasChildren: false,
            signature: "ring(fraction0to1, { tone? })",
            doc: "A tiny circular progress ring. Good for quotas and timers."
        ),
        ComponentSpec(
            component: .sparkline, surfaces: both,
            props: [PropSpec("values", .numbers, required: true), PropSpec("tone", .tone), PropSpec("kind", .token(["line", "bar"]))],
            hasChildren: false,
            signature: "sparkline(numbers, { tone?, kind? })",
            doc: "A word-sized trend line (or bars) with no axes. Pass the most recent 10 to 40 points."
        ),
        ComponentSpec(
            component: .row, surfaces: both,
            props: [PropSpec("spacing", .token(spacingTokens)), PropSpec("align", .token(["top", "center", "bottom", "baseline"])), PropSpec("priority", .token(priorityTokens))],
            hasChildren: true,
            signature: "row(children, { spacing?, align?, priority? })",
            doc: "Lays children out left to right. spacing: 'none' | 'tight' | 'normal' (default) | 'loose'."
        ),
        ComponentSpec(
            component: .spacer, surfaces: both, props: [], hasChildren: false,
            signature: "spacer()",
            doc: "Flexible gap inside a row; pushes what follows to the far edge."
        ),
        ComponentSpec(
            component: .column, surfaces: panel,
            props: [
                PropSpec("spacing", .token(spacingTokens)),
                PropSpec("align", .token(alignTokens)),
                PropSpec("priority", .token(priorityTokens)),
                PropSpec("elastic", .bool),
            ],
            hasChildren: true,
            signature: "column(children, { spacing?, align?, priority?, elastic? })",
            doc: "Stacks children top to bottom. elastic: true fits as many complete children as height allows and appends '+N more' instead of clipping or leaving blank space."
        ),
        ComponentSpec(
            component: .split, surfaces: panel,
            props: [
                PropSpec("weights", .numbers),
                PropSpec("spacing", .token(spacingTokens)),
                PropSpec("align", .token(["top", "center", "bottom"])),
                PropSpec("priority", .token(priorityTokens)),
            ],
            hasChildren: true,
            signature: "split(children, { weights?, spacing?, align?, priority? })",
            doc: "Responsive 2 to 3 column layout: lays children side by side when the widget is wide and automatically stacks them vertically when dragged narrow."
        ),
        ComponentSpec(
            component: .section, surfaces: panel,
            props: [
                PropSpec("title", .string),
                PropSpec("trailing", .string),
                PropSpec("priority", .token(priorityTokens)),
                PropSpec("elastic", .bool),
            ],
            hasChildren: true,
            signature: "section(title, children, { trailing?, priority?, elastic? })",
            doc: "A titled group. trailing: short right-aligned note in the header. priority: 'essential' (default) | 'supporting' | 'detail' — lower-priority sections yield cleanly when short. elastic: true fits as many complete children (meters, keyValues, cards) as height allows with '+N more'."
        ),
        ComponentSpec(
            component: .grid, surfaces: panel,
            props: [
                PropSpec("columns", .number, required: true),
                PropSpec("spacing", .token(spacingTokens)),
                PropSpec("priority", .token(priorityTokens)),
            ],
            hasChildren: true,
            signature: "grid(columns, children, { spacing?, priority? })",
            doc: "Responsive equal-width grid (up to columns, 1 to 7): automatically steps down columns as the widget narrows so tiles never crush."
        ),
        ComponentSpec(
            component: .stat, surfaces: panel,
            props: [
                PropSpec("label", .string, required: true), PropSpec("value", .string, required: true), PropSpec("unit", .string),
                PropSpec("icon", .symbol), PropSpec("tone", .tone), PropSpec("caption", .string),
                PropSpec("trend", .token(["up", "down", "flat"])),
            ],
            hasChildren: false,
            signature: "stat(label, value, { unit?, icon?, tone?, caption?, trend? })",
            doc: "A tile with a small label and one big number. Put two to four in a grid for a dashboard header."
        ),
        ComponentSpec(
            component: .meter, surfaces: panel,
            props: [
                PropSpec("label", .string, required: true), PropSpec("fraction", .fraction, required: true),
                PropSpec("value", .string), PropSpec("tone", .tone), PropSpec("icon", .symbol),
            ],
            hasChildren: false,
            signature: "meter(label, fraction0to1, { value?, tone?, icon? })",
            doc: "A labelled level bar with an optional value at the right, e.g. meter('Memory', 0.62, { value: '20 / 32 GB' })."
        ),
        ComponentSpec(
            component: .chart, surfaces: panel,
            props: [
                PropSpec("values", .numbers), PropSpec("series", .series), PropSpec("kind", .token(["line", "area", "bar"])),
                PropSpec("tone", .tone), PropSpec("height", .token(heights + ["fill"])), PropSpec("min", .number), PropSpec("max", .number),
                PropSpec("labels", .strings),
            ],
            hasChildren: false,
            signature: "chart(numbersOrSeries, { kind?, tone?, height?, min?, max?, labels? })",
            doc: "A chart across the widget width. Pass numbers, or series as [{ label, values, tone }] for several lines with a legend. kind: 'area' (default) | 'line' | 'bar'. height: 'small' | 'medium' | 'large' | 'fill' (default in widgets: fills remaining height). labels: [leftLabel, rightLabel] under the x axis, e.g. ['60 s ago', 'now']."
        ),
        ComponentSpec(
            component: .list, surfaces: panel,
            props: [
                PropSpec("title", .string),
                PropSpec("trailing", .string),
                PropSpec("trailingTone", .tone),
                PropSpec("rail", .bool),
                PropSpec("compact", .bool),
                PropSpec("overflow", .token(["summary", "none"])),
            ],
            hasChildren: true,
            signature: "list(items, { title?, trailing?, trailingTone?, rail?, compact?, overflow? })",
            doc: "An adaptive list of item() rows with separators. Inside widgets, automatically fits as many complete rows as the height allows and appends '+N more' (overflow: 'summary', default) instead of scrolling. Optional title/trailing renders a compact card header inside the tile; rail: true connects rows with a vertical status rail and tone-colored node dots. compact: true drops subtitles when tight to fit more rows."
        ),
        ComponentSpec(
            component: .item, surfaces: panel,
            props: [
                PropSpec("title", .string, required: true), PropSpec("subtitle", .string),
                PropSpec("compactTitle", .string), PropSpec("compactSubtitle", .string),
                PropSpec("tag", .string), PropSpec("caption", .string), PropSpec("slots", .any),
                PropSpec("icon", .symbol),
                PropSpec("value", .string), PropSpec("badge", .string), PropSpec("tone", .tone), PropSpec("action", .action),
                PropSpec("payload", .any), PropSpec("url", .url), PropSpec("accessoryIcon", .symbol),
                PropSpec("accessoryAction", .action), PropSpec("accessoryLabel", .string),
            ],
            hasChildren: false,
            signature: "item(title, { subtitle?, compactTitle?, compactSubtitle?, tag?, caption?, slots?, icon?, value?, badge?, tone?, action?, payload?, url?, accessoryIcon?, accessoryAction?, accessoryLabel? })",
            doc: "One list row: icon, title and subtitle at the left, value or badge at the right. compactTitle and compactSubtitle are optional shorter labels used automatically when the widget is narrow. slots: [{ icon?, value, tone? }] renders a fixed equal-width telemetry bar (2 to 4 slots) with optional tag and caption underneath. action runs a module action on click; url opens an https link in the browser instead. accessoryAction adds a small icon button at the far right (accessoryIcon, default 'minus.circle'; accessoryLabel is its tooltip) that runs with the same payload, e.g. to remove the row."
        ),
        ComponentSpec(
            component: .keyValue, surfaces: panel,
            props: [
                PropSpec("label", .string, required: true), PropSpec("value", .string, required: true), PropSpec("tone", .tone),
                PropSpec("mono", .bool),
            ],
            hasChildren: false,
            signature: "keyValue(label, value, { tone?, mono? })",
            doc: "A detail line: label at the left, value at the right."
        ),
        ComponentSpec(
            component: .button, surfaces: panel,
            props: [
                PropSpec("label", .string, required: true), PropSpec("action", .action), PropSpec("icon", .symbol),
                PropSpec("style", .token(["primary", "secondary", "destructive", "plain"])), PropSpec("payload", .any),
                PropSpec("url", .url),
            ],
            hasChildren: false,
            signature: "button(label, action, { icon?, style?, payload?, url? })",
            doc: "A button. action names a function in the module's actions; payload is passed to it. One 'primary' per panel at most. Put several buttons in a row or grid."
        ),
        ComponentSpec(
            component: .toggle, surfaces: panel,
            props: [
                PropSpec("label", .string, required: true), PropSpec("on", .bool, required: true),
                PropSpec("action", .action, required: true), PropSpec("icon", .symbol),
            ],
            hasChildren: false,
            signature: "toggle(label, isOn, action, { icon? })",
            doc: "A labelled switch. The action receives the new boolean as its payload."
        ),
        ComponentSpec(
            component: .segmented, surfaces: panel,
            props: [
                PropSpec("options", .strings, required: true), PropSpec("selected", .string),
                PropSpec("action", .action, required: true),
            ],
            hasChildren: false,
            signature: "segmented(options, selected, action)",
            doc: "A segmented picker of two to five short options. The action receives the chosen option."
        ),
        ComponentSpec(
            component: .slider, surfaces: panel,
            props: [
                PropSpec("value", .number, required: true), PropSpec("action", .action, required: true), PropSpec("min", .number),
                PropSpec("max", .number), PropSpec("step", .number), PropSpec("label", .string), PropSpec("icon", .symbol),
            ],
            hasChildren: false,
            signature: "slider(value, action, { min?, max?, step?, label?, icon? })",
            doc: "A slider from min (default 0) to max (default 1). The action receives the new number when the user lets go."
        ),
        ComponentSpec(
            component: .field, surfaces: panel,
            props: [
                PropSpec("placeholder", .string, required: true), PropSpec("action", .action, required: true),
                PropSpec("value", .string), PropSpec("icon", .symbol), PropSpec("submitLabel", .string),
                PropSpec("suggest", .action),
            ],
            hasChildren: false,
            signature: "field(placeholder, action, { value?, icon?, submitLabel?, suggest? })",
            doc: "A one-line text input. The action receives the text when the user presses Return. suggest names an action that receives the text as it is typed and returns completions, [{ title, subtitle?, value? }] or strings; they drop down under the field, the arrow keys move between them, and picking one sends its value (or title) to action. Return the best matches first, at most six."
        ),
        ComponentSpec(
            component: .divider, surfaces: panel, props: [], hasChildren: false,
            signature: "divider()",
            doc: "A hairline between unrelated groups. Sections already separate themselves; use sparingly."
        ),
        ComponentSpec(
            component: .note, surfaces: panel,
            props: [PropSpec("value", .string, required: true), PropSpec("tone", .tone), PropSpec("icon", .symbol), PropSpec("priority", .token(priorityTokens))],
            hasChildren: false,
            signature: "note(text, { tone?, icon?, priority? })",
            doc: "A wrapped secondary paragraph for explanations, timestamps ('Updated 2 min ago') and errors (tone: 'bad')."
        ),
        ComponentSpec(
            component: .progress, surfaces: panel,
            props: [PropSpec("value", .fraction), PropSpec("label", .string), PropSpec("tone", .tone)], hasChildren: false,
            signature: "progress(fraction0to1OrNull, { label?, tone? })",
            doc: "A full-width progress bar; null shows an indeterminate spinner with the label."
        ),
        ComponentSpec(
            component: .image, surfaces: panel,
            props: [PropSpec("url", .url, required: true), PropSpec("height", .token(heights))], hasChildren: false,
            signature: "image(httpsUrl, { height? })",
            doc: "A remote image with rounded corners. Its host must be listed in permissions."
        ),
        ComponentSpec(
            component: .empty, surfaces: panel,
            props: [
                PropSpec("icon", .symbol, required: true), PropSpec("title", .string, required: true), PropSpec("message", .string),
                PropSpec("action", .action), PropSpec("actionLabel", .string),
            ],
            hasChildren: false,
            signature: "empty(sfSymbolName, title, { message?, action?, actionLabel? })",
            doc: "A centred placeholder for 'nothing here yet', 'signed out' or 'failed to load', with an optional button."
        ),
        ComponentSpec(
            component: .web, surfaces: panel,
            props: [
                PropSpec("url", .url, required: true), PropSpec("height", .token(heights + ["fill"])), PropSpec("selector", .string),
                PropSpec("interactive", .bool), PropSpec("zoom", .number), PropSpec("reloadSeconds", .number),
            ],
            hasChildren: false,
            signature: "web(url, { height?, selector?, interactive?, zoom?, reloadSeconds? })",
            doc: "A live web page inside the widget, using the app's signed-in browser profile. selector scrolls to and frames one element of the page (a live clip of a scoreboard, a queue position, a build log). interactive: true lets the user click and type in it. Its host must be listed in permissions."
        ),
        ComponentSpec(
            component: .app, surfaces: panel,
            props: [PropSpec("html", .string, required: true), PropSpec("height", .token(heights + ["tall", "fill"])), PropSpec("state", .any)],
            hasChildren: false,
            signature: "app(html, { height?, state? })",
            doc: "A small web app inside the widget for things the native components cannot draw (canvas, drag interactions, custom visualisations). html is a body fragment plus <style> and <script>; the Lintel kit stylesheet and the `lintel` bridge are already loaded (see 'Mini apps'). Prefer native components whenever they can do the job."
        ),
    ]
}
