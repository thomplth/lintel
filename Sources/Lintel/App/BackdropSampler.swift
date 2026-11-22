import AppKit
import Combine
import LintelCore
import ScreenCaptureKit

/// Samples the screen behind Lintel's floating surfaces (excluding Lintel itself) when the theme uses the
/// `adaptive` Liquid Glass material, so capsules, widgets, and panels blend into light, dark, and coloured desktops.
@MainActor
final class BackdropSampler {
    private let model: BarModel
    private unowned let bar: BarWindowController
    private unowned let panelWindow: PanelWindowController
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isCapturing = false
    private var needsResample = false
    private var pendingWork: DispatchWorkItem?

    init(model: BarModel, bar: BarWindowController, panelWindow: PanelWindowController) {
        self.model = model
        self.bar = bar
        self.panelWindow = panelWindow
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestSample(after: 0)
                self?.requestSample(after: 0.3)
            }
        })
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestSample(after: 0.25) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSample(after: 0.2) }
        })

        model.$theme
            .map(\.usesAdaptiveBackdrop)
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.updateRunningState(enabled: enabled)
            }
            .store(in: &cancellables)

        model.$isActive
            .removeDuplicates()
            .sink { [weak self] _ in self?.requestSample(after: 0.08) }
            .store(in: &cancellables)

        model.$panel
            .map { $0?.slotID }
            .removeDuplicates()
            .sink { [weak self] _ in self?.requestSample(after: 0.12) }
            .store(in: &cancellables)

        model.$visibility
            .map(\.isHidden)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateRunningState(enabled: self.model.theme.usesAdaptiveBackdrop)
            }
            .store(in: &cancellables)

        updateRunningState(enabled: model.theme.usesAdaptiveBackdrop)
    }

    func requestSample(after delay: TimeInterval = 0) {
        guard model.theme.usesAdaptiveBackdrop, !model.isHidden else { return }
        if delay <= 0 {
            triggerCapture()
            return
        }
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.triggerCapture()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateRunningState(enabled: Bool) {
        let shouldRun = enabled && !model.isHidden
        if !shouldRun {
            timer?.invalidate()
            timer = nil
            pendingWork?.cancel()
            pendingWork = nil
            if !enabled, !model.adaptiveBackdrop.isEmpty {
                model.adaptiveBackdrop = AdaptiveBackdropState()
            }
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.triggerCapture() }
            }
        }
        requestSample(after: 0.05)
    }

    private func triggerCapture() {
        guard model.theme.usesAdaptiveBackdrop, !model.isHidden else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !model.adaptiveBackdrop.isEmpty {
                model.adaptiveBackdrop = AdaptiveBackdropState()
            }
            return
        }
        guard !isCapturing else {
            needsResample = true
            return
        }
        guard let screen = bar.screen else { return }
        let screenFrame = screen.frame
        let targets = collectTargets(on: screenFrame)
        guard !targets.captureRect.isEmpty else { return }

        isCapturing = true
        needsResample = false
        let previous = model.adaptiveBackdrop
        let ownPID = ProcessInfo.processInfo.processIdentifier

        Task { [weak self] in
            let updated = await Perf.measure("backdrop.sample") {
                await Self.capture(
                    targets: targets,
                    screenFrame: screenFrame,
                    displayID: Self.displayID(of: screen),
                    ownPID: ownPID,
                    previous: previous
                )
            }
            guard let self else { return }
            self.isCapturing = false
            if self.model.theme.usesAdaptiveBackdrop, !self.model.isHidden, let updated, updated != self.model.adaptiveBackdrop {
                self.model.adaptiveBackdrop = updated
            }
            if self.needsResample {
                self.needsResample = false
                self.triggerCapture()
            }
        }
    }

    private struct CaptureTargets: Sendable {
        var captureRect: CGRect
        var barRect: CGRect
        var slotRects: [String: CGRect]
        var panelRect: CGRect?
    }

    private func collectTargets(on screenFrame: CGRect) -> CaptureTargets {
        let barRect = bar.contentFrame.intersection(screenFrame)
        var union = barRect
        var slotRects: [String: CGRect] = [:]

        let visibleIDs = Set(model.visibleRows.joined().map(\.id))
            .union(model.visibleWidgets.map(\.slot.id))
        for id in visibleIDs {
            if let rect = bar.screenFrame(ofSlot: id)?.intersection(screenFrame), !rect.isEmpty {
                slotRects[id] = rect
                union = union.isEmpty ? rect : union.union(rect)
            }
        }

        var panelRect: CGRect?
        if model.panel != nil, panelWindow.isVisible {
            let rect = panelWindow.visibleFrame.intersection(screenFrame)
            if !rect.isEmpty {
                panelRect = rect
                union = union.isEmpty ? rect : union.union(rect)
            }
        }

        return CaptureTargets(captureRect: union, barRect: barRect, slotRects: slotRects, panelRect: panelRect)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private nonisolated static func capture(
        targets: CaptureTargets,
        screenFrame: CGRect,
        displayID: CGDirectDisplayID?,
        ownPID: pid_t,
        previous: AdaptiveBackdropState
    ) async -> AdaptiveBackdropState? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID }) ?? content.displays.first else {
            return nil
        }

        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        // Convert AppKit bottom-left screen coordinates to display-local top-left coordinates.
        let sourceRect = CGRect(
            x: max(0, targets.captureRect.minX - screenFrame.minX),
            y: max(0, screenFrame.maxY - targets.captureRect.maxY),
            width: min(targets.captureRect.width, screenFrame.width),
            height: min(targets.captureRect.height, screenFrame.height)
        )
        guard sourceRect.width >= 1, sourceRect.height >= 1 else { return nil }

        let scale = min(1.0, min(96.0 / sourceRect.width, 64.0 / sourceRect.height))
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(8, Int((sourceRect.width * scale).rounded()))
        config.height = max(8, Int((sourceRect.height * scale).rounded()))
        config.showsCursor = false

        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let rgba = rgbaBytes(of: image)
        else { return nil }

        func normalized(_ appKitRect: CGRect) -> CGRect {
            let x = (appKitRect.minX - targets.captureRect.minX) / targets.captureRect.width
            let y = (targets.captureRect.maxY - appKitRect.maxY) / targets.captureRect.height
            let w = appKitRect.width / targets.captureRect.width
            let h = appKitRect.height / targets.captureRect.height
            return CGRect(x: x, y: y, width: w, height: h)
        }

        var next = AdaptiveBackdropState()
        if !targets.barRect.isEmpty,
           let sample = AdaptiveBackdrop.sample(rgba: rgba, width: image.width, height: image.height, region: normalized(targets.barRect)) {
            next.defaultSurface = AdaptiveBackdrop.surface(for: sample, previous: previous.defaultSurface)
        } else {
            next.defaultSurface = previous.defaultSurface
        }

        for (id, rect) in targets.slotRects {
            if let sample = AdaptiveBackdrop.sample(rgba: rgba, width: image.width, height: image.height, region: normalized(rect)) {
                next.slotSurfaces[id] = AdaptiveBackdrop.surface(for: sample, previous: previous.surface(for: id))
            }
        }

        if let panelRect = targets.panelRect,
           let sample = AdaptiveBackdrop.sample(rgba: rgba, width: image.width, height: image.height, region: normalized(panelRect)) {
            next.panelSurface = AdaptiveBackdrop.surface(for: sample, previous: previous.panelSurface ?? previous.defaultSurface)
        }

        return next
    }

    private nonisolated static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
