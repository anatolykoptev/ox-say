import AppKit

/// The pill at the bottom of the screen that shows dictation is happening: a
/// pulsing dot and bars that move with your voice while recording, a spinner
/// while the daemon transcribes, and a short message when something went wrong.
/// It never takes focus, so the paste still goes to the app you were typing in,
/// and it lets clicks through.
final class Overlay {
    private let panel: NSPanel
    private let background: NSVisualEffectView
    private let bars = LevelBarsView(count: 9)
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Transcribing…")
    private let hint = NSTextField(labelWithString: "esc")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let pillSize = NSSize(width: 176, height: 36)
    private var size: NSSize
    private var showingMessage = false
    private var messageTimeout: DispatchWorkItem?
    /// Bumped by every show, so a fade-out that finishes after a new show does
    /// not order the new pill out.
    private var shown = 0

    init() {
        size = pillSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Overlay.pill(radius: size.height / 2)
        panel.contentView = background

        bars.frame = NSRect(x: 22, y: 0, width: 96, height: size.height)
        background.addSubview(bars)

        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .tertiaryLabelColor
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: size.width - hint.frame.width - 14, y: (size.height - hint.frame.height) / 2)
        background.addSubview(hint)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: 18, y: (size.height - spinner.frame.height) / 2)
        background.addSubview(spinner)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: spinner.frame.maxX + 8, y: (size.height - label.frame.height) / 2)
        background.addSubview(label)

        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .labelColor
        message.maximumNumberOfLines = 3
        message.isHidden = true
        background.addSubview(message)
    }

    /// Recording: bars "breathe" in grey until the first sound arrives.
    func showListening() {
        leaveMessage()
        bars.reset()
        bars.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = true
        show()
        bars.start()
    }

    func showWorking() {
        leaveMessage()
        bars.stop()
        bars.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.isHidden = false
        show()
    }

    /// Dictation is over. A message on screen stays until it times out.
    func finish() {
        if !showingMessage { hide() }
    }

    /// Says what went wrong (or where the text went) for a few seconds.
    func showMessage(_ text: String) {
        bars.stop()
        bars.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.isHidden = true
        hint.isHidden = true
        message.stringValue = text
        message.isHidden = false
        let maxText: CGFloat = 420
        message.preferredMaxLayoutWidth = maxText
        let fit = message.sizeThatFits(NSSize(width: maxText, height: 200))
        resize(to: NSSize(width: max(pillSize.width, ceil(fit.width) + 40), height: max(pillSize.height, ceil(fit.height) + 18)))
        message.frame = NSRect(x: 20, y: (size.height - ceil(fit.height)) / 2, width: ceil(fit.width), height: ceil(fit.height))
        showingMessage = true
        show()
        messageTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.showingMessage = false
            self?.hide()
        }
        messageTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    private func leaveMessage() {
        messageTimeout?.cancel()
        messageTimeout = nil
        showingMessage = false
        message.isHidden = true
        hint.isHidden = false
        resize(to: pillSize)
    }

    private func resize(to newSize: NSSize) {
        guard newSize != size else { return }
        size = newSize
        panel.setContentSize(size)
        background.frame = NSRect(origin: .zero, size: size)
        background.maskImage = Overlay.pill(radius: min(size.height, pillSize.height) / 2)
        bars.frame.size.height = size.height
        hint.frame.origin = NSPoint(x: size.width - hint.frame.width - 14, y: (size.height - hint.frame.height) / 2)
    }

    private func hide() {
        bars.stop()
        spinner.stopAnimation(nil)
        let fading = shown
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.shown == fading else { return }
            self.panel.orderOut(nil)
        })
    }

    /// From the microphone, any thread.
    func setLevels(_ levels: [Float]) {
        DispatchQueue.main.async { [bars] in bars.target(levels) }
    }

    private func show() {
        shown += 1
        // Bottom centre of the screen the pointer is on, above the Dock.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private static func pill(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A red dot and a row of bars. Bar heights ease toward the latest microphone
/// levels at 30 frames a second; before the first level arrives they breathe
/// in grey, so a microphone that has not started yet does not look like silence.
final class LevelBarsView: NSView {
    private let count: Int
    private var shown: [CGFloat]
    private var wanted: [CGFloat]
    private var heard = false
    private var timer: Timer?
    private var tick: CGFloat = 0

    init(count: Int) {
        self.count = count
        shown = Array(repeating: 0, count: count)
        wanted = Array(repeating: 0, count: count)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reset() {
        heard = false
        shown = Array(repeating: 0, count: count)
        wanted = Array(repeating: 0, count: count)
        tick = 0
        needsDisplay = true
    }

    func target(_ levels: [Float]) {
        guard timer != nil else { return } // a late level after the recording ended
        heard = true
        for i in 0..<min(count, levels.count) { wanted[i] = CGFloat(levels[i]) }
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        tick += 1
        for i in 0..<count { shown[i] += (wanted[i] - shown[i]) * 0.35 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        // Pulsing dot: recording is on.
        let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(tick / 30 * 2 * .pi * 0.8))
        NSColor.systemRed.withAlphaComponent(pulse).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: midY - 4, width: 8, height: 8)).fill()

        let barWidth: CGFloat = 4, gap: CGFloat = 3, maxHeight: CGFloat = 18, minHeight: CGFloat = 3
        var x: CGFloat = 20
        for i in 0..<count {
            let height: CGFloat
            let color: NSColor
            if heard {
                height = minHeight + pow(shown[i], 0.7) * (maxHeight - minHeight)
                color = .white
            } else {
                // Waiting for the microphone: a slow wave from the centre out.
                let distance = abs(CGFloat(i) - CGFloat(count - 1) / 2)
                let wave = 0.5 + 0.5 * sin(tick / 30 * 2 * .pi * 1.1 - distance * 0.6)
                height = 4 + 4 * wave
                color = NSColor.white.withAlphaComponent(0.25 + 0.3 * wave)
            }
            color.setFill()
            let rect = NSRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}
