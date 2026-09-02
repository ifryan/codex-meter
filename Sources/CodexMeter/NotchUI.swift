// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import QuartzCore

enum AppFont {
    static func ubuntuMono(_ size: CGFloat) -> NSFont {
        NSFont(name: "UbuntuMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func ubuntuMonoBold(_ size: CGFloat) -> NSFont {
        NSFont(name: "UbuntuMono-Bold", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .bold)
    }
}

enum EdgePathTrimmer {
    private struct Segment {
        let start: NSPoint
        let end: NSPoint
        let length: CGFloat
    }

    static func trim(_ source: NSBezierPath, fraction: CGFloat) -> NSBezierPath {
        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return NSBezierPath() }

        let flattened = source.flattened
        var segments: [Segment] = []
        var currentPoint: NSPoint?
        var subpathStart: NSPoint?
        var points = [NSPoint](repeating: .zero, count: 3)

        for index in 0..<flattened.elementCount {
            switch flattened.element(at: index, associatedPoints: &points) {
            case .moveTo:
                currentPoint = points[0]
                subpathStart = points[0]
            case .lineTo:
                if let start = currentPoint {
                    let end = points[0]
                    segments.append(Segment(start: start, end: end, length: distance(start, end)))
                    currentPoint = end
                }
            case .cubicCurveTo:
                if let start = currentPoint {
                    let end = points[2]
                    segments.append(Segment(start: start, end: end, length: distance(start, end)))
                    currentPoint = end
                }
            case .quadraticCurveTo:
                if let start = currentPoint {
                    let end = points[1]
                    segments.append(Segment(start: start, end: end, length: distance(start, end)))
                    currentPoint = end
                }
            case .closePath:
                if let start = currentPoint, let end = subpathStart {
                    segments.append(Segment(start: start, end: end, length: distance(start, end)))
                    currentPoint = end
                }
            @unknown default:
                continue
            }
        }

        let totalLength = segments.reduce(CGFloat.zero) { $0 + $1.length }
        guard totalLength > 0 else { return NSBezierPath() }
        let targetLength = totalLength * clamped
        let result = NSBezierPath()
        var consumed: CGFloat = 0

        for segment in segments {
            guard segment.length > 0 else { continue }
            if result.isEmpty { result.move(to: segment.start) }
            let remaining = targetLength - consumed
            if remaining >= segment.length {
                result.line(to: segment.end)
                consumed += segment.length
                continue
            }
            let ratio = max(0, remaining / segment.length)
            result.line(to: NSPoint(
                x: segment.start.x + (segment.end.x - segment.start.x) * ratio,
                y: segment.start.y + (segment.end.y - segment.start.y) * ratio
            ))
            break
        }
        return result
    }

    private static func distance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

@MainActor
final class UsageBarsView: NSView {
    var percent = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let heights: [CGFloat] = [7, 12, 18, 12, 7]
        let activeCount = percent <= 0 ? 0 : min(5, Int(ceil(Double(percent) / 20.0)))
        for index in 0..<5 {
            let height = heights[index]
            let rect = NSRect(x: CGFloat(index) * 7, y: (bounds.height - height) / 2, width: 3, height: height)
            (index < activeCount ? NSColor.white : NSColor.white.withAlphaComponent(0.28)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor
final class NotchMeterView: NSControl {
    var menuProvider: (() -> NSMenu)?
    var hoverChanged: ((Bool) -> Void)?

    private let iconView = NSImageView()
    /// Collapsed notch: Codex's top line (e.g. "52% 3D"). Expanded: Codex's big headline value.
    private let valueLabel = NSTextField(labelWithString: "--%")
    /// Collapsed notch: Codex's second line, only shown when the account has a second window
    /// (e.g. a 5-hour window alongside the weekly one). Hidden in expanded mode.
    private let codexSecondaryLabel = NSTextField(labelWithString: "")
    /// Collapsed notch: Claude's top line. Expanded: Claude's big headline value.
    private let resetLabel = NSTextField(labelWithString: "--H")
    /// Collapsed notch: Claude's second line (7-day), shown alongside `resetLabel`'s 5-hour line.
    private let claudeSecondaryLabel = NSTextField(labelWithString: "")
    private let headingLabel = NSTextField(labelWithString: "Codex")
    private let captionLabel = NSTextField(labelWithString: "剩余")
    private let barsView = UsageBarsView()
    private var detailLeftLabels: [NSTextField] = []
    private var detailRightLabels: [NSTextField] = []
    private var hoverAreas: [NSTrackingArea] = []
    private var hasNotch = false
    private var notchWidth: CGFloat = 185
    private var notchHeight: CGFloat = 32
    private var isExpanded = false
    private var codexEdgePercent: Int?
    private var claudeEdgePercent: Int?
    private var codexPrimaryValue: MeterValue?
    private var codexSecondaryValue: MeterValue?
    private var claudePrimaryValue: MeterValue?
    private var claudeSecondaryValue: MeterValue?

    private var bodyWidth: CGFloat {
        if hasNotch && !isExpanded { return bounds.width }
        return isExpanded ? min(360, bounds.width) : min(260, bounds.width)
    }

    private var bodyHeight: CGFloat {
        if hasNotch && isExpanded { return max(0, bounds.height - notchHeight) }
        return bounds.height
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Codex 余量")
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown

        valueLabel.textColor = .white
        valueLabel.font = AppFont.ubuntuMonoBold(16)
        valueLabel.alignment = .left
        resetLabel.textColor = .white
        resetLabel.font = AppFont.ubuntuMonoBold(16)
        resetLabel.alignment = .right
        codexSecondaryLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        codexSecondaryLabel.font = AppFont.ubuntuMono(10)
        codexSecondaryLabel.alignment = .left
        codexSecondaryLabel.isHidden = true
        claudeSecondaryLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        claudeSecondaryLabel.font = AppFont.ubuntuMono(10)
        claudeSecondaryLabel.alignment = .right
        claudeSecondaryLabel.isHidden = true
        headingLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        headingLabel.font = AppFont.ubuntuMono(12)
        captionLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        captionLabel.font = AppFont.ubuntuMono(11)

        [iconView, valueLabel, resetLabel, codexSecondaryLabel, claudeSecondaryLabel, headingLabel, captionLabel, barsView].forEach(addSubview)
        toolTip = "Codex / Claude 余量"
    }

    required init?(coder: NSCoder) { nil }

    func configure(hasNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat, expanded: Bool) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = max(1, notchHeight)
        isExpanded = expanded
        needsDisplay = true
        needsLayout = true
        updateTrackingAreas()
    }

    func setCodex(primary: MeterValue?, secondary: MeterValue?) {
        codexEdgePercent = Self.tightestPercent(primary, secondary)
        (codexPrimaryValue, codexSecondaryValue) = Self.ordered(primary, secondary)
        barsView.percent = codexEdgePercent ?? 0
        needsLayout = true
        needsDisplay = true
        updateAccessibilityLabel()
    }

    func setClaude(fiveHour: MeterValue?, sevenDay: MeterValue?) {
        claudeEdgePercent = Self.tightestPercent(fiveHour, sevenDay)
        (claudePrimaryValue, claudeSecondaryValue) = Self.ordered(fiveHour, sevenDay)
        needsLayout = true
        needsDisplay = true
        updateAccessibilityLabel()
    }

    /// The ring shows a single arc per side, so when both windows are present it tracks
    /// whichever has less remaining — the one that actually gates further use.
    private static func tightestPercent(_ a: MeterValue?, _ b: MeterValue?) -> Int? {
        [a, b].compactMap { $0?.percent }.min().map { max(0, min(100, $0)) }
    }

    /// Drops missing windows so a side with only a weekly quota still renders on the top line.
    /// Keeps the declared order (five-hour before weekly) rather than sorting by urgency, so the
    /// readout doesn't reshuffle itself as percentages drift.
    private static func ordered(_ a: MeterValue?, _ b: MeterValue?) -> (MeterValue?, MeterValue?) {
        let present = [a, b].compactMap { $0 }
        return (present.first, present.count > 1 ? present[1] : nil)
    }

    /// One window as a single line: the percentage carries the weight, the countdown trails it
    /// in smaller dim type. Two type sizes in one line is what keeps "52% 3H" from reading as
    /// one mushed-together token.
    private static func collapsedText(
        _ value: MeterValue,
        percentSize: CGFloat,
        timeSize: CGFloat,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment

        let text = NSMutableAttributedString(string: "\(value.percent)%", attributes: [
            .font: AppFont.ubuntuMonoBold(percentSize),
            .foregroundColor: percentColor(value.percent),
            .paragraphStyle: paragraph
        ])
        text.append(NSAttributedString(string: " \(value.resetText)", attributes: [
            .font: AppFont.ubuntuMono(timeSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            .paragraphStyle: paragraph
        ]))
        return text
    }

    /// Colour only appears once a quota is worth worrying about, so a healthy meter stays plain
    /// white rather than decorating every reading.
    private static func percentColor(_ percent: Int) -> NSColor {
        switch percent {
        case 50...: return .white
        case 20..<50: return NSColor(red: 1.00, green: 0.78, blue: 0.12, alpha: 1)
        default: return NSColor(red: 1.00, green: 0.45, blue: 0.45, alpha: 1)
        }
    }

    private func updateAccessibilityLabel() {
        let codexText = codexEdgePercent.map { "Codex 剩余 \($0)%" } ?? "Codex 余量不可用"
        let claudeText = claudeEdgePercent.map { "Claude 剩余 \($0)%" } ?? "Claude 未接入"
        setAccessibilityLabel("\(codexText)，\(claudeText)")
    }

    var detailRowCount: Int { detailLeftLabels.count }

    func setDetailRows(_ rows: [MeterDetailRow]) {
        detailLeftLabels.forEach { $0.removeFromSuperview() }
        detailRightLabels.forEach { $0.removeFromSuperview() }
        detailLeftLabels.removeAll()
        detailRightLabels.removeAll()

        for row in rows {
            let left = NSTextField(labelWithString: row.title)
            left.textColor = NSColor.white.withAlphaComponent(0.92)
            left.font = AppFont.ubuntuMono(12)
            left.lineBreakMode = .byTruncatingTail

            let right = NSTextField(labelWithString: row.value)
            right.textColor = NSColor.white.withAlphaComponent(0.62)
            right.font = AppFont.ubuntuMono(12)
            right.alignment = .right
            right.lineBreakMode = .byTruncatingHead

            addSubview(left)
            addSubview(right)
            detailLeftLabels.append(left)
            detailRightLabels.append(right)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bodyX = (bounds.width - bodyWidth) / 2

        if isExpanded {
            valueLabel.font = AppFont.ubuntuMonoBold(16)
            resetLabel.font = AppFont.ubuntuMonoBold(16)
            iconView.isHidden = true
            headingLabel.isHidden = true
            captionLabel.isHidden = true
            barsView.isHidden = true
            valueLabel.isHidden = false
            resetLabel.isHidden = false
            codexSecondaryLabel.isHidden = true
            claudeSecondaryLabel.isHidden = true

            if hasNotch {
                layoutNotchTopLabels()
            } else {
                valueLabel.frame = NSRect(x: bodyX + 20, y: bodyHeight - 28, width: 90, height: 22)
                resetLabel.frame = NSRect(x: bodyX + bodyWidth - 110, y: bodyHeight - 28, width: 90, height: 22)
            }

            for index in detailLeftLabels.indices {
                let rowY = hasNotch ? bodyHeight - 27 - CGFloat(index * 22) : 14 - CGFloat(index * 22)
                detailLeftLabels[index].isHidden = false
                detailRightLabels[index].isHidden = false
                detailLeftLabels[index].frame = NSRect(x: bodyX + 20, y: rowY, width: 120, height: 18)
                detailRightLabels[index].frame = NSRect(
                    x: bodyX + bodyWidth - 160,
                    y: rowY,
                    width: 140,
                    height: 18
                )
            }
            return
        }

        valueLabel.isHidden = false
        detailLeftLabels.forEach { $0.isHidden = true; $0.frame = .zero }
        detailRightLabels.forEach { $0.isHidden = true; $0.frame = .zero }
        if hasNotch {
            valueLabel.font = AppFont.ubuntuMonoBold(12)
            resetLabel.font = AppFont.ubuntuMonoBold(12)
            iconView.isHidden = true
            resetLabel.isHidden = false
            headingLabel.isHidden = true
            captionLabel.isHidden = true
            barsView.isHidden = true
            layoutNotchTopLabels()
            headingLabel.frame = .zero
            captionLabel.frame = .zero
            barsView.frame = .zero
        } else {
            valueLabel.font = AppFont.ubuntuMonoBold(16)
            // This fallback pill only has room for Codex's headline percent — the two-line
            // breakdown is reserved for the notch wings, where there's room for it.
            valueLabel.stringValue = codexEdgePercent.map { "\($0)%" } ?? "--%"
            codexSecondaryLabel.isHidden = true
            claudeSecondaryLabel.isHidden = true
            iconView.isHidden = false
            resetLabel.isHidden = true
            headingLabel.isHidden = false
            captionLabel.isHidden = false
            barsView.isHidden = false
            iconView.frame = NSRect(x: bodyX + 17, y: 17, width: 24, height: 24)
            headingLabel.frame = NSRect(x: bodyX + 52, y: 30, width: 110, height: 17)
            valueLabel.alignment = .left
            valueLabel.frame = NSRect(x: bodyX + 52, y: 12, width: 64, height: 18)
            captionLabel.frame = NSRect(x: bodyX + 106, y: 12, width: 86, height: 17)
            barsView.frame = NSRect(x: bodyX + bodyWidth - 51, y: 18, width: 35, height: 22)
        }
    }

    /// In collapsed notch mode, a side with two windows splits into two stacked lines (primary
    /// on top, brighter; secondary below, dimmer) instead of cramming both onto one line. A side
    /// with only one window gets that line centered across the full wing height, as before.
    /// Expanded mode always uses the single-line form — full detail lives in the rows below.
    /// Collapsed notch: each wing is a small stat block, one line per quota window, vertically
    /// centred in the notch band so a side with one window and a side with two still look like
    /// the same design rather than a rendering glitch. Expanded mode drops back to a single plain
    /// headline per side, because the full breakdown is already listed in the rows underneath.
    /// Collapsed notch: each wing is sized to its own data — a wing reporting two windows stacks
    /// them as a centred block, a wing reporting one centres that single reading in the notch band
    /// so it never looks top-heavy against an empty second row.
    private func layoutNotchTopLabels() {
        let wingWidth = (bounds.width - notchWidth) / 2
        let outerPadding: CGFloat = 14
        let labelWidth = max(0, wingWidth - outerPadding)
        let rightX = wingWidth + notchWidth
        let bandBottom = bounds.height - notchHeight

        if isExpanded {
            valueLabel.alignment = .left
            valueLabel.stringValue = codexPrimaryValue?.text ?? "--%"
            valueLabel.frame = NSRect(x: outerPadding, y: bandBottom, width: labelWidth, height: 22)
            resetLabel.alignment = .right
            resetLabel.stringValue = claudePrimaryValue?.text ?? "--%"
            resetLabel.frame = NSRect(x: rightX, y: bandBottom, width: labelWidth, height: 22)
            codexSecondaryLabel.isHidden = true
            claudeSecondaryLabel.isHidden = true
            return
        }

        layoutWing(
            primaryLabel: valueLabel,
            secondaryLabel: codexSecondaryLabel,
            primary: codexPrimaryValue,
            secondary: codexSecondaryValue,
            x: outerPadding,
            width: labelWidth,
            bandBottom: bandBottom,
            alignment: .left
        )
        layoutWing(
            primaryLabel: resetLabel,
            secondaryLabel: claudeSecondaryLabel,
            primary: claudePrimaryValue,
            secondary: claudeSecondaryValue,
            x: rightX,
            width: labelWidth,
            bandBottom: bandBottom,
            alignment: .right
        )
    }

    private func layoutWing(
        primaryLabel: NSTextField,
        secondaryLabel: NSTextField,
        primary: MeterValue?,
        secondary: MeterValue?,
        x: CGFloat,
        width: CGFloat,
        bandBottom: CGFloat,
        alignment: NSTextAlignment
    ) {
        primaryLabel.alignment = alignment
        secondaryLabel.alignment = alignment

        guard let primary else {
            let height: CGFloat = 15
            primaryLabel.stringValue = "--%"
            primaryLabel.frame = NSRect(
                x: x,
                y: bandBottom + (notchHeight - height) / 2,
                width: width,
                height: height
            )
            secondaryLabel.isHidden = true
            return
        }

        guard let secondary else {
            let height: CGFloat = 15
            primaryLabel.attributedStringValue = Self.collapsedText(
                primary,
                percentSize: 12.5,
                timeSize: 10,
                alignment: alignment
            )
            primaryLabel.frame = NSRect(
                x: x,
                y: bandBottom + (notchHeight - height) / 2,
                width: width,
                height: height
            )
            secondaryLabel.isHidden = true
            return
        }

        let firstRowHeight: CGFloat = 13
        let secondRowHeight: CGFloat = 12
        let block = firstRowHeight + secondRowHeight
        let blockTop = bandBottom + (notchHeight + block) / 2

        primaryLabel.attributedStringValue = Self.collapsedText(
            primary,
            percentSize: 11.5,
            timeSize: 9,
            alignment: alignment
        )
        primaryLabel.frame = NSRect(x: x, y: blockTop - firstRowHeight, width: width, height: firstRowHeight)
        secondaryLabel.attributedStringValue = Self.collapsedText(
            secondary,
            percentSize: 10.5,
            timeSize: 8.5,
            alignment: alignment
        )
        secondaryLabel.frame = NSRect(x: x, y: blockTop - block, width: width, height: secondRowHeight)
        secondaryLabel.isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        if hasNotch {
            notchSurfacePath(topRadius: 6, bottomRadius: 14).fill()
        } else {
            let bodyRect = NSRect(x: (bounds.width - bodyWidth) / 2, y: 0, width: bodyWidth, height: bodyHeight)
            NSBezierPath(roundedRect: bodyRect, xRadius: isExpanded ? 14 : 18, yRadius: isExpanded ? 14 : 18).fill()
        }
        if hasNotch && !isExpanded { drawCollapsedEdgeProgress() }
    }

    private func notchSurfacePath(topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let left = bounds.minX
        let right = bounds.maxX
        let bottom = bounds.minY
        let top = bounds.maxY
        path.move(to: NSPoint(x: left, y: top))
        appendQuadratic(to: NSPoint(x: left + topRadius, y: top - topRadius), control: NSPoint(x: left + topRadius, y: top), on: path)
        path.line(to: NSPoint(x: left + topRadius, y: bottom + bottomRadius))
        appendQuadratic(to: NSPoint(x: left + topRadius + bottomRadius, y: bottom), control: NSPoint(x: left + topRadius, y: bottom), on: path)
        path.line(to: NSPoint(x: right - topRadius - bottomRadius, y: bottom))
        appendQuadratic(to: NSPoint(x: right - topRadius, y: bottom + bottomRadius), control: NSPoint(x: right - topRadius, y: bottom), on: path)
        path.line(to: NSPoint(x: right - topRadius, y: top - topRadius))
        appendQuadratic(to: NSPoint(x: right, y: top), control: NSPoint(x: right - topRadius, y: top), on: path)
        path.close()
        return path
    }

    /// Half the notch outline, starting at the top-left corner and growing down/inward to the
    /// bottom midpoint. Fed to `EdgePathTrimmer`, this draws Codex's ring "growing" from the
    /// top-left corner — mirrored by `rightEdgePath()` for Claude.
    private func leftEdgePath() -> NSBezierPath {
        let path = NSBezierPath()
        let inset: CGFloat = 0.75
        let topRadius: CGFloat = 6
        let bottomRadius: CGFloat = 14
        let topY = bounds.maxY - inset
        let bottomY = bounds.minY + inset
        let leftVerticalX = bounds.minX + topRadius + inset
        let midX = bounds.midX

        path.move(to: NSPoint(x: bounds.minX + inset, y: topY))
        appendQuadratic(to: NSPoint(x: leftVerticalX, y: topY - topRadius), control: NSPoint(x: leftVerticalX, y: topY), on: path)
        path.line(to: NSPoint(x: leftVerticalX, y: bottomY + bottomRadius))
        appendQuadratic(to: NSPoint(x: leftVerticalX + bottomRadius, y: bottomY), control: NSPoint(x: leftVerticalX, y: bottomY), on: path)
        path.line(to: NSPoint(x: midX, y: bottomY))
        return path
    }

    /// Mirror of `leftEdgePath()`: starts at the top-right corner, grows down/inward to the
    /// bottom midpoint.
    private func rightEdgePath() -> NSBezierPath {
        let path = NSBezierPath()
        let inset: CGFloat = 0.75
        let topRadius: CGFloat = 6
        let bottomRadius: CGFloat = 14
        let topY = bounds.maxY - inset
        let bottomY = bounds.minY + inset
        let rightVerticalX = bounds.maxX - topRadius - inset
        let midX = bounds.midX

        path.move(to: NSPoint(x: bounds.maxX - inset, y: topY))
        appendQuadratic(to: NSPoint(x: rightVerticalX, y: topY - topRadius), control: NSPoint(x: rightVerticalX, y: topY), on: path)
        path.line(to: NSPoint(x: rightVerticalX, y: bottomY + bottomRadius))
        appendQuadratic(to: NSPoint(x: rightVerticalX - bottomRadius, y: bottomY), control: NSPoint(x: rightVerticalX, y: bottomY), on: path)
        path.line(to: NSPoint(x: midX, y: bottomY))
        return path
    }

    private func appendQuadratic(to end: NSPoint, control: NSPoint, on path: NSBezierPath) {
        let start = path.currentPoint
        let control1 = NSPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3)
        let control2 = NSPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3)
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    }

    private func drawCollapsedEdgeProgress() {
        drawEdgeRing(percent: codexEdgePercent, fullPath: leftEdgePath())
        drawEdgeRing(percent: claudeEdgePercent, fullPath: rightEdgePath())
    }

    private func drawEdgeRing(percent: Int?, fullPath: NSBezierPath) {
        guard let percent, percent > 0 else { return }
        let progress = EdgePathTrimmer.trim(fullPath, fraction: CGFloat(percent) / 100)
        progress.lineCapStyle = .round
        progress.lineJoinStyle = .round

        let palette = Self.ringPalette(forRemainingPercent: percent)

        progress.lineWidth = 6
        palette.glow.withAlphaComponent(0.13).setStroke()
        progress.stroke()
        progress.lineWidth = 3.4
        palette.glow.withAlphaComponent(0.27).setStroke()
        progress.stroke()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let strokedPath = progress.cgPath.copy(strokingWithWidth: 1.7, lineCap: .round, lineJoin: .round, miterLimit: 10)
        context.addPath(strokedPath)
        context.clip()
        let colors = [palette.start.cgColor, palette.middle.cgColor, palette.end.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.72, 1]) {
            let gradientBounds = fullPath.bounds
            context.drawLinearGradient(
                gradient,
                start: NSPoint(x: gradientBounds.minX, y: gradientBounds.midY),
                end: NSPoint(x: gradientBounds.maxX, y: gradientBounds.midY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    private static func ringPalette(forRemainingPercent percent: Int) -> (start: NSColor, middle: NSColor, end: NSColor, glow: NSColor) {
        switch percent {
        case 50...:
            return (
                NSColor(red: 0.08, green: 0.66, blue: 0.36, alpha: 1),
                NSColor(red: 0.22, green: 0.94, blue: 0.52, alpha: 1),
                NSColor(red: 0.76, green: 1.00, blue: 0.84, alpha: 1),
                NSColor(red: 0.20, green: 0.92, blue: 0.50, alpha: 1)
            )
        case 20..<50:
            return (
                NSColor(red: 0.94, green: 0.52, blue: 0.05, alpha: 1),
                NSColor(red: 1.00, green: 0.78, blue: 0.12, alpha: 1),
                NSColor(red: 1.00, green: 0.95, blue: 0.58, alpha: 1),
                NSColor(red: 1.00, green: 0.72, blue: 0.10, alpha: 1)
            )
        default:
            return (
                NSColor(red: 0.82, green: 0.12, blue: 0.20, alpha: 1),
                NSColor(red: 1.00, green: 0.28, blue: 0.30, alpha: 1),
                NSColor(red: 1.00, green: 0.72, blue: 0.68, alpha: 1),
                NSColor(red: 1.00, green: 0.24, blue: 0.28, alpha: 1)
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverAreas.forEach(removeTrackingArea)
        hoverAreas.removeAll()
        let rects: [NSRect]
        if hasNotch && !isExpanded {
            let wingWidth = (bounds.width - notchWidth) / 2
            rects = [
                NSRect(x: 0, y: 0, width: wingWidth, height: bounds.height),
                NSRect(x: bounds.width - wingWidth, y: 0, width: wingWidth, height: bounds.height)
            ]
        } else {
            rects = [activeBodyRect]
        }
        for rect in rects {
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: point)
        let localPoint = convert(windowPoint, from: nil)
        if hasNotch && !isExpanded {
            guard bounds.contains(localPoint) else { return false }
            let wingWidth = (bounds.width - notchWidth) / 2
            return localPoint.x <= wingWidth || localPoint.x >= bounds.width - wingWidth
        }
        return activeBodyRect.contains(localPoint)
    }

    private var activeBodyRect: NSRect {
        if hasNotch && isExpanded { return bounds }
        return NSRect(x: (bounds.width - bodyWidth) / 2, y: 0, width: bodyWidth, height: bodyHeight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: 0), in: self)
    }
}

@MainActor
final class CodexNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    let panel: NSPanel
    private let meterView: NotchMeterView
    private var screen: NSScreen?
    private var hasNotch = false
    private var notchWidth: CGFloat = 185
    private var notchHeight: CGFloat = 32
    private var isExpanded = false
    private var pendingCollapse: DispatchWorkItem?
    private var hoverPollTimer: Timer?
    private var pointerInside = false

    init(menuProvider: @escaping () -> NSMenu) {
        meterView = NotchMeterView(frame: .zero)
        meterView.menuProvider = menuProvider
        panel = CodexNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = meterView
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        meterView.hoverChanged = { [weak self] hovering in self?.handleNativeHover(hovering) }
        panel.orderFrontRegardless()
        reposition()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPointer() }
        }
    }

    func setCodex(primary: MeterValue?, secondary: MeterValue?) { meterView.setCodex(primary: primary, secondary: secondary) }
    func setClaude(fiveHour: MeterValue?, sevenDay: MeterValue?) { meterView.setClaude(fiveHour: fiveHour, sevenDay: sevenDay) }

    func invalidate() {
        pendingCollapse?.cancel()
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    func setDetailRows(_ rows: [MeterDetailRow]) {
        meterView.setDetailRows(rows)
        if isExpanded { applyFrame(animated: true) }
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
        notchHeight = hasNotch ? screen.safeAreaInsets.top : 32
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(132, right.minX - left.maxX)
        } else {
            notchWidth = 132
        }
        applyFrame(animated: false)
    }

    private func setHovering(_ hovering: Bool) {
        pendingCollapse?.cancel()
        if hovering {
            setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.meterView.containsScreenPoint(NSEvent.mouseLocation) else { return }
                self.setExpanded(false)
            }
            pendingCollapse = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    private func handleHoverSignal(_ hovering: Bool) {
        pointerInside = hovering
        setHovering(hovering)
    }

    private func handleNativeHover(_ hovering: Bool) {
        guard !hasNotch else { return }
        handleHoverSignal(hovering)
    }

    private func pollPointer() {
        guard hasNotch else { return }
        let inside = meterView.containsScreenPoint(NSEvent.mouseLocation)
        guard inside != pointerInside else { return }
        handleHoverSignal(inside)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if expanded { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        applyFrame(animated: true)
    }

    private func applyFrame(animated: Bool) {
        guard let screen else { return }
        let collapsedWidth: CGFloat = hasNotch ? notchWidth + 168 : 272
        let panelWidth: CGFloat = isExpanded ? max(collapsedWidth, 320) : collapsedWidth
        let collapsedHeight: CGFloat = hasNotch ? notchHeight + 2 : 62
        let expandedBodyHeight = max(42, 16 + CGFloat(meterView.detailRowCount * 22))
        let panelHeight: CGFloat = isExpanded ? (hasNotch ? notchHeight + expandedBodyHeight : 78) : collapsedHeight
        let centerX: CGFloat
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        } else {
            centerX = screen.frame.midX
        }
        let frame = NSRect(
            x: (centerX - panelWidth / 2).rounded(),
            y: (screen.frame.maxY - panelHeight).rounded(),
            width: panelWidth.rounded(),
            height: panelHeight.rounded()
        )
        meterView.configure(hasNotch: hasNotch, notchWidth: notchWidth, notchHeight: notchHeight, expanded: isExpanded)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = isExpanded ? 0.22 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.9, 0.22, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    private func targetScreen() -> NSScreen? {
        if let main = NSScreen.main,
           main.safeAreaInsets.top > 0,
           main.auxiliaryTopLeftArea != nil {
            return main
        }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
