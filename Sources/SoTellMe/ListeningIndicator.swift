import AppKit

/// A small, unobtrusive floating HUD shown while SoTellMe is listening or
/// transcribing, so the user always knows the mic state at a glance.
final class ListeningIndicator {
    private var panel: NSPanel?
    private var dotView: NSView?
    private var label: NSTextField?

    func show(state: String) {
        if panel == nil {
            buildPanel()
        }
        updateState(state)
        panel?.orderFrontRegardless()
    }

    private func buildPanel() {
        let width: CGFloat = 170
        let height: CGFloat = 40
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - 90
        let rect = NSRect(x: x, y: y, width: width, height: height)

        let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true

        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = height / 2
        visualEffect.layer?.masksToBounds = true

        let dot = NSView(frame: NSRect(x: 14, y: height / 2 - 6, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6

        let text = NSTextField(labelWithString: "")
        text.frame = NSRect(x: 36, y: 11, width: width - 46, height: 18)
        text.textColor = .labelColor
        text.font = .systemFont(ofSize: 12, weight: .medium)

        visualEffect.addSubview(dot)
        visualEffect.addSubview(text)
        p.contentView = visualEffect

        animatePulse(on: dot)

        panel = p
        dotView = dot
        label = text
    }

    private func animatePulse(on dot: NSView) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        dot.layer?.add(anim, forKey: "pulse")
    }

    func updateState(_ text: String) {
        label?.stringValue = text
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        dotView = nil
        label = nil
    }
}
