import Foundation

/// The written half of the design system: what a model is told before it writes a module.
public enum DesignGuide {
    public static let symbols: [(topic: String, names: [String])] = [
        ("status", ["checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "info.circle", "bell", "bell.badge", "clock", "hourglass", "bolt.fill", "flame", "sparkles", "star.fill", "heart.fill", "flag.fill", "lock.fill", "lock.open", "eye", "pin.fill"]),
        ("system", ["cpu", "memorychip", "internaldrive", "externaldrive", "display", "laptopcomputer", "desktopcomputer", "server.rack", "thermometer.medium", "fan", "gauge.with.dots.needle.50percent", "speedometer", "power", "battery.100percent", "battery.50percent", "battery.25percent", "battery.100percent.bolt", "powerplug"]),
        ("network", ["wifi", "wifi.slash", "network", "antenna.radiowaves.left.and.right", "arrow.down", "arrow.up", "arrow.up.arrow.down", "arrow.down.circle", "arrow.up.circle", "globe", "link", "icloud", "cloud", "personalhotspot", "lock.shield"]),
        ("media", ["speaker.wave.2.fill", "speaker.slash.fill", "speaker.fill", "headphones", "airpodspro", "music.note", "play.fill", "pause.fill", "stop.fill", "forward.fill", "backward.fill", "mic.fill", "video.fill", "camera"]),
        ("time", ["calendar", "calendar.badge.clock", "timer", "stopwatch", "alarm", "sunrise", "sunset", "moon.fill", "sun.max.fill", "clock.arrow.circlepath"]),
        ("weather", ["cloud.sun.fill", "cloud.fill", "cloud.rain.fill", "cloud.bolt.rain.fill", "cloud.snow.fill", "cloud.fog.fill", "wind", "snowflake", "drop.fill", "umbrella.fill", "thermometer.sun"]),
        ("work", ["chevron.left.forwardslash.chevron.right", "terminal", "hammer", "wrench.and.screwdriver", "ladybug", "shippingbox", "arrow.triangle.pull", "arrow.triangle.branch", "arrow.triangle.merge", "doc.text", "folder", "tray.full", "envelope", "bubble.left", "person.2", "checklist", "list.bullet", "square.and.pencil", "magnifyingglass", "paperplane"]),
        ("money", ["dollarsign.circle", "bitcoinsign.circle", "eurosign.circle", "chart.line.uptrend.xyaxis", "chart.bar", "chart.pie", "creditcard", "cart", "bag", "tag", "ticket", "banknote"]),
        ("travel", ["airplane", "car", "tram", "bicycle", "figure.walk", "map", "mappin.and.ellipse", "location", "fork.knife", "cup.and.saucer", "bed.double", "house"]),
        ("controls", ["plus", "minus", "xmark", "checkmark", "arrow.clockwise", "arrow.counterclockwise", "trash", "gearshape", "slider.horizontal.3", "ellipsis", "chevron.right", "chevron.down", "square.and.arrow.up", "doc.on.doc", "pencil", "paintbrush", "eraser", "safari", "puzzlepiece.extension", "key", "keyboard", "newspaper", "dot.radiowaves.left.and.right"]),
    ]

    public static var allSymbols: [String] {
        symbols.flatMap(\.names)
    }

    public static var componentReference: String {
        func block(_ surface: String, _ specs: [ComponentSpec]) -> String {
            "\(surface)\n" + specs.map { "  \($0.signature)\n      \($0.doc)" }.joined(separator: "\n")
        }
        let chip = Catalog.all.filter { $0.surfaces.contains(.chip) }
        let panel = Catalog.all.filter { !$0.surfaces.contains(.chip) }
        return block("Allowed in the bar item and in panels:", chip) + "\n\n" + block("Panels only:", panel)
    }

    /// What the assistant needs to know about how the current theme's looks treat colour, or nil when nothing.
    public static func lookNote(for theme: Theme) -> String? {
        let states = [(theme.idleLook, "idle"), (theme.activeLook, "open")].filter { $0.0 == .halo }.map(\.1)
        guard !states.isEmpty, theme.haloToneLightness != nil else { return nil }
        return """
            This theme draws the bar on the halo look while \(states.joined(separator: " and ")): plain text with a dark \
            shadow. There, coloured tones on text, icons and lines are lightened to the text colour so they stay legible \
            over pale windows, and badges keep their exact colour. A paler colour there is intended. To show a different \
            colour on the halo, give a per-look tone such as { halo: 'warn', otherwise: 'orange' }; a tone named for \
            halo is drawn exactly as named.
            """
    }

    public static var reference: String {
        """
        # Writing a Lintel module

        A module is one JavaScript file run in JavaScriptCore: no imports, no DOM, no Node, no fetch, no setTimeout.
        It calls defineModule exactly once:

        defineModule({
          meta: {
            id: 'lowercase-with-dashes',
            title: 'Short Title',              // at most 24 characters
            icon: 'cpu',                       // SF Symbol shown in the panel header and in settings
            summary: 'One sentence saying what it shows.',
            pinned: false,                     // true = always visible; false = visible only while the bar is active
            order: 50,                         // lower sorts further left
            refreshSeconds: 60,                // how often chip runs (minimum 1); be gentle with remote services
            panelRefreshSeconds: 5,            // optional faster refresh while the widget is visible or peeked
            defaultShape: 'card',              // initial freeform shape: 'compact' | 'card' (default) | 'wide' | 'sidebar' | 'canvas'
            permissions: ['api.example.com'],  // every host contacted, plus capabilities: 'notify', 'audio',
                                               // 'clipboard', 'jobs', 'exec:<tool>', 'secret:<name>'
          },
          jobs: {                                           // optional; background scheduled tasks owned by this module
            'sync': {                                       // lowercase id; runs off the render loop and survives wake
              title: 'Short job title',
              schedule: { every: 3600 },                    // or { cron: '0 */5 * * *' } or { manual: true }
              timeoutSeconds: 90,                           // optional (default 60, max 600)
              runOnWake: true,                              // optional (default true): catch up after Mac sleep
              retrySeconds: 900,                            // optional backoff base on thrown error
              async run(host) { return { summary: 'ok' }; }
            },
          },
          chip(host) { return <bar item view>; },           // one-line bar chip
          widget(host) { return [<responsive blocks>]; },   // one responsive widget tree — adapts to any freeform size
          configure(host) { return [<settings controls>]; }, // optional: module settings shown in the Lintel window
          actions: {                                        // optional; run by buttons, toggles, fields, list rows
            name(host, payload) { ... },                    // may be async; views re-render afterwards
          },
        });

        Variables declared at the top of the file live as long as the module is loaded, so keep in-memory state there.
        Use host.storage for anything that must survive a restart.

        ## The unified freeform continuum

        1. Chip (`chip(host)`): one glance, one line in the top bar: an icon plus one or two short values. At most 8
           elements and about 30 characters. No sentences.
        2. Freeform Widget (`widget(host)`): dragging any corner or edge of a chip or widget morphs it smoothly to any
           width and height (narrow vertical sidebar, slim top ribbon, compact tile, or wide dashboard) with zero blank
           voids and zero scrolling. Write ONE priority-ordered responsive tree—never duplicate layouts per size:
           - Use `split([left, right])` for two-pane content: it lays side-by-side when wide and automatically stacks
             vertically when dragged narrow into a sidebar.
           - Use `grid(columns, tiles)` for stat tiles or buttons: `columns` is a maximum; the grid steps down
             automatically (`3 → 2 → 1`) as the widget narrows so values never crush.
           - Pass ALL candidate rows to `list(items)` and set `elastic: true` on repeatable `section()` / `column()`
             groups (meters, accounts, volumes): the layout engine shows as many complete entries as fit the current
             height and appends `+N more` smoothly as you drag taller—never hard-cap arrays with `.slice(0, 3)`.
           - Leave `chart()` / `app()` / `web()` height unset (or `'fill'`) so they expand fluidly with available height.
           - Keep at least one `essential` (default priority) hero block at the top; mark secondary groups with
             `{ priority: 'supporting' }` or `{ priority: 'detail' }` so they yield cleanly at tiny sizes.
           - Put settings (formats, toggles, pickers) in `configure(host)`; Lintel shows them in the module's page in the Lintel window.
           - Finite widgets automatically clamp their height to their natural content height so dragging taller never
             creates empty blank space.
           - Rows animate in, out and into new places on their own. Lintel tells siblings apart by `key`, then `url`,
             `payload`, `title` or `label`; give repeated entries that share those a `{ key: 'stable-id' }` (any
             component accepts it) so a refresh that drops one slides the rest up instead of rewriting each row.
        3. Widgets can be stacked vertically in columns or placed side-by-side on the shelf by dragging their grip handle
           (or ⌘-dragging). Double-clicking the resize handle snaps height tightly to content.

        ## Components

        These global functions are the only way to draw. They return plain objects with no methods.
        There are no raw sizes, paddings or colours: you choose roles and tones and the user's theme decides the rest.

        \(componentReference)

        Tones: primary, secondary, tertiary, accent, good, warn, bad, info, or a hue: red, orange, yellow, green, mint,
        teal, cyan, blue, indigo, purple, pink, brown, gray. Hex colours are rejected. Use good/warn/bad for meaning
        (thresholds, pass/fail), accent for emphasis, secondary for supporting text. Most things need no tone at all.
        A tone can differ by look, the material a surface is drawn on: { halo: 'secondary', otherwise: 'orange' }.
        Looks are halo, glass, solid and none; otherwise covers the rest, and a look with no tone gets none.

        ## Host API

        Synchronous data (cheap; call on every render):
          host.system() -> { cpu: 0..1, cores: [0..1], loadAverage: [1m, 5m, 15m], memoryUsed: bytes, memoryTotal: bytes,
                             memoryPressure: 0..1, swapUsed: bytes, gpu: 0..1 | null, uptime: seconds,
                             thermal: 'nominal'|'fair'|'serious'|'critical',
                             battery: { percent: 0..100, charging, plugged, minutesRemaining | null, cycles | null,
                                        health: 0..1 | null } | null }
          host.network() -> { down: bytes/s, up: bytes/s, interface: 'en0' | null, ip: string | null,
                              wifi: { ssid: string | null, rssi: dBm, channel: number } | null }
          host.disk() -> { volumes: [{ name, total: bytes, free: bytes }], readRate: bytes/s, writeRate: bytes/s }
          host.processes() -> [{ name, pid, cpu: fraction of one core, memory: bytes }]   // top ten by CPU
          host.audio() -> { volume: 0..1, muted: boolean, output: string | null }
          host.bluetooth() -> { on: boolean, devices: [{ name, connected: boolean, battery: 0..100 | null }] }
          host.appearance() -> { dark: boolean }
          host.jobs() -> [{ id, title, schedule, enabled, status, isRunning, lastRunAt, lastOkAt, nextRunAt, durationMs, summary, lastError, consecutiveErrors, recentRuns }]
          host.allJobs() -> same array across all modules (needs 'jobs' in meta.permissions)
          host.history(key, number, max = 60) -> number[]   // appends and returns a rolling series, for sparklines and charts
          host.storage.get(key, fallback), host.storage.set(key, jsonValue), host.storage.remove(key)   // persistent

        Asynchronous (await them; each rejects with an Error on failure):
          host.fetchJSON(url, { method?, headers?, body? }) -> parsed JSON. HTTPS only (http for localhost).
          host.fetchText(url, { method?, headers?, body? }) -> string
          host.browser.text(url, cssSelector) -> innerText of the first match in the app's signed-in browser profile,
                              or null. Use only when the site has no JSON API; it loads the whole page.
          host.browser.all(url, cssSelector) -> innerText of every match (at most 50)
          host.secret(name) -> string | null     // a key the user saved in settings; needs 'secret:<name>'
          host.exec(tool, [args], { timeout?, input?, keepStdinOpenMs? }) -> { status, stdout, stderr }   // needs 'exec:<tool>', timeout up to 300s
          host.jobs.run(id) -> Promise<jobSnapshot>   // trigger one of this module's jobs (or 'module:id' with 'jobs')
          host.setVolume(fraction), host.setMuted(boolean)        // needs 'audio'

        Fire and forget:
          host.jobs.setNext(id, epochMsOrNull)   // override next scheduled run time (e.g. exact upstream reset)
          host.jobs.setEnabled(id, boolean)      // pause or resume a scheduled job
          host.jobs.clearError(id)               // acknowledge/clear a job failure state
          host.notify(title, body)   // needs 'notify'; only for events the user asked to be told about
          host.open(url)             // opens an https link in the default browser
          host.copy(text)            // needs 'clipboard'
          host.refresh()             // re-render soon
          host.attention(boolean)    // true keeps the bar item on screen while the bar is idle, even if unpinned, until
                                     // you pass false. Only for what needs the user now: a failed build, a timer
                                     // running, a battery nearly empty. Call it on every render with the current truth.

        Formatting helpers (use them so every module reads the same way):
          host.format.bytes(n) '1.2 GB' · rate(n) '3.4 MB/s' · percent(fraction) '42%' · number(n) '12,345' ·
          compact(n) '1.2k' · duration(seconds) '1h 05m' · timer(seconds) '4:05' · ago(dateOrMs) '5 min ago' ·
          time(date?, { seconds?, twelveHour? }) '14:05' / '2:05 PM' · truncate(text, max) ·
          date(date?, { order?: 'day-month' | 'month-day' | 'dmy' | 'mdy' | 'iso', weekday? (default true), year? })
          'Mon 16 Nov' · 'Mon Nov 16, 2026' · '16/11' · '2026-11-16'

        ## Rules the app enforces (a module that breaks one is rejected and sent back)

        - Bar item: only chip components; at most 8 elements; each text at most 32 characters, 56 in total; one line.
        - Every icon name must be a real SF Symbol, or a monochrome vector path `svg:<size>:<path>` (e.g. `svg:24:M...Z` or `svg:16x15:M...Z`). Every action a view names must exist in actions.
        - Every host a module fetches, browses, embeds or loads an image from must be in meta.permissions.
        - Links on items and buttons must be https. list() holds only item() rows, at most 30. Sections do not nest.
        - No hex colours, font sizes or pixel values anywhere.

        ## Quality bar (what separates a good module from a passing one)

        - Numbers that change get mono: true. Units are short and consistent ('GB', '%', 'ms').
        - Handle the unhappy paths inside render and panel: catch failures and return a short, calm state, e.g.
          row([icon('exclamationmark.triangle.fill', { tone: 'warn' }), text('offline')]) in the bar and
          empty('wifi.slash', 'Cannot reach the service', { message, action: 'retry', actionLabel: 'Try again' }) in
          the panel. Never throw for an expected failure, and never show raw error text in the bar.
        - Show loading only when it matters; cache the last good value in a variable and keep showing it, with
          note('Updated 5 min ago') in the panel.
        - Colour means something. A healthy value has no tone. Use warn and bad at thresholds only.
        - A panel answers three questions in order: what is the state, why, and what can I do about it.
        - Trends beat snapshots: keep a host.history series and show sparkline in the bar or chart in the panel.
        - Text is sentence case. No exclamation marks. No emoji; use icon().

        ## Mini apps

        app(html, { height, state }) runs your HTML fragment in a sandboxed web view with a transparent background.
        It has no network access except to hosts in meta.permissions. Already loaded for you:
          CSS variables: --lt-text, --lt-secondary, --lt-tertiary, --lt-accent, --lt-on-accent, --lt-fill (subtle
            background), --lt-separator, --lt-good, --lt-warn, --lt-bad, --lt-radius, --lt-unit, --lt-font-size
          Classes: .lt-button, .lt-button.primary, .lt-input, .lt-card, .lt-row, .lt-label, .lt-value, .lt-caption
          Bridge: lintel.send(action, payload) -> Promise of the action's return value;
                  lintel.onState(function (state) { ... }) receives `state` now and after every re-render.
        The page is reloaded only when the html string changes, so keep html constant and pass changing data in state.

        ## SF Symbols known to exist

        \(symbols.map { "\($0.topic): \($0.names.joined(separator: ", "))" }.joined(separator: "\n"))
        """
    }
}
