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
    private let valueLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--H")
    private let headingLabel = NSTextField(labelWithString: "Codex")
    private let captionLabel = NSTextField(labelWithString: "剩余")
    private let barsView = UsageBarsView()
    private var resetCreditLeftLabels: [NSTextField] = []
    private var resetCreditRightLabels: [NSTextField] = []
    private var hoverAreas: [NSTrackingArea] = []
    private var hasNotch = false
    private var notchWidth: CGFloat = 185
    private var notchHeight: CGFloat = 32
    private var isExpanded = false
    private var edgeProgressPercent: Int?

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
        headingLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        headingLabel.font = AppFont.ubuntuMono(12)
        captionLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        captionLabel.font = AppFont.ubuntuMono(11)

        [iconView, valueLabel, resetLabel, headingLabel, captionLabel, barsView].forEach(addSubview)
        toolTip = "Codex 余量"
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

    func setRemainingPercent(_ percent: Int?) {
        edgeProgressPercent = percent.map { max(0, min(100, $0)) }
        valueLabel.stringValue = edgeProgressPercent.map { "\($0)%" } ?? "--%"
        barsView.percent = edgeProgressPercent ?? 0
        needsDisplay = true
        setAccessibilityLabel(edgeProgressPercent.map { "Codex 剩余 \($0)%" } ?? "Codex 余量不可用")
    }

    func setResetText(_ text: String) {
        resetLabel.stringValue = text
    }

    var resetCreditRowCount: Int { resetCreditLeftLabels.count }

    func setResetCredits(_ rows: [ResetCreditDisplayRow]) {
        resetCreditLeftLabels.forEach { $0.removeFromSuperview() }
        resetCreditRightLabels.forEach { $0.removeFromSuperview() }
        resetCreditLeftLabels.removeAll()
        resetCreditRightLabels.removeAll()

        for row in rows {
            let left = NSTextField(labelWithString: row.title)
            left.textColor = NSColor.white.withAlphaComponent(0.92)
            left.font = AppFont.ubuntuMono(12)
            left.lineBreakMode = .byTruncatingTail

            let right = NSTextField(labelWithString: row.expiry)
            right.textColor = NSColor.white.withAlphaComponent(0.62)
            right.font = AppFont.ubuntuMono(12)
            right.alignment = .right
            right.lineBreakMode = .byTruncatingHead

            addSubview(left)
            addSubview(right)
            resetCreditLeftLabels.append(left)
            resetCreditRightLabels.append(right)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let bodyX = (bounds.width - bodyWidth) / 2
        valueLabel.font = AppFont.ubuntuMonoBold(16)

        if isExpanded {
            iconView.isHidden = true
            headingLabel.isHidden = true
            captionLabel.isHidden = true
            barsView.isHidden = true
            valueLabel.isHidden = false
            resetLabel.isHidden = false

            if hasNotch {
                layoutNotchTopLabels()
            } else {
                valueLabel.frame = NSRect(x: bodyX + 20, y: bodyHeight - 28, width: 90, height: 22)
                resetLabel.frame = NSRect(x: bodyX + bodyWidth - 110, y: bodyHeight - 28, width: 90, height: 22)
            }

            for index in resetCreditLeftLabels.indices {
                let rowY = hasNotch ? bodyHeight - 27 - CGFloat(index * 22) : 14 - CGFloat(index * 22)
                resetCreditLeftLabels[index].isHidden = false
                resetCreditRightLabels[index].isHidden = false
                resetCreditLeftLabels[index].frame = NSRect(x: bodyX + 20, y: rowY, width: 120, height: 18)
                resetCreditRightLabels[index].frame = NSRect(
                    x: bodyX + bodyWidth - 160,
                    y: rowY,
                    width: 140,
                    height: 18
                )
            }
            return
        }

        valueLabel.isHidden = false
        resetCreditLeftLabels.forEach { $0.isHidden = true; $0.frame = .zero }
        resetCreditRightLabels.forEach { $0.isHidden = true; $0.frame = .zero }
        if hasNotch {
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

    private func layoutNotchTopLabels() {
        let wingWidth = (bounds.width - notchWidth) / 2
        let outerPadding: CGFloat = 20
        let labelWidth = max(0, wingWidth - outerPadding)
        let topLabelY = bounds.height - notchHeight

        valueLabel.alignment = .left
        valueLabel.frame = NSRect(x: outerPadding, y: topLabelY, width: labelWidth, height: 22)
        resetLabel.alignment = .right
        resetLabel.frame = NSRect(
            x: wingWidth + notchWidth,
            y: topLabelY,
            width: labelWidth,
            height: 22
        )
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

    private func fullEdgePath() -> NSBezierPath {
        let path = NSBezierPath()
        let inset: CGFloat = 0.75
        let topRadius: CGFloat = 6
        let bottomRadius: CGFloat = 14
        let topY = bounds.maxY - inset
        let bottomY = bounds.minY + inset
        let leftVerticalX = bounds.minX + topRadius + inset
        let rightVerticalX = bounds.maxX - topRadius - inset

        path.move(to: NSPoint(x: bounds.minX + inset, y: topY))
        appendQuadratic(to: NSPoint(x: leftVerticalX, y: topY - topRadius), control: NSPoint(x: leftVerticalX, y: topY), on: path)
        path.line(to: NSPoint(x: leftVerticalX, y: bottomY + bottomRadius))
        appendQuadratic(to: NSPoint(x: leftVerticalX + bottomRadius, y: bottomY), control: NSPoint(x: leftVerticalX, y: bottomY), on: path)
        path.line(to: NSPoint(x: rightVerticalX - bottomRadius, y: bottomY))
        appendQuadratic(to: NSPoint(x: rightVerticalX, y: bottomY + bottomRadius), control: NSPoint(x: rightVerticalX, y: bottomY), on: path)
        path.line(to: NSPoint(x: rightVerticalX, y: topY - topRadius))
        appendQuadratic(to: NSPoint(x: bounds.maxX - inset, y: topY), control: NSPoint(x: rightVerticalX, y: topY), on: path)
        return path
    }

    private func appendQuadratic(to end: NSPoint, control: NSPoint, on path: NSBezierPath) {
        let start = path.currentPoint
        let control1 = NSPoint(x: start.x + (control.x - start.x) * 2 / 3, y: start.y + (control.y - start.y) * 2 / 3)
        let control2 = NSPoint(x: end.x + (control.x - end.x) * 2 / 3, y: end.y + (control.y - end.y) * 2 / 3)
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    }

    private func drawCollapsedEdgeProgress() {
        guard let edgeProgressPercent, edgeProgressPercent > 0 else { return }
        let fullPath = fullEdgePath()
        let progress = EdgePathTrimmer.trim(fullPath, fraction: CGFloat(edgeProgressPercent) / 100)
        progress.lineCapStyle = .round
        progress.lineJoinStyle = .round

        let palette: (start: NSColor, middle: NSColor, end: NSColor, glow: NSColor)
        switch edgeProgressPercent {
        case 50...:
            palette = (
                NSColor(red: 0.08, green: 0.66, blue: 0.36, alpha: 1),
                NSColor(red: 0.22, green: 0.94, blue: 0.52, alpha: 1),
                NSColor(red: 0.76, green: 1.00, blue: 0.84, alpha: 1),
                NSColor(red: 0.20, green: 0.92, blue: 0.50, alpha: 1)
            )
        case 20..<50:
            palette = (
                NSColor(red: 0.94, green: 0.52, blue: 0.05, alpha: 1),
                NSColor(red: 1.00, green: 0.78, blue: 0.12, alpha: 1),
                NSColor(red: 1.00, green: 0.95, blue: 0.58, alpha: 1),
                NSColor(red: 1.00, green: 0.72, blue: 0.10, alpha: 1)
            )
        default:
            palette = (
                NSColor(red: 0.82, green: 0.12, blue: 0.20, alpha: 1),
                NSColor(red: 1.00, green: 0.28, blue: 0.30, alpha: 1),
                NSColor(red: 1.00, green: 0.72, blue: 0.68, alpha: 1),
                NSColor(red: 1.00, green: 0.24, blue: 0.28, alpha: 1)
            )
        }

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

    func setRemainingPercent(_ percent: Int?) { meterView.setRemainingPercent(percent) }
    func setResetText(_ text: String) { meterView.setResetText(text) }

    func invalidate() {
        pendingCollapse?.cancel()
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    func setResetCredits(_ rows: [ResetCreditDisplayRow]) {
        meterView.setResetCredits(rows)
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
        let collapsedWidth: CGFloat = hasNotch ? notchWidth + 128 : 272
        let panelWidth: CGFloat = isExpanded ? max(collapsedWidth, 320) : collapsedWidth
        let collapsedHeight: CGFloat = hasNotch ? notchHeight + 2 : 62
        let expandedBodyHeight = max(42, 16 + CGFloat(meterView.resetCreditRowCount * 22))
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
