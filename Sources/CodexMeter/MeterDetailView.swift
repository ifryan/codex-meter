// SPDX-License-Identifier: GPL-3.0-only
import AppKit

@MainActor
final class MeterDragHeaderView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("io.github.ifryan.codexmeter.agent-order")
    let provider: MeterAgent
    let stableID: String
    var dragStarted: (() -> Void)?
    var dragEnded: (() -> Void)?
    private let titleLabel: NSTextField
    private let planLabel: NSTextField
    private let grip = NSImageView()
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    override var isFlipped: Bool { true }

    init(provider: MeterAgent, plan: String?, stableID: String? = nil, title: String? = nil) {
        self.provider = provider
        self.stableID = stableID ?? provider.rawValue
        let name = title ?? provider.title
        titleLabel = NSTextField(labelWithString: name)
        planLabel = NSTextField(labelWithString: plan ?? "")
        super.init(frame: .zero)
        titleLabel.font = AppFont.ubuntuMonoBold(12)
        titleLabel.textColor = .white
        planLabel.font = AppFont.ubuntuMono(11)
        planLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        planLabel.alignment = .right
        planLabel.lineBreakMode = .byTruncatingTail
        planLabel.toolTip = plan
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")
        grip.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        [grip, titleLabel, planLabel].forEach(addSubview)
        toolTip = "拖动调整 \(name) 的排列顺序，刘海显示同步更新"
        setAccessibilityLabel(name + (plan.map { "，套餐 \($0)" } ?? "") + "，拖动排序")
    }

    required init?(coder: NSCoder) { nil }

    var preferredHeight: CGFloat {
        max(22, ceil(max(titleLabel.intrinsicContentSize.height, planLabel.intrinsicContentSize.height)) + 4)
    }

    override func layout() {
        super.layout()
        grip.frame = NSRect(x: 0, y: (bounds.height - 12) / 2, width: 10, height: 12)
        // Leave actual cell/glyph slack instead of clipping the title to its measured advance.
        let titleWidth = min(max(76, ceil(titleLabel.intrinsicContentSize.width) + 10), max(76, bounds.width * 0.65))
        titleLabel.lineBreakMode = .byTruncatingTail
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height) + 2
        titleLabel.frame = NSRect(x: 18, y: (bounds.height - titleHeight) / 2, width: titleWidth, height: titleHeight)
        let planX = titleLabel.frame.maxX + 12
        let planHeight = ceil(planLabel.intrinsicContentSize.height) + 2
        planLabel.frame = NSRect(x: planX, y: (bounds.height - planHeight) / 2,
                                 width: max(0, bounds.width - planX), height: planHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        let item = NSPasteboardItem()
        item.setString(stableID, forType: Self.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        dragging = true
        dragStarted?()
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseDownPoint = nil
        dragEnded?()
    }
}

@MainActor
final class DetailDocumentView: NSView {
    weak var activeSource: MeterDragHeaderView?
    var insertionChanged: ((NSPoint?) -> Void)?
    var commitDrop: ((NSPoint) -> Bool)?
    var insertionY: CGFloat? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([MeterDragHeaderView.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard let source = activeSource,
              let senderSource = sender.draggingSource as? MeterDragHeaderView else { return false }
        return source === senderSource
            && sender.draggingPasteboard.string(forType: MeterDragHeaderView.pasteboardType) == source.stableID
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        // Periodic drag updates scroll long panels even when the pointer pauses at an edge.
        if let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            let point = convert(sender.draggingLocation, from: nil)
            let direction: CGFloat = point.y < clip.bounds.minY + 24 ? -1 : (point.y > clip.bounds.maxY - 24 ? 1 : 0)
            if direction != 0 {
                let y = max(0, min(max(0, bounds.height - clip.bounds.height), clip.bounds.minY + direction * 10))
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        insertionChanged?(convert(sender.draggingLocation, from: nil))
        return .move
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertionChanged?(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        return commitDrop?(convert(sender.draggingLocation, from: nil)) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let insertionY else { return }
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: insertionY - 1, width: bounds.width, height: 2).fill()
    }
}

/// Shared quota blocks keep the percentage above the full reset date and countdown.
@MainActor
final class MeterDetailSectionView: NSView {
    let header: MeterDragHeaderView
    private let separator = NSView()
    private struct Row {
        let title: NSTextField
        let value: NSTextField
        let detail: NSTextField?
    }
    private let labels: [Row]
    private let padding: CGFloat = 12
    private let rowGap: CGFloat = 10
    override var isFlipped: Bool { true }
    var rowCount: Int { labels.count }

    init(section: MeterDetailSection) {
        header = MeterDragHeaderView(provider: section.agent, plan: section.plan, stableID: section.stableID, title: section.title)
        labels = section.rows.map { row in
            let title = NSTextField(wrappingLabelWithString: row.title)
            let value = NSTextField(wrappingLabelWithString: row.value)
            title.font = AppFont.ubuntuMono(11)
            value.font = AppFont.ubuntuMono(11)
            title.textColor = NSColor.white.withAlphaComponent(0.55)
            value.textColor = NSColor.white.withAlphaComponent(0.85)
            value.alignment = .right
            title.toolTip = row.title
            value.toolTip = row.value
            let detail = row.detail.map { text -> NSTextField in
                let label = NSTextField(wrappingLabelWithString: text)
                label.font = AppFont.ubuntuMono(10)
                label.textColor = NSColor.white.withAlphaComponent(0.5)
                label.toolTip = text + "（本地时间）"
                return label
            }
            return Row(title: title, value: value, detail: detail)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        addSubview(header)
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(separator)
        for row in labels {
            addSubview(row.title)
            addSubview(row.value)
            if let detail = row.detail { addSubview(detail) }
        }
        setAccessibilityLabel(section.title + " 用量明细")
    }

    required init?(coder: NSCoder) { nil }

    private func titleWidth(for width: CGFloat) -> CGFloat { min(122, max(78, (width - padding * 2) * 0.4)) }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        // NSTextField's cell includes its text insets; measuring the cell matches actual wrapping.
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: 10_000)).height ?? 14)
    }

    private func headingHeight(_ row: Row, width: CGFloat) -> CGFloat {
        let left = titleWidth(for: width)
        return max(14, max(textHeight(row.title, width: left), textHeight(row.value, width: width - padding * 2 - left - 12)))
    }

    private func rowHeight(_ row: Row, width: CGFloat) -> CGFloat {
        headingHeight(row, width: width) + (row.detail.map { 4 + textHeight($0, width: width - padding * 2) } ?? 0)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        padding * 2 + header.preferredHeight + 8 + 1 + 8 + labels.reduce(0) { $0 + rowHeight($1, width: width) }
            + CGFloat(max(0, labels.count - 1)) * rowGap
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        header.frame = NSRect(x: padding, y: padding, width: width - padding * 2, height: header.preferredHeight)
        separator.frame = NSRect(x: padding, y: header.frame.maxY + 8, width: width - padding * 2, height: 1)
        let leftWidth = titleWidth(for: width)
        var y = separator.frame.maxY + 8
        for row in labels {
            let heading = headingHeight(row, width: width)
            row.title.frame = NSRect(x: padding, y: y, width: leftWidth, height: heading)
            row.value.frame = NSRect(x: padding + leftWidth + 12, y: y, width: width - padding * 2 - leftWidth - 12, height: heading)
            if let detail = row.detail {
                detail.frame = NSRect(x: padding, y: y + heading + 4, width: width - padding * 2,
                                      height: textHeight(detail, width: width - padding * 2))
            }
            y += rowHeight(row, width: width) + rowGap
        }
    }
}
