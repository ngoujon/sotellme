import AppKit

/// A small, unobtrusive floating HUD anchored to the bottom of the screen,
/// shown while SoTellMe is listening or transcribing: a status row, a live
/// (partial) transcript preview, and a voice-reactive waveform.
final class ListeningIndicator {
    private var panel: NSPanel?
    private var dotView: NSView?
    private var statusLabel: NSTextField?
    private var transcriptLabel: NSTextField?
    private var waveform: WaveformView?

    func show(state: String) {
        if panel == nil {
            buildPanel()
        }
        updateState(state)
        updateTranscript("")
        waveform?.reset()
        panel?.orderFrontRegardless()
    }

    private func buildPanel() {
        let width: CGFloat = 380
        let height: CGFloat = 128
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.visibleFrame.minY + 36
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
        visualEffect.layer?.cornerRadius = 22
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let dot = NSView(frame: NSRect(x: 20, y: height - 28, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 38, y: height - 31, width: width - 58, height: 16)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .semibold)

        let transcript = NSTextField(labelWithString: "")
        transcript.frame = NSRect(x: 20, y: 46, width: width - 40, height: 38)
        transcript.textColor = .labelColor
        transcript.font = .systemFont(ofSize: 14, weight: .medium)
        transcript.cell?.wraps = true
        transcript.cell?.isScrollable = false
        transcript.cell?.truncatesLastVisibleLine = true
        transcript.maximumNumberOfLines = 2
        transcript.lineBreakMode = .byTruncatingHead
        transcript.alignment = .center

        let wave = WaveformView(frame: NSRect(x: 20, y: 14, width: width - 40, height: 26))

        visualEffect.addSubview(dot)
        visualEffect.addSubview(status)
        visualEffect.addSubview(transcript)
        visualEffect.addSubview(wave)
        p.contentView = visualEffect

        animatePulse(on: dot)

        panel = p
        dotView = dot
        statusLabel = status
        transcriptLabel = transcript
        waveform = wave
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
        statusLabel?.stringValue = text
    }

    /// Shows the current (possibly partial) transcript live, replacing older
    /// text with the most recent words when it doesn't fit.
    func updateTranscript(_ text: String) {
        transcriptLabel?.stringValue = text
    }

    /// Feeds the current microphone peak amplitude (0...1) into the
    /// voice-reactive waveform.
    func updateLevel(_ level: Float) {
        waveform?.pushLevel(level)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        dotView = nil
        statusLabel = nil
        transcriptLabel = nil
        waveform = nil
    }
}

/// A row of thin bars that animate in real time to reflect microphone
/// amplitude, like a compact voice waveform.
private final class WaveformView: NSView {
    private let barCount = 28
    private var levels: [CGFloat]
    private var barLayers: [CALayer] = []

    override init(frame: NSRect) {
        levels = Array(repeating: 0.04, count: barCount)
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        rebuildBars()
    }

    func reset() {
        levels = Array(repeating: 0.04, count: barCount)
        render(animated: false)
    }

    func pushLevel(_ level: Float) {
        levels.removeFirst()
        let normalized = max(0.04, min(1, CGFloat(level) * 5))
        levels.append(normalized)
        render(animated: true)
    }

    private func rebuildBars() {
        guard let rootLayer = layer, bounds.width > 0 else { return }
        rootLayer.sublayers = nil
        barLayers.removeAll()

        let spacing: CGFloat = 3
        let barWidth = max(1, (bounds.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemGreen.cgColor
            bar.cornerRadius = barWidth / 2
            let x = CGFloat(i) * (barWidth + spacing)
            bar.frame = NSRect(x: x, y: bounds.midY - 1, width: barWidth, height: 2)
            rootLayer.addSublayer(bar)
            barLayers.append(bar)
        }
        render(animated: false)
    }

    private func render(animated: Bool) {
        guard barLayers.count == levels.count, bounds.height > 0 else { return }
        let maxHeight = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.09)
        for (i, bar) in barLayers.enumerated() {
            let h = max(2, levels[i] * maxHeight)
            let color: NSColor = levels[i] > 0.75 ? .systemRed : (levels[i] > 0.4 ? .systemYellow : .systemGreen)
            bar.backgroundColor = color.cgColor
            bar.frame = NSRect(x: bar.frame.origin.x, y: (maxHeight - h) / 2, width: bar.frame.width, height: h)
        }
        CATransaction.commit()
    }
}
