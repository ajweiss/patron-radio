import AppKit

/// The two-line menu bar label, drawn with AppKit so text sits on whole pixels.
///
/// SwiftUI placed these tiny fonts at fractional baselines (text centered in
/// frames whose heights don't match the font's line height), which smears
/// horizontal strokes across two pixel rows — obvious on 1x displays next to the
/// crisp system clock. Here every baseline, the state glyph and the marquee
/// offset are snapped to device pixels.
final class StatusLabelView: NSView {
    struct Content: Equatable {
        var iconOnly = false
        var symbol = "radio"          // icon-only mode
        var glyph = "stop.fill"       // state glyph before the name
        var name = ""
        var subtitles: [String] = []  // one entry, or two that alternate every 15 s
    }

    static let nameFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let subtitleFont = NSFont.systemFont(ofSize: 9)
    static let glyphWidth: CGFloat = 11
    /// Baselines within the 22 pt label box (the menu bar button is 21–22 pt tall).
    private static let boxHeight: CGFloat = 22
    private static let nameBaseline: CGFloat = 9
    private static let subtitleBaseline: CGFloat = 19

    var content = Content() {
        didSet {
            guard content != oldValue else { return }
            if content.subtitles != oldValue.subtitles { scrollStart = Date() }
            updateTimer()
            needsDisplay = true
        }
    }

    private var scrollStart = Date()
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the status bar button

    deinit { timer?.invalidate() }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        updateTimer()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let top = snap((bounds.height - Self.boxHeight) / 2)
        if content.iconOnly {
            drawSymbol(content.symbol, pointSize: 14, weight: .medium,
                       centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
            return
        }

        // Line 1: state glyph + station name, glyph centered on the capitals.
        let nameBaseline = top + Self.nameBaseline
        drawSymbol(content.glyph, pointSize: 7, weight: .heavy,
                   centeredAt: NSPoint(x: (Self.glyphWidth - 2) / 2,
                                       y: nameBaseline - Self.nameFont.capHeight / 2))
        drawText(content.name, font: Self.nameFont, color: .labelColor,
                 x: Self.glyphWidth, baseline: nameBaseline, width: bounds.width - Self.glyphWidth, truncate: true)

        // Line 2: city / stream title, crawling when it doesn't fit.
        let subtitle = currentSubtitle
        let overflow = textWidth(subtitle, Self.subtitleFont) - bounds.width
        let offset = overflow > 1 ? snap(Marquee.offset(at: Date().timeIntervalSince(scrollStart), distance: overflow + 4)) : 0
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        drawText(subtitle, font: Self.subtitleFont, color: NSColor.labelColor.withAlphaComponent(0.75),
                 x: -offset, baseline: top + Self.subtitleBaseline, width: .greatestFiniteMagnitude, truncate: false)
        NSGraphicsContext.restoreGraphicsState()
    }

    private var currentSubtitle: String {
        guard content.subtitles.count > 1 else { return content.subtitles.first ?? "" }
        return content.subtitles[Int(Date().timeIntervalSinceReferenceDate / 15) % content.subtitles.count]
    }

    /// Draws a single line with its baseline exactly at `baseline` (a whole pixel).
    private func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat,
                          width: CGFloat, truncate: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncate ? .byTruncatingTail : .byClipping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let origin = NSPoint(x: snap(x), y: snap(baseline) - font.ascender)
        let rect = NSRect(x: origin.x, y: origin.y, width: max(0, width), height: ceil(font.ascender - font.descender))
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: attrs)
    }

    private func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, centeredAt c: NSPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [.labelColor]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        let rect = NSRect(x: snap(c.x - size.width / 2), y: snap(c.y - size.height / 2),
                          width: size.width, height: size.height)
        image.draw(in: rect)
    }

    private func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Rounds to the nearest device pixel.
    private func snap(_ v: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return (v * scale).rounded() / scale
    }

    // MARK: Animation

    /// Redraws only while something moves: ~30 fps while the subtitle crawls,
    /// otherwise once a second (to catch the 15 s city/title alternation).
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, !content.iconOnly else { return }
        let scrolling = content.subtitles.contains { textWidth($0, Self.subtitleFont) - bounds.width > 1 }
        let interval: TimeInterval = scrolling ? 1.0 / 30 : (content.subtitles.count > 1 ? 1 : 0)
        guard interval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTimer()
    }
}
