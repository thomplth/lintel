import AppKit
import LintelCore
import Synchronization

/// Adjusts pointer events before any app sees them:
/// - Holds the pointer just below the top edge above the bar, so an auto-hidden system menu bar does not slide in
///   there. Holding ⌥ lets the pointer through, and so do the moves Lintel posts itself to reveal the menu bar.
/// - Takes ⌘ off presses on the bar's menu bar item. macOS keeps ⌘-drags on menu bar items for itself, moving the
///   item or, dragged away, switching off every menu bar item Lintel has; without ⌘ the press reaches Lintel, which
///   reads ⌘ from the session's keyboard state instead and rearranges the module.
final class PointerTap: Sendable {
    private let span = Mutex<ClosedRange<CGFloat>?>(nil)
    private let menuBarRow = Mutex<CGRect?>(nil)
    private let isPressingMenuBarRow = Atomic<Bool>(false)
    private let isInstalled = Atomic<Bool>(false)

    var isRunning: Bool { isInstalled.load(ordering: .relaxed) }

    /// The stretch of the main display's top edge to guard, in global x; nil leaves the whole edge open.
    func guardSpan(_ newSpan: ClosedRange<CGFloat>?) {
        span.withLock { $0 = newSpan }
    }

    /// The bar's menu bar item in global display coordinates; nil while the first row is not in the menu bar.
    func takeCommandOffPresses(in frame: CGRect?) {
        menuBarRow.withLock { $0 = frame }
    }

    /// macOS disables a tap whose callback stalls, and lets the pointer through meanwhile; a thread of its own keeps
    /// the callback clear of the main thread's layout and window work.
    func start() {
        let thread = Thread { [self] in
            while !install() { Thread.sleep(forTimeInterval: 5) }
            CFRunLoopRun()
        }
        thread.name = "Lintel pointer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Fails until the user grants Accessibility, which can happen at any time after launch.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                Unmanaged<PointerTap>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled.store(true, ordering: .relaxed)
        return true
    }

    private nonisolated(unsafe) var tap: CFMachPort?
    private static let ownProcess = Int64(ProcessInfo.processInfo.processIdentifier)

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .leftMouseDown {
            let pressesRow = event.flags.contains(.maskCommand) && menuBarRow.withLock { $0?.contains(event.location) ?? false }
            isPressingMenuBarRow.store(pressesRow, ordering: .relaxed)
        }
        if isPressingMenuBarRow.load(ordering: .relaxed), type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp {
            event.flags.remove(.maskCommand)
            if type == .leftMouseUp { isPressingMenuBarRow.store(false, ordering: .relaxed) }
            return
        }
        guard type != .leftMouseDown, type != .leftMouseUp else { return }
        let point = event.location
        guard point.y < TopEdgeGuard.revealDepth, !event.flags.contains(.maskAlternate),
              event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownProcess
        else { return }
        let held = TopEdgeGuard.position(for: point, screenTop: 0, guarded: span.withLock { $0 })
        if held != point { event.location = held }
    }
}
