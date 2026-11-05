// SPDX-License-Identifier: GPL-3.0-only
import AppKit

/// Drawing text directly avoids NSTextField's cell insets eating into the physical notch height.
@MainActor
final class CompactMeterRowView: NSView {
    let provider: MeterAgent
    var displayTitle: String
    private(set) var percentText = "--%"
    private(set) var timeText = "--H"

    init(provider: MeterAgent) {
        self.provider = provider
        displayTitle = provider.title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func update(percent: String, time: String) {
        percentText = percent
        timeText = time
        setAccessibilityLabel("\(displayTitle)，\(percent)，\(time)")
        needsDisplay = true
    }

    private func strings(size: CGFloat) -> (NSAttributedString, NSAttributedString) {
        (NSAttributedString(string: percentText, attributes: [.font: AppFont.ubuntuMonoBold(size), .foregroundColor: NSColor.white]),
         NSAttributedString(string: timeText, attributes: [.font: AppFont.ubuntuMono(size), .foregroundColor: NSColor.white.withAlphaComponent(0.65)]))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gap: CGFloat = timeText.isEmpty ? 0 : 8
        var fontSize: CGFloat = 10.5
        var text = strings(size: fontSize)
        // Fit both dimensions so larger glyphs cannot cross row or camera boundaries.
        while fontSize > 5 && (max(text.0.size().height, text.1.size().height) > bounds.height
            || text.0.size().width + text.1.size().width + gap > bounds.width) {
            fontSize -= 0.25
            text = strings(size: fontSize)
        }
        text.0.draw(at: NSPoint(x: 0, y: (bounds.height - text.0.size().height) / 2))
        text.1.draw(at: NSPoint(x: bounds.width - text.1.size().width, y: (bounds.height - text.1.size().height) / 2))
    }

    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
}
