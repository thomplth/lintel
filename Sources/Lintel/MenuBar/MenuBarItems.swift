import AppKit
import ApplicationServices
import LintelCore
import ScreenCaptureKit

struct MenuBarItem: @unchecked Sendable {
    let key: String
    let owner: String
    let title: String
    let value: String
    let summary: String
    let frame: CGRect
    let element: AXUIElement

    var label: String {
        [title, value, summary].first { !$0.isEmpty } ?? owner
    }
}

enum MenuBarItems {
    private static let queue = DispatchQueue(label: "menu-bar-items")

    static func scan(_ completion: @escaping ([MenuBarItem]) -> Void) {
        queue.async {
            let items = Perf.measure("menubar.scan") { scanNow() }
            DispatchQueue.main.async { completion(items) }
        }
    }

    static func scanNow() -> [MenuBarItem] {
        guard AXIsProcessTrusted() else { return [] }
        var items: [MenuBarItem] = []
        // Background services never own a menu bar item, and asking each one costs a full timeout.
        let systemHosts: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.TextInputMenuAgent"]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy != .prohibited || systemHosts.contains(app.bundleIdentifier ?? "") {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            // A hung app would otherwise stall the whole scan for the six-second default.
            AXUIElementSetMessagingTimeout(application, 0.25)
            guard let extras = attribute(application, "AXExtrasMenuBar") else { continue }
            let owner = app.bundleIdentifier ?? app.localizedName ?? "pid-\(app.processIdentifier)"
            var found: [AXUIElement] = []
            collect(extras as! AXUIElement, into: &found, depth: 0)
            for (index, element) in found.enumerated() {
                let identifier = attribute(element, "AXIdentifier") as? String
                items.append(MenuBarItem(
                    key: identifier.map { "menubar:\($0)" } ?? "menubar:\(owner):\(index)",
                    owner: owner,
                    title: text(element, "AXTitle"),
                    value: text(element, "AXValue"),
                    summary: text(element, "AXDescription"),
                    frame: frame(of: element),
                    element: element
                ))
            }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    static func isReachable(_ item: MenuBarItem) -> Bool {
        AXUIElementSetMessagingTimeout(item.element, 0.3)
        return attribute(item.element, "AXPosition") != nil
    }

    // Pressing returns only when the item's menu closes, so the caller must not wait on it.
    static func press(_ item: MenuBarItem) {
        queue.async {
            AXUIElementSetMessagingTimeout(item.element, 1)
            AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        }
    }

    static func images(for items: [MenuBarItem]) async -> [String: NSImage] {
        guard CGPreflightScreenCaptureAccess(), !items.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let bar = content.windows.first(where: {
                  $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" && $0.frame.height < 80
              })
        else { return [:] }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(bar.frame.width) * 2
        configuration.height = Int(bar.frame.height) * 2
        configuration.showsCursor = false
        guard let strip = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: bar), configuration: configuration
        ) else { return [:] }

        let scale = CGFloat(strip.width) / bar.frame.width
        var images: [String: NSImage] = [:]
        for item in items {
            let local = item.frame.offsetBy(dx: -bar.frame.minX, dy: -bar.frame.minY)
            let pixels = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            guard let crop = strip.cropping(to: pixels) else { continue }
            guard hasInk(crop) else {
                images[item.key] = NSImage()
                continue
            }
            let image = NSImage(cgImage: crop, size: item.frame.size)
            image.isTemplate = true
            images[item.key] = image
        }
        return images
    }

    static func setAllowedInSystemMenuBar(bundle: String, allowed: Bool) throws {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        guard let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any],
              let blob = root["trackedApplications"] as? Data,
              var tracked = try PropertyListSerialization.propertyList(from: blob, format: nil) as? [Any]
        else { throw ModuleFailure("Control Center's app list has an unexpected shape") }

        var isFound = false
        for index in stride(from: 0, to: tracked.count - 1, by: 2) {
            guard let application = tracked[index] as? [String: Any],
                  (application["bundle"] as? [String: Any])?["_0"] as? String == bundle,
                  var state = tracked[index + 1] as? [String: Any]
            else { continue }
            state["isAllowed"] = allowed
            tracked[index + 1] = state
            isFound = true
        }
        guard isFound else { throw ModuleFailure("\(bundle) has no menu bar item known to Control Center") }

        let updated = try PropertyListSerialization.data(fromPropertyList: tracked, format: .binary, options: 0)
        let domain = file.deletingPathExtension().path
        try run("/usr/bin/defaults", ["write", domain, "trackedApplications", "-data", updated.map { String(format: "%02x", $0) }.joined()])
        // Control Center reads the list only at launch; launchd starts it again at once.
        try run("/usr/bin/killall", ["ControlCenter"])
    }

    /// Apps Control Center knows to own a menu bar item, with whether each is currently allowed to show it.
    static func trackedApplications() -> [(bundle: String, isAllowed: Bool)] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let blob = root["trackedApplications"] as? Data,
              let tracked = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [Any]
        else { return [] }
        var result: [(String, Bool)] = []
        for index in stride(from: 0, to: tracked.count - 1, by: 2) {
            guard let application = tracked[index] as? [String: Any],
                  let bundle = (application["bundle"] as? [String: Any])?["_0"] as? String,
                  let state = tracked[index + 1] as? [String: Any]
            else { continue }
            result.append((bundle, state["isAllowed"] as? Bool ?? true))
        }
        return result
    }

    static func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let result = try Shell.run(tool, arguments)
        guard result.status == 0 else {
            throw ModuleFailure("\(tool) exited with \(result.status): \(result.stderr.prefix(200))")
        }
    }

    private static func collect(_ element: AXUIElement, into found: inout [AXUIElement], depth: Int) {
        for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
            if attribute(child, "AXSubrole") as? String == "AXMenuExtra" {
                found.append(child)
            } else if depth < 2 {
                collect(child, into: &found, depth: depth + 1)
            }
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func text(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = attribute(element, "AXPosition") { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
        if let value = attribute(element, "AXSize") { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    // An item removed from the system menu bar keeps its Accessibility frame but leaves only faint background there.
    private static func hasInk(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let alphaOffset = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first ? 0 : 3
        let solid = stride(from: alphaOffset, to: CFDataGetLength(data), by: 4 * 7).lazy.filter { bytes[$0] > 150 }
        return Array(solid.prefix(8)).count == 8
    }

    static func isSystemMenuBarRevealed() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any]
            else { return false }
            return (bounds["Y"] as? Double ?? -1) >= 0
        }
    }
}

/// What is remembered about an item between sightings.
struct KnownMenuBarItem: Codable, Equatable {
    var key: String
    var label: String
    var owner: String
    var midX: Double
}

/// Keeps the bar's adopted menu bar items in step with what other apps show in the system menu bar.
///
/// Apple's own items stay reachable while the system menu bar is auto-hidden. Other apps' items do not: macOS
/// withdraws them from Accessibility whenever the bar slides away. So every sighting is remembered, and pressing
/// a withdrawn item first brings the system menu bar back.
@MainActor
final class MenuBarAdoption {
    private let model: BarModel
    private let home: AppHome
    private(set) var items: [String: MenuBarItem] = [:]
    private(set) var known: [String: KnownMenuBarItem] = [:]
    private var images: [String: NSImage] = [:]
    private var timer: Timer?
    private var isScanning = false
    private var isRevealing = false
    /// Settings and chat need the full list even when nothing is adopted yet.
    var wantsListing = false

    private var knownFile: URL { home.root.appending(path: "menu-bar-items.json") }

    init(model: BarModel, home: AppHome) {
        self.model = model
        self.home = home
        known = Dictionary((home.load([KnownMenuBarItem].self, from: knownFile) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A freshly launched app registers its status item a moment after launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.scanIfNeeded(force: false) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanIfNeeded(force: false) }
        }
        refreshSlots()
        scanIfNeeded(force: false)
    }

    var adoptedKeys: [String] {
        model.layout.rows.flatMap { $0 }.filter { $0.hasPrefix("menubar:") }
    }

    /// Every item ever seen whose app is still running, most recently sighted position first to last.
    var listing: [KnownMenuBarItem] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return known.values
            .filter { items[$0.key] != nil || running.contains($0.owner) || $0.owner.hasPrefix("com.apple.") }
            .sorted { $0.midX < $1.midX }
    }

    func scanIfNeeded(force: Bool) {
        guard force || wantsListing || !adoptedKeys.isEmpty else { return }
        scan()
    }

    /// The system menu bar just slid in: the one moment other apps' items can be seen.
    func systemMenuBarRevealed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scan() }
    }

    func scan(completion: (() -> Void)? = nil) {
        guard !isScanning else {
            completion?()
            return
        }
        isScanning = true
        MenuBarItems.scan { [weak self] found in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScanning = false
                self.items = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                var remembered = self.known
                for item in found {
                    remembered[item.key] = KnownMenuBarItem(key: item.key, label: item.label, owner: item.owner, midX: item.frame.midX)
                }
                if remembered != self.known {
                    self.known = remembered
                    self.home.save(remembered.values.sorted { $0.key < $1.key }, to: self.knownFile)
                }
                self.refreshSlots()
                completion?()
                let adopted = found.filter { self.adoptedKeys.contains($0.key) && self.model.layout.symbols[$0.key] == nil }
                guard self.model.settings.adoptsPictures, !adopted.isEmpty else { return }
                Task {
                    for (key, image) in await MenuBarItems.images(for: adopted) where image.size != .zero {
                        self.images[key] = image
                    }
                    self.refreshSlots()
                }
            }
        }
    }

    func refreshSlots() {
        var slots = model.slots.filter { $0.kind != .menuBarItem }
        for item in listing {
            var slot = Slot(id: item.key, kind: .menuBarItem, title: item.label)
            slot.order = 500
            slot.isOptIn = true
            if let symbol = model.layout.symbols[item.key], NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                slot.chip = ViewNode(.icon, ["name": .string(symbol)])
            } else {
                slot.chip = ViewNode(.text, ["value": .string(String(item.label.prefix(24)))])
                slot.image = images[item.key]
            }
            slots.append(slot)
        }
        if slots != model.slots { model.slots = slots }
    }

    func press(_ key: String) {
        if let item = items[key], MenuBarItems.isReachable(item) {
            MenuBarItems.press(item)
        } else {
            reveal { [weak self] in
                if let item = self?.items[key] { MenuBarItems.press(item) }
            }
        }
    }

    /// Brings the system menu bar in by resting the pointer on the top edge, rescans, runs `then`, and puts the
    /// pointer back. There is no API to reveal an auto-hidden menu bar.
    func reveal(then: @escaping () -> Void) {
        guard !isRevealing, let screen = NSScreen.screens.first, let origin = CGEvent(source: nil)?.location else { return }
        isRevealing = true
        let edge = CGPoint(x: min(max(origin.x, screen.frame.minX + 40), screen.frame.maxX - 40), y: 0)
        func nudge() {
            CGWarpMouseCursorPosition(edge)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edge, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        nudge()
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                attempts += 1
                guard let self else { return timer.invalidate() }
                guard MenuBarItems.isSystemMenuBarRevealed() || attempts >= 20 else { return nudge() }
                timer.invalidate()
                self.isScanning = false
                self.scan {
                    then()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        CGWarpMouseCursorPosition(origin)
                        self.isRevealing = false
                    }
                }
            }
        }
    }
}
