import AppKit
import QuartzCore
import SwiftUI

extension EnvironmentValues {
    /// True inside `Stage` (where the stand-in backdrop lives inside the same window rather than behind it).
    @Entry var isStagedBackdrop = false
}

/// Invisible, hit-test-transparent WindowServer backdrop sensor backed by `CABackdropLayer.tracksLuma`.
/// Reports the real-time perceptual sRGB luma (`0...1`) behind its bounds with zero Screen Recording permission.
struct BackdropLumaSensor: NSViewRepresentable {
    var onLuma: (Double) -> Void

    func makeNSView(context: Context) -> BackdropLumaSensorView {
        let view = BackdropLumaSensorView()
        view.onLuma = onLuma
        return view
    }

    func updateNSView(_ nsView: BackdropLumaSensorView, context: Context) {
        nsView.onLuma = onLuma
    }

    static func dismantleNSView(_ nsView: BackdropLumaSensorView, coordinator: ()) {
        nsView.onLuma = nil
        nsView.layer?.delegate = nil
    }
}

final class BackdropLumaSensorView: NSView, CALayerDelegate {
    var onLuma: ((Double) -> Void)?
    private var lastReported: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            return CALayer()
        }
        let backdrop = backdropClass.init()
        backdrop.setValue(true, forKey: "enabled")
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(true, forKey: "tracksLuma")
        backdrop.setValue(0.2, forKey: "lumaUpdateRate")
        return backdrop
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.delegate = window != nil ? self : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc(backdropLayer:didChangeLuma:)
    func backdropLayer(_ layer: CALayer, didChangeLuma luma: Double) {
        if let last = lastReported, abs(last - luma) < 0.02 { return }
        lastReported = luma
        DispatchQueue.main.async { [weak self] in
            self?.onLuma?(luma)
        }
    }
}
