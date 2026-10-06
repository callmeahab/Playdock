import AppKit
import SwiftUI

struct WindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

private final class WindowAppearanceView: NSView {
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== configuredWindow else { return }
        configuredWindow = window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        window.isMovableByWindowBackground = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
                guard let window else { return }
                if let size = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-size=") }) {
                    let dimensions = size.dropFirst("--ui-size=".count).split(separator: "x").compactMap { Double($0) }
                    if dimensions.count == 2, dimensions[0] >= 1060, dimensions[1] >= 700 {
                        window.setContentSize(NSSize(width: dimensions[0], height: dimensions[1]))
                        window.center()
                    }
                }
                print("WAYFARER_UI_WINDOW=\(window.windowNumber)")
                fflush(stdout)
            }
        }
        #endif
    }
}

struct WindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowAppearanceView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(WayfarerTheme.surface) }
                else { RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial) }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)).allowsHitTesting(false))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1).allowsHitTesting(false))
    }
}

extension View {
    func glassPanel(radius: CGFloat = 20) -> some View { modifier(GlassPanel(radius: radius)) }
}

struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.14))
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background(LinearGradient(colors: [Color(red: 0.48, green: 0.94, blue: 0.82), WayfarerTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: WayfarerTheme.accent.opacity(enabled ? 0.12 : 0), radius: 14, y: 4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(enabled ? 1 : 0.35)
    }
}

/// Static light fields give the shell depth without a continuous animation or blur pass.
struct LibraryAtmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            WayfarerTheme.background.opacity(reduceTransparency ? 1 : 0.94)
            RadialGradient(colors: [WayfarerTheme.violet.opacity(0.105), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
            RadialGradient(colors: [WayfarerTheme.accent.opacity(0.07), .clear], center: .leading, startRadius: 0, endRadius: 520)
        }.allowsHitTesting(false)
    }
}

/// A dark tint keeps macOS vibrancy from becoming a separate gray slab.
struct SidebarAtmosphere: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if !reduceTransparency { WindowMaterial(material: .underWindowBackground) }
            WayfarerTheme.background.opacity(reduceTransparency ? 1 : 0.92)
            LinearGradient(colors: [WayfarerTheme.accent.opacity(0.035), .clear, WayfarerTheme.violet.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.allowsHitTesting(false)
    }
}

struct Eyebrow: View {
    let title: String
    var color: Color = WayfarerTheme.accent
    var body: some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(color)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 15).padding(.vertical, 10)
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.065), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Keep Escape available in native sheets even when an embedded NSView has focus.
struct DialogEscapeHandler: NSViewRepresentable {
    var enabled = true
    let close: () -> Void
    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var close: () -> Void = {}
        var monitor: Any?
        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self, self.enabled, event.keyCode == 53,
                      event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,
                      let window=self.view?.window, event.windowNumber == window.windowNumber else { return event }
                self.close(); return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> NSView { let view=NSView(); context.coordinator.view=view; return view }
    func updateNSView(_ view:NSView,context:Context) { context.coordinator.enabled=enabled; context.coordinator.close=close }
    static func dismantleNSView(_ view:NSView,coordinator:Coordinator) { coordinator.enabled=false }
}
