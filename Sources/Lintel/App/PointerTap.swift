import AppKit
import LintelCore
import Synchronization

/// Holds the pointer just below the top edge above the bar, so an auto-hidden system menu bar does not slide in
/// there. Holding ⌥ lets the pointer through, and so do the moves Lintel posts itself to reveal the menu bar.
final class TopEdgeTap: Sendable {
    private let span = Mutex<ClosedRange<CGFloat>?>(nil)
    private let isInstalled = Atomic<Bool>(false)

    var isRunning: Bool { isInstalled.load(ordering: .relaxed) }

    /// The stretch of the main display's top edge to guard, in global x; nil leaves the whole edge open.
    func guardSpan(_ newSpan: ClosedRange<CGFloat>?) {
        span.withLock { $0 = newSpan }
    }

    /// macOS disables a tap whose callback stalls, and lets the pointer through meanwhile; a thread of its own keeps
    /// the callback clear of the main thread's layout and window work.
    func start() {
        let thread = Thread { [self] in
            while !install() { Thread.sleep(forTimeInterval: 5) }
            CFRunLoopRun()
        }
        thread.name = "Lintel top edge"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func install() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Fails until the user grants Accessibility, which can happen at any time after launch.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { proxy, type, event, context in
                Unmanaged<TopEdgeTap>.fromOpaque(context!).takeUnretainedValue().handle(type, event)
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
        let point = event.location
        guard point.y < TopEdgeGuard.revealDepth, !event.flags.contains(.maskAlternate),
              event.getIntegerValueField(.eventSourceUnixProcessID) != Self.ownProcess
        else { return }
        let held = TopEdgeGuard.position(for: point, screenTop: 0, guarded: span.withLock { $0 })
        if held != point { event.location = held }
    }
}
