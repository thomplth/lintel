import AppKit
import LintelCore
import SwiftUI

/// Lets Tab reach a control and Space or Return use it, as a click would; arrows adjust controls that take a value.
struct KeyboardOperable<Ring: Shape>: ViewModifier {
    let ring: Ring
    let context: RenderContext
    /// Names the control within its panel, so the panel can focus it again when next opened from the keyboard.
    let focusKey: String
    let isContent: Bool
    let activate: (() -> Void)?
    let adjust: ((Int) -> Void)?
    @FocusState private var isFocused: Bool
    @ObservedObject private var modality = FocusRingModality.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let animates = context.animates && !reduceMotion
        let showsRing = isFocused && modality.visibility.showsRing
        content
            // `.activate` controls are skipped by Tab unless Keyboard Navigation is on in System Settings, which most
            // people leave off; `.edit` ones are always reachable, like text fields.
            .focusable(interactions: .edit)
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                ring.stroke(context.accent, lineWidth: 2)
                    .opacity(showsRing ? 1 : 0)
                    .scaleEffect(showsRing || !animates ? 1 : 1.06)
                    .animation(animates ? .spring(duration: 0.2, bounce: 0.2) : nil, value: showsRing)
                    .allowsHitTesting(false)
            }
            .onKeyPress(keys: [.space, .return]) { _ in
                guard let activate else { return .ignored }
                activate()
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard let adjust else { return .ignored }
                adjust(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            .onAppear {
                guard context.panelFocus?.claims(focusKey, in: context.moduleID, isContent: isContent) == true else { return }
                // Focus set during the appearance itself is dropped while the panel's window is still becoming key.
                DispatchQueue.main.async { isFocused = true }
            }
            .onChange(of: isFocused) {
                if isFocused { context.panelFocus?.focused(focusKey, in: context.moduleID) }
            }
    }
}

/// Tracks whether the last input was keyboard navigation or a click, for every window Lintel owns.
@MainActor
final class FocusRingModality: ObservableObject {
    static let shared = FocusRingModality()
    @Published private(set) var visibility = FocusVisibility()
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                FocusRingModality.shared.record(event.type == .keyDown ? .init(keyCode: event.keyCode) : .pointer)
            }
            return event
        }
    }

    func record(_ input: FocusVisibility.Input) {
        var next = visibility
        next.record(input)
        if next != visibility { visibility = next }
    }
}

extension View {
    func keyboardOperable<Ring: Shape>(
        _ context: RenderContext, focusKey: String, isContent: Bool = true, ring: Ring,
        activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil
    ) -> some View {
        modifier(KeyboardOperable(
            ring: ring, context: context, focusKey: focusKey, isContent: isContent, activate: activate, adjust: adjust
        ))
    }

    func keyboardOperable(_ context: RenderContext, focusKey: String, activate: @escaping () -> Void) -> some View {
        keyboardOperable(context, focusKey: focusKey, ring: context.tileShape, activate: activate)
    }
}

extension ViewNode {
    /// Stays the same while a panel's content refreshes, unlike the node's place among its siblings.
    var focusKey: String {
        [component.rawValue, string("action"), string("label") ?? string("title"), props["payload"]?.text]
            .compactMap { $0 }.joined(separator: "|")
    }
}
