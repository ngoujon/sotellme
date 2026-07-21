import AppKit

/// A small, unobtrusive floating HUD shown while SoTellMe is listening or
/// transcribing, so the user always knows the mic state at a glance.
final class ListeningIndicator {
    private var panel: NSPanel?
    private var dotView: NSView?
    private var label: NSTextField?
    private var levelBarBackground: NSView?
    private var levelBarFill: NSView?

    func show(state: String) {
        if panel == nil {
            buildPanel()
        }
        updateState(state)
        updateLevel(0)
        panel?.orderFrontRegardless()
    }

    private func buildPanel() {
        let width: CGFloat = 170
        let height: CGFloat = 54
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - 100
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

        let dot = NSView(frame: NSRect(x: 14, y: height - 22, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6

        let text = NSTextField(labelWithString: "")
        text.frame = NSRect(x: 36, y: height - 26, width: width - 46, height: 18)
        text.textColor = .labelColor
        text.font = .systemFont(ofSize: 12, weight: .medium)

        let barBackground = NSView(frame: NSRect(x: 36, y: 10, width: width - 46, height: 6))
        barBackground.wantsLayer = true
        barBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        barBackground.layer?.cornerRadius = 3

        let barFill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 6))
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor.systemGreen.cgColor
        barFill.layer?.cornerRadius = 3
        barBackground.addSubview(barFill)

        visualEffect.addSubview(dot)
        visualEffect.addSubview(text)
        visualEffect.addSubview(barBackground)
        p.contentView = visualEffect

        animatePulse(on: dot)

        panel = p
        dotView = dot
        label = text
        levelBarBackground = barBackground
        levelBarFill = barFill
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

    /// Reflects the current microphone input level (0...1 peak amplitude)
    /// as a filled bar, with color shifting from green to red near clipping.
    func updateLevel(_ level: Float) {
        guard let background = levelBarBackground, let fill = levelBarFill else { return }
        let clamped = max(0, min(1, level * 4))
        fill.frame.size.width = background.bounds.width * CGFloat(clamped)
        let color: NSColor = clamped > 0.85 ? .systemRed : (clamped > 0.5 ? .systemYellow : .systemGreen)
        fill.layer?.backgroundColor = color.cgColor
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        dotView = nil
        label = nil
        levelBarBackground = nil
        levelBarFill = nil
    }
}
