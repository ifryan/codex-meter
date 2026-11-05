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

/// The same three row centers align text on the left with progress on the right.
enum MeterLayout {
    static let leftWing: CGFloat = 104
    static let rightWing: CGFloat = 64
    static let capsuleWidth: CGFloat = 320
    static let compactPadding: CGFloat = 2
    static let compactHorizontalPadding: CGFloat = 8
    static let detailPadding: CGFloat = 12
    static let sectionGap: CGFloat = 10
    static let footerHeight: CGFloat = 14
    static let footerGap: CGFloat = 10
    static var detailChromeHeight: CGFloat { detailPadding * 2 + footerGap + footerHeight }

    static func headerHeight(notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? floor(notchHeight) : 32
    }

    static func wingRects(width: CGFloat, top: CGFloat, height: CGFloat, notch: NSRange?) -> [NSRect] {
        let left = notch.map { CGFloat($0.location) } ?? width * leftWing / (leftWing + rightWing)
        let right = notch.map { CGFloat($0.location + $0.length) } ?? left
        return [NSRect(x: 0, y: top - height, width: left, height: height),
                NSRect(x: right, y: top - height, width: max(0, width - right), height: height)]
    }

    static func rows(in wing: NSRect, count: Int = 3) -> [NSRect] {
        guard count > 0 else { return [] }
        let rowHeight = max(0, (wing.height - compactPadding * 2) / CGFloat(count))
        let top = wing.midY + rowHeight * CGFloat(count) / 2
        return (0..<count).map {
            NSRect(x: wing.minX + compactHorizontalPadding, y: top - CGFloat($0 + 1) * rowHeight, width: max(0, wing.width - compactHorizontalPadding * 2), height: rowHeight)
        }
    }

    static func progressTracks(in row: NSRect, paired: Bool) -> [NSRect] {
        if paired {
            let width = max(0, (row.width - 4) / 2)
            return [NSRect(x: row.minX, y: row.midY - 1.5, width: width, height: 3),
                    NSRect(x: row.maxX - width, y: row.midY - 1.5, width: width, height: 3)]
        }
        return [NSRect(x: row.minX, y: row.midY - 1.5, width: row.width, height: 3)]
    }

}

@MainActor
final class NotchMeterView: NSControl {
    var menuProvider: (() -> NSMenu)?
    var hoverChanged: ((Bool) -> Void)?
    var orderChanged: (([MeterAgent]) -> Void)?
    var dragStateChanged: ((Bool) -> Void)?
    private var agentOrder = MeterAgent.allCases
    private(set) var isDragging = false
    private var pendingDetailSections: [MeterDetailSection]?
    private let footerLabel = NSTextField(labelWithString: "最近更新 尚未更新")
    private var compactRows: [CompactMeterRowView] = []
    private var values: [MeterValue?] = [nil, nil, nil]
    private var refreshing = [false, false, false]
    private var glmConfigured = false
    private var detailSections: [MeterDetailSection] = []
    private var sectionViews: [MeterDetailSectionView] = []
    private let scrollView = NSScrollView()
    private let documentView = DetailDocumentView()
    private var hoverAreas: [NSTrackingArea] = []
    private var hasNotch = false
    private var notchWidth: CGFloat = 185
    private var notchOffset: CGFloat = MeterLayout.leftWing
    private var notchHeight: CGFloat = 32
    private var isExpanded = false
    private var refreshTicker: Timer?
    private var refreshPhase = 0
    private var monitorReadings: [PinnedReading]?
    private var monitorRows: [CompactMeterRowView] = []
    var accountOrderChanged: (([UUID]) -> Void)?

    private var headerHeight: CGFloat { MeterLayout.headerHeight(notchHeight: hasNotch ? notchHeight : 0) }
    private var notchRange: NSRange? {
        hasNotch ? NSRange(location: Int(notchOffset), length: Int(notchWidth)) : nil
    }
    private var wingRects: [NSRect] {
        MeterLayout.wingRects(width: bounds.width, top: bounds.height, height: headerHeight, notch: notchRange)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for agent in MeterAgent.allCases {
            let row = CompactMeterRowView(provider: agent)
            compactRows.append(row)
            addSubview(row)
        }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        addSubview(scrollView)
        footerLabel.font = AppFont.ubuntuMono(10)
        footerLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        footerLabel.lineBreakMode = .byTruncatingTail
        addSubview(footerLabel)
        documentView.insertionChanged = { [weak self] point in self?.updateInsertion(at: point) }
        documentView.commitDrop = { [weak self] point in self?.commitDrop(at: point) ?? false }
        toolTip = "Codex / Claude / GLM 余量 · 悬停查看详情，点击打开菜单"
    }

    required init?(coder: NSCoder) { nil }

    func configure(hasNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat, expanded: Bool, notchOffset: CGFloat = MeterLayout.leftWing) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.notchOffset = notchOffset
        isExpanded = expanded
        needsLayout = true
        needsDisplay = true
    }

    func setCodex(value: MeterValue?, isRefreshing: Bool = false) {
        update(index: 0, value: value, refreshing: isRefreshing)
    }

    func setClaude(value: MeterValue?, isRefreshing: Bool = false) {
        update(index: 1, value: value, refreshing: isRefreshing)
    }

    func setGLM(value: MeterValue?, isRefreshing: Bool = false, isConfigured: Bool = true) {
        glmConfigured = isConfigured
        update(index: 2, value: value, refreshing: isRefreshing)
    }

    func setMonitor(readings: [PinnedReading], sections: [MonitorSection]) {
        monitorReadings = Array(readings.prefix(3))
        compactRows.forEach { $0.isHidden = true }
        while monitorRows.count < min(3, readings.count) {
            let row = CompactMeterRowView(provider: .codex)
            monitorRows.append(row)
            addSubview(row)
        }
        for (index, row) in monitorRows.enumerated() { row.isHidden = index >= min(3, readings.count) }
        setDetailSections(sections.map { section in
            MeterDetailSection(agent: .codex, plan: section.plan,
                rows: section.rows.map { MeterDetailRow(title: $0.title, value: $0.value, detail: $0.detail) },
                accountID: section.accountID, accountTitle: section.title)
        })
        if readings.contains(where: \.refreshing), refreshTicker == nil {
            let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshPhase = (self.refreshPhase + 1) % 3
                    self.needsLayout = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTicker = timer
        } else if !readings.contains(where: \.refreshing) { stopRefreshAnimation() }
        setAccessibilityLabel(readings.map { $0.title + "，" + ($0.refreshing ? "正在刷新" : $0.value + " " + $0.subtitle) }.joined(separator: "；"))
        toolTip = readings.isEmpty ? "尚未固定连接 · 点击打开连接设置" : readings.map { $0.title + " " + $0.value }.joined(separator: " · ")
        needsLayout = true
        needsDisplay = true
    }

    private func update(index: Int, value: MeterValue?, refreshing: Bool) {
        values[index] = value
        self.refreshing[index] = refreshing
        if self.refreshing.contains(true), refreshTicker == nil {
            let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshPhase = (self.refreshPhase + 1) % 3
                    self.needsLayout = true
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTicker = timer
        } else if !self.refreshing.contains(true) { stopRefreshAnimation() }
        needsLayout = true
        needsDisplay = true
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel(Self.accessibilityText(
            codexPercent: values[0]?.percent, claudePercent: values[1]?.percent,
            codexRefreshing: self.refreshing[0], claudeRefreshing: self.refreshing[1],
            glmPercent: values[2]?.percent, glmRefreshing: self.refreshing[2], glmConfigured: glmConfigured, order: agentOrder
        ))
    }

    func stopRefreshAnimation() {
        refreshTicker?.invalidate()
        refreshTicker = nil
        refreshPhase = 0
    }

    static func accessibilityText(codexPercent: Int?, claudePercent: Int?, codexRefreshing: Bool, claudeRefreshing: Bool,
                                  glmPercent: Int? = nil, glmRefreshing: Bool = false, glmConfigured: Bool = false,
                                  order: [MeterAgent] = MeterAgent.allCases) -> String {
        let codex = codexRefreshing ? "Codex 正在刷新" : (codexPercent.map { "Codex 剩余 \($0)%" } ?? "Codex 余量不可用")
        let claude = claudeRefreshing ? "Claude 正在刷新" : (claudePercent.map { "Claude 剩余 \($0)%" } ?? "Claude 未接入")
        let glm = glmRefreshing ? "GLM 正在刷新" : (glmPercent.map { "GLM 剩余 \($0)%" } ?? (glmConfigured ? "GLM 余量不可用" : "GLM 未配置"))
        let descriptions = [codex, claude, glm]
        return order.map { descriptions[$0.index] }.joined(separator: "，")
    }

    var detailRowCount: Int { sectionViews.reduce(0) { $0 + $1.rowCount } }

    func setAgentOrder(_ order: [MeterAgent]) {
        agentOrder = MeterAgentOrder.normalized(order.map(\.rawValue))
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
    }

    func setUpdateText(_ text: String) {
        footerLabel.stringValue = text
        footerLabel.toolTip = text + "（各来源中最近一次成功更新，时间均为本地时间）"
    }

    func setDetailSections(_ sections: [MeterDetailSection]) {
        // Refreshes can complete during a drag; retain its source view until AppKit ends the session.
        if isDragging { pendingDetailSections = sections; return }
        guard sections != detailSections else { return }
        detailSections = sections
        sectionViews.forEach { $0.removeFromSuperview() }
        sectionViews = sections.map { section in
            let view = MeterDetailSectionView(section: section)
            view.header.dragStarted = { [weak self, weak header = view.header] in
                guard let self, let header else { return }
                self.isDragging = true
                self.documentView.activeSource = header
                self.dragStateChanged?(true)
            }
            view.header.dragEnded = { [weak self] in
                guard let self else { return }
                self.isDragging = false
                self.documentView.activeSource = nil
                self.documentView.insertionY = nil
                if let pending = self.pendingDetailSections {
                    self.pendingDetailSections = nil
                    self.setDetailSections(pending)
                }
                self.dragStateChanged?(false)
            }
            documentView.addSubview(view)
            return view
        }
        needsLayout = true
    }

    func detailHeight(width: CGFloat) -> CGFloat {
        sectionViews.reduce(0) { $0 + $1.preferredHeight(width: width) } + CGFloat(max(0, sectionViews.count - 1)) * MeterLayout.sectionGap
    }

    private func insertion(at point: NSPoint) -> (MeterAgent, Int, CGFloat)? {
        guard let source = documentView.activeSource else { return nil }
        let remaining = sectionViews.filter { $0.header.stableID != source.stableID }
        let index = remaining.firstIndex(where: { point.y < $0.frame.midY }) ?? remaining.count
        let y = index < remaining.count ? remaining[index].frame.minY - MeterLayout.sectionGap / 2
            : (remaining.last?.frame.maxY ?? 0) + MeterLayout.sectionGap / 2
        return (source.provider, index, max(1, min(documentView.bounds.height - 1, y)))
    }

    private func updateInsertion(at point: NSPoint?) {
        documentView.insertionY = point.flatMap { insertion(at: $0)?.2 }
    }

    private func commitDrop(at point: NSPoint) -> Bool {
        if monitorReadings != nil, let source = documentView.activeSource, let sourceID = UUID(uuidString: source.stableID) {
            var remaining = sectionViews.filter { $0.header.stableID != source.stableID }
            let index = remaining.firstIndex(where: { point.y < $0.frame.midY }) ?? remaining.count
            if let view = sectionViews.first(where: { $0.header.stableID == source.stableID }) { remaining.insert(view, at: index) }
            let ids = remaining.compactMap { UUID(uuidString: $0.header.stableID) }
            guard ids.contains(sourceID) else { return false }
            accountOrderChanged?(ids)
            return true
        }
        guard let (provider, index, _) = insertion(at: point) else { return false }
        let order = MeterAgentOrder.moving(provider, to: index, in: agentOrder)
        setAgentOrder(order)
        orderChanged?(order)
        return true
    }

    override func layout() {
        super.layout()
        if let readings = monitorReadings {
            for (position, rect) in MeterLayout.rows(in: wingRects[0], count: readings.count).enumerated() {
                let reading = readings[position]
                let row = monitorRows[position]
                row.frame = rect
                row.displayTitle = reading.title
                row.toolTip = reading.title + " · " + reading.value + " " + reading.subtitle
                row.update(percent: reading.refreshing ? String(repeating: "·", count: refreshPhase + 1) : reading.value,
                           time: reading.refreshing ? "" : reading.subtitle)
            }
        } else { for (position, rect) in MeterLayout.rows(in: wingRects[0]).enumerated() {
            let index = agentOrder[position].index
            let row = compactRows[index]
            row.frame = rect
            let period = values[index]?.secondaryPercent == nil
                ? (values[index]?.durationMinutes == 10_080 ? "周余量及重置倒计时" : "5 小时余量及重置倒计时")
                : "5 小时余量/周余量，5 小时重置倒计时/周重置倒计时"
            row.toolTip = "\(agentOrder[position].title)：\(period)。双进度条左侧为 5 小时，右侧为周额度。"
            if refreshing[index] {
                row.update(percent: String(repeating: "·", count: refreshPhase + 1), time: "")
            } else if let value = values[index] {
                row.update(percent: value.percentText, time: value.countdownText)
            } else {
                row.update(percent: index == 2 && !glmConfigured ? "未配置" : "--%", time: index == 2 && !glmConfigured ? "" : "--H")
            }
        } }
        scrollView.isHidden = !isExpanded
        footerLabel.isHidden = !isExpanded
        if isExpanded {
            let padding = MeterLayout.detailPadding
            footerLabel.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: MeterLayout.footerHeight)
            scrollView.frame = NSRect(x: padding, y: padding + MeterLayout.footerHeight + MeterLayout.footerGap,
                                      width: bounds.width - padding * 2,
                                      height: max(0, bounds.height - headerHeight - MeterLayout.detailChromeHeight))
            let width = scrollView.contentSize.width
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: detailHeight(width: width))
            var y: CGFloat = 0
            for section in sectionViews {
                let height = section.preferredHeight(width: width)
                section.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height + MeterLayout.sectionGap
            }
        }
        updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: hasNotch ? 10 : 16, yRadius: hasNotch ? 10 : 16).fill()
        // Fill the top corners against the physical screen edge, keeping rounded lower corners.
        if hasNotch { NSRect(x: 0, y: bounds.maxY - 10, width: bounds.width, height: 10).fill() }
        if let readings = monitorReadings {
            if readings.isEmpty {
                let text = NSAttributedString(string: "连接设置", attributes: [.font: AppFont.ubuntuMono(10), .foregroundColor: NSColor.white])
                text.draw(at: NSPoint(x: 8, y: bounds.maxY - headerHeight / 2 - text.size().height / 2))
            }
            for (position, rect) in MeterLayout.rows(in: wingRects[1], count: readings.count).enumerated() {
                let reading = readings[position]
                if reading.percent != nil {
                    for (index, track) in MeterLayout.progressTracks(in: rect, paired: reading.secondaryPercent != nil).enumerated() {
                        drawProgress(percent: index == 0 ? reading.percent : reading.secondaryPercent, in: track)
                    }
                } else {
                    let text = NSAttributedString(string: reading.title, attributes: [.font: AppFont.ubuntuMono(8), .foregroundColor: NSColor.white.withAlphaComponent(0.55)])
                    text.draw(with: rect, options: [.truncatesLastVisibleLine])
                }
            }
        } else { for (position, rect) in MeterLayout.rows(in: wingRects[1]).enumerated() {
            let value = values[agentOrder[position].index]
            let tracks = MeterLayout.progressTracks(in: rect, paired: value?.secondaryPercent != nil)
            let percentages = [value?.percent, value?.secondaryPercent]
            for (index, track) in tracks.enumerated() {
                drawProgress(percent: percentages[index], in: track)
            }
        } }
    }

    private func drawProgress(percent: Int?, in track: NSRect) {
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        guard let percent else { return }
        switch percent {
        case 50...: NSColor(red: 0.22, green: 0.94, blue: 0.52, alpha: 1).setFill()
        case 20..<50: NSColor(red: 1, green: 0.78, blue: 0.12, alpha: 1).setFill()
        default: NSColor(red: 1, green: 0.28, blue: 0.30, alpha: 1).setFill()
        }
        let progress = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(max(0, min(100, percent))) / 100, height: track.height)
        NSBezierPath(roundedRect: progress, xRadius: 1, yRadius: 1).fill()
    }

    private var activeRects: [NSRect] {
        var rects = wingRects
        if isExpanded { rects.append(NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))) }
        return rects
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hoverAreas.forEach(removeTrackingArea)
        hoverAreas = activeRects.map {
            NSTrackingArea(rect: $0, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        }
        hoverAreas.forEach(addTrackingArea)
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return activeRects.contains { $0.contains(local) }
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

    init(menuProvider: @escaping () -> NSMenu, orderChanged: @escaping ([MeterAgent]) -> Void) {
        meterView = NotchMeterView(frame: .zero)
        meterView.menuProvider = menuProvider
        meterView.orderChanged = orderChanged
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
        meterView.dragStateChanged = { [weak self] dragging in
            guard let self else { return }
            self.pendingCollapse?.cancel()
            if !dragging {
                self.applyFrame(animated: true)
                self.handleHoverSignal(self.meterView.containsScreenPoint(NSEvent.mouseLocation))
            }
        }
        panel.orderFrontRegardless()
        reposition()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPointer() }
        }
    }

    func setCodex(value: MeterValue?, isRefreshing: Bool = false) {
        meterView.setCodex(value: value, isRefreshing: isRefreshing)
    }

    func setClaude(value: MeterValue?, isRefreshing: Bool = false) {
        meterView.setClaude(value: value, isRefreshing: isRefreshing)
    }

    func setGLM(value: MeterValue?, isRefreshing: Bool = false, isConfigured: Bool = true) {
        meterView.setGLM(value: value, isRefreshing: isRefreshing, isConfigured: isConfigured)
    }

    func invalidate() {
        pendingCollapse?.cancel()
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        meterView.stopRefreshAnimation()
    }

    func setDetailSections(_ sections: [MeterDetailSection]) {
        meterView.setDetailSections(sections)
        if isExpanded && !meterView.isDragging { applyFrame(animated: true) }
    }

    func setAgentOrder(_ order: [MeterAgent]) { meterView.setAgentOrder(order) }
    func setUpdateText(_ text: String) { meterView.setUpdateText(text) }

    func setMonitor(readings: [PinnedReading], sections: [MonitorSection], orderChanged: @escaping ([UUID]) -> Void) {
        meterView.accountOrderChanged = orderChanged
        meterView.setMonitor(readings: readings, sections: sections)
        if isExpanded && !meterView.isDragging { applyFrame(animated: false) }
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
        notchHeight = hasNotch ? screen.safeAreaInsets.top : 32
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else {
            notchWidth = 132
        }
        applyFrame(animated: false)
    }

    private func setHovering(_ hovering: Bool) {
        pendingCollapse?.cancel()
        guard !meterView.isDragging else { return }
        if hovering {
            setExpanded(true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.meterView.isDragging, !self.meterView.containsScreenPoint(NSEvent.mouseLocation) else { return }
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
        let panelWidth = hasNotch ? notchWidth + MeterLayout.leftWing + MeterLayout.rightWing : MeterLayout.capsuleWidth
        let headerHeight = MeterLayout.headerHeight(notchHeight: hasNotch ? notchHeight : 0)
        let detailHeight = min(meterView.detailHeight(width: panelWidth - MeterLayout.detailPadding * 2) + MeterLayout.detailChromeHeight, screen.visibleFrame.height * 0.75)
        let panelHeight = headerHeight + (isExpanded ? detailHeight : 0)
        let x: CGFloat
        if hasNotch, let left = screen.auxiliaryTopLeftArea {
            x = left.maxX - MeterLayout.leftWing
        } else {
            x = screen.frame.midX - panelWidth / 2
        }
        let frame = NSRect(x: x.rounded(), y: (screen.frame.maxY - panelHeight).rounded(),
                           width: panelWidth.rounded(), height: panelHeight.rounded())
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
