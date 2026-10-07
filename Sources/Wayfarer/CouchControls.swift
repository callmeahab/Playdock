import SwiftUI
import AppKit

private struct CouchControlsKey: EnvironmentKey { static let defaultValue = false }
private struct CouchControlIDKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var couchControls: Bool { get { self[CouchControlsKey.self] } set { self[CouchControlsKey.self] = newValue } }
    var couchControlID: String { get { self[CouchControlIDKey.self] } set { self[CouchControlIDKey.self] = newValue } }
}
extension View {
    func controllerControls(_ active: Bool) -> some View {
        environment(\.couchControls, active)
            .buttonStyle(ControllerButtonStyle(style: .automatic))
            .toggleStyle(ControllerToggleStyle(style: .automatic))
            .disclosureGroupStyle(ControllerDisclosureStyle())
            .controlSize(active ? .large : .regular)
    }
    func couchControl(_ id: String) -> some View { environment(\.couchControlID, id) }
    func couchAction(_ action: @escaping @MainActor () -> Void) -> some View { modifier(CouchActionRegistration(action: action)) }
}

struct ControllerButtonStyle<Style: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(style).couchAction { configuration.trigger() }
    }
}
struct PlayButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(PlayButtonAppearance()).couchAction { configuration.trigger() }
    }
}
struct QuietButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }.buttonStyle(QuietButtonAppearance()).couchAction { configuration.trigger() }
    }
}
struct ControllerToggleStyle<Style: ToggleStyle>: ToggleStyle {
    let style: Style
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(style).couchAction { configuration.isOn.toggle() }
    }
}
struct ControllerDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.couchControls) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        if enabled {
            VStack(alignment: .leading, spacing: 8) {
                Button { configuration.isExpanded.toggle() } label: {
                    HStack { Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right"); configuration.label }
                }.buttonStyle(ControllerButtonStyle(style: .plain))
                if configuration.isExpanded { configuration.content }
            }
        } else {
            DisclosureGroup(isExpanded: configuration.$isExpanded) { configuration.content } label: { configuration.label }.disclosureGroupStyle(.automatic)
        }
    }
}

private struct CouchActionRegistration: ViewModifier {
    @Environment(\.couchControls) private var active
    @Environment(\.couchControlID) private var id
    @Environment(\.isEnabled) private var enabled
    let action: @MainActor () -> Void
    func body(content: Content) -> some View {
        content.background {
            if active { CouchControlMarker(id: id, enabled: enabled, action: action).allowsHitTesting(false) }
        }
    }
}
private struct CouchControlMarker: NSViewRepresentable {
    let id: String
    let enabled: Bool
    let action: @MainActor () -> Void
    func makeNSView(context: Context) -> CouchControlView { CouchControlView() }
    func updateNSView(_ view: CouchControlView, context: Context) { view.controlID = id; view.enabled = enabled; view.action = action }
    static func dismantleNSView(_ view: CouchControlView, coordinator: ()) { view.action = nil }
}

// Register semantic actions so controller focus does not depend on accessibility permissions.
@MainActor final class CouchControlView: NSView {
    var controlID = ""
    var enabled = true
    var action: (@MainActor () -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
