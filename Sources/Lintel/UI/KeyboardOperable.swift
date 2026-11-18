import SwiftUI

/// Lets Tab reach a control and Space or Return use it, as a click would; arrows adjust controls that take a value.
struct KeyboardOperable<Ring: Shape>: ViewModifier {
    let ring: Ring
    let color: Color
    let activate: (() -> Void)?
    let adjust: ((Int) -> Void)?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            // `.activate` controls are skipped by Tab unless Keyboard Navigation is on in System Settings, which most
            // people leave off; `.edit` ones are always reachable, like text fields.
            .focusable(interactions: .edit)
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay { if isFocused { ring.stroke(color, lineWidth: 2) } }
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
    }
}

extension View {
    func keyboardOperable<Ring: Shape>(
        _ context: RenderContext, ring: Ring, activate: (() -> Void)? = nil, adjust: ((Int) -> Void)? = nil
    ) -> some View {
        modifier(KeyboardOperable(ring: ring, color: context.accent, activate: activate, adjust: adjust))
    }

    func keyboardOperable(_ context: RenderContext, activate: @escaping () -> Void) -> some View {
        keyboardOperable(context, ring: context.tileShape, activate: activate)
    }
}
