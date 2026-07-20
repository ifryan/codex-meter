import AppKit
import Foundation
import OSLog
import QuartzCore

struct RateWindow {
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

struct RateBucket {
    let id: String
    let name: String?
    let primary: RateWindow?
    let secondary: RateWindow?
}

struct ResetCredit {
    let expiresAt: Date?
}

struct UsageSnapshot {
    let plan: String?
    let main: RateBucket
    let buckets: [RateBucket]
    let resetCreditCount: Int?
    let resetCredits: [ResetCredit]
    let fetchedAt: Date
}

struct ResetCreditDisplayRow {
    let title: String
    let expiry: String
}

enum MeterError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case noResponse
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex CLI。请先安装或打开 Codex。"
        case .launchFailed(let detail):
            return "无法启动 Codex：\(detail)"
        case .noResponse:
            return "Codex 限额接口没有响应。"
        case .server(let detail):
            return "Codex 返回错误：\(detail)"
        case .invalidResponse:
            return "无法解析 Codex 限额数据。"
        }
    }
}

final class CodexUsageClient: @unchecked Sendable {
    func fetch() throws -> UsageSnapshot {
        var lastError: Error = MeterError.noResponse
        for attempt in 0..<3 {
            do {
                return try fetchOnce()
            } catch {
                lastError = error
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.35) }
            }
        }
        throw lastError
    }

    private func fetchOnce() throws -> UsageSnapshot {
        let executable = try resolveCodexExecutable()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw MeterError.launchFailed(error.localizedDescription)
        }

        let timeout = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)

        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        var buffered = Data()
        func write(_ json: String) {
            input.fileHandleForWriting.write(Data((json + "\n").utf8))
        }
        func readResponse(id: Int) throws -> [String: Any] {
            while process.isRunning {
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = buffered[..<newline]
                    buffered.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          (object["id"] as? NSNumber)?.intValue == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw MeterError.server(error["message"] as? String ?? "未知错误")
                    }
                    return object
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffered.append(chunk)
            }
            throw MeterError.noResponse
        }

        // The app-server handshake is ordered. Sending the rate-limit request before
        // initialize has completed can be silently ignored by some Codex builds.
        write(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-meter","version":"0.2.0"},"capabilities":{"experimentalApi":true}}}"#)
        _ = try readResponse(id: 1)
        write(#"{"method":"initialized"}"#)
        write(#"{"id":2,"method":"account/rateLimits/read","params":null}"#)
        let response = try readResponse(id: 2)
        guard let result = response["result"] as? [String: Any] else {
            throw MeterError.invalidResponse
        }
        return try parse(result: result)
    }

    private func resolveCodexExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw MeterError.codexNotFound
    }

    private func parse(result: [String: Any]) throws -> UsageSnapshot {
        guard let mainJSON = result["rateLimits"] as? [String: Any],
              let main = parseBucket(mainJSON, fallbackID: "codex") else {
            throw MeterError.invalidResponse
        }

        let bucketJSON = result["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let buckets = bucketJSON.compactMap { id, value in
            parseBucket(value, fallbackID: id)
        }.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }

        let credits = result["rateLimitResetCredits"] as? [String: Any]
        let resetCredits = (credits?["credits"] as? [[String: Any]] ?? []).map { credit in
            let timestamp = (credit["expiresAt"] as? NSNumber)?.doubleValue
            return ResetCredit(expiresAt: timestamp.map(Date.init(timeIntervalSince1970:)))
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return UsageSnapshot(
            plan: mainJSON["planType"] as? String,
            main: main,
            buckets: buckets,
            resetCreditCount: credits?["availableCount"] as? Int,
            resetCredits: resetCredits,
            fetchedAt: Date()
        )
    }

    private func parseBucket(_ json: [String: Any], fallbackID: String) -> RateBucket? {
        let id = json["limitId"] as? String ?? fallbackID
        return RateBucket(
            id: id,
            name: json["limitName"] as? String,
            primary: parseWindow(json["primary"]),
            secondary: parseWindow(json["secondary"])
        )
    }

    private func parseWindow(_ value: Any?) -> RateWindow? {
        guard let json = value as? [String: Any], let used = json["usedPercent"] as? Int else {
            return nil
        }
        let reset = (json["resetsAt"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(
            usedPercent: used,
            durationMinutes: json["windowDurationMins"] as? Int,
            resetsAt: reset
        )
    }
}

@MainActor
final class UsageBarsView: NSView {
    var percent = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let heights: [CGFloat] = [7, 12, 18, 12, 7]
        let activeCount = max(1, min(5, Int(ceil(Double(percent) / 20.0))))
        for index in 0..<5 {
            let height = heights[index]
            let rect = NSRect(x: CGFloat(index) * 7, y: (bounds.height - height) / 2, width: 3, height: height)
            let color = index < activeCount ? NSColor.white : NSColor.white.withAlphaComponent(0.28)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

@MainActor
final class UsageProgressView: NSView {
    var percent = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.16).setFill()
        track.fill()

        let fillWidth = max(bounds.height, bounds.width * CGFloat(percent) / 100)
        let fill = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.white.setFill()
        fill.fill()
    }
}

@MainActor
final class NotchMeterView: NSControl {
    var menuProvider: (() -> NSMenu)?
    var hoverChanged: ((Bool) -> Void)?
    private let iconView = NSImageView()
    private let valueLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--H")
    private let headingLabel = NSTextField(labelWithString: "Codex 余量")
    private let captionLabel = NSTextField(labelWithString: "本周期剩余")
    private let barsView = UsageBarsView()
    private let progressView = UsageProgressView()
    private let detailLabels = (0..<5).map { _ in NSTextField(labelWithString: "") }
    private var resetCreditLeftLabels: [NSTextField] = []
    private var resetCreditRightLabels: [NSTextField] = []
    private var hoverAreas: [NSTrackingArea] = []
    private var hasNotch = false
    private var notchWidth: CGFloat = 185
    private var isExpanded = false
    private var detailHeading = "Codex 余量"
    private var edgeProgressPercent = 0
    private var currentValueText = "--%"
    private var currentResetText = "--H"

    private var bodyWidth: CGFloat {
        if hasNotch && !isExpanded { return bounds.width }
        return isExpanded ? min(360, bounds.width) : min(260, bounds.width)
    }
    private var bodyHeight: CGFloat {
        if hasNotch && isExpanded { return max(0, bounds.height - 32) }
        return bounds.height
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "Codex 余量"
        )
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown

        valueLabel.textColor = .white
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        valueLabel.alignment = .left

        resetLabel.textColor = .white
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        resetLabel.alignment = .center

        headingLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        headingLabel.font = .systemFont(ofSize: 12, weight: .medium)

        captionLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        captionLabel.font = .systemFont(ofSize: 11, weight: .medium)

        addSubview(iconView)
        addSubview(valueLabel)
        addSubview(resetLabel)
        addSubview(headingLabel)
        addSubview(captionLabel)
        addSubview(barsView)
        addSubview(progressView)
        for label in detailLabels {
            label.textColor = NSColor.white.withAlphaComponent(0.88)
            label.font = .systemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        toolTip = "Codex 余量"
    }

    required init?(coder: NSCoder) { nil }

    func configure(hasNotch: Bool, notchWidth: CGFloat, expanded: Bool) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        isExpanded = expanded
        needsDisplay = true
        needsLayout = true
        updateTrackingAreas()
    }

    func setValue(_ text: String) {
        currentValueText = text
        valueLabel.stringValue = text
        let percent = Int(text.replacingOccurrences(of: "%", with: "")) ?? 0
        edgeProgressPercent = max(0, min(100, percent))
        barsView.percent = percent
        progressView.percent = percent
        needsDisplay = true
        setAccessibilityLabel("Codex 剩余 \(text)")
    }

    func setResetHours(_ text: String) {
        currentResetText = text
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
            left.font = .systemFont(ofSize: 12, weight: .medium)
            left.lineBreakMode = .byTruncatingTail

            let right = NSTextField(labelWithString: row.expiry)
            right.textColor = NSColor.white.withAlphaComponent(0.62)
            right.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            right.alignment = .right
            right.lineBreakMode = .byTruncatingHead

            addSubview(left)
            addSubview(right)
            resetCreditLeftLabels.append(left)
            resetCreditRightLabels.append(right)
        }
        needsLayout = true
    }

    func setDetails(heading: String, lines: [String]) {
        detailHeading = heading
        headingLabel.stringValue = heading
        for (index, label) in detailLabels.enumerated() {
            label.stringValue = index < lines.count ? lines[index] : ""
        }
    }

    override func layout() {
        super.layout()
        let bodyX = (bounds.width - bodyWidth) / 2
        if isExpanded {
            iconView.isHidden = true
            resetLabel.isHidden = false
            valueLabel.isHidden = false
            headingLabel.isHidden = true
            captionLabel.isHidden = true
            barsView.isHidden = true
            progressView.isHidden = true

            let wingWidth = (bounds.width - notchWidth) / 2
            valueLabel.alignment = .center
            valueLabel.frame = NSRect(
                x: 0,
                y: bodyHeight + 7,
                width: wingWidth,
                height: 18
            )
            resetLabel.frame = NSRect(
                x: wingWidth + notchWidth,
                y: bodyHeight + 7,
                width: wingWidth,
                height: 18
            )

            progressView.frame = .zero
            detailLabels.forEach {
                $0.isHidden = true
                $0.frame = .zero
            }
            for index in resetCreditLeftLabels.indices {
                let rowY = bodyHeight - 27 - CGFloat(index * 22)
                resetCreditLeftLabels[index].isHidden = false
                resetCreditRightLabels[index].isHidden = false
                resetCreditLeftLabels[index].frame = NSRect(x: bodyX + 20, y: rowY, width: 120, height: 18)
                resetCreditRightLabels[index].frame = NSRect(
                    x: bodyX + bodyWidth - 153,
                    y: rowY,
                    width: 133,
                    height: 18
                )
            }
        } else {
            valueLabel.isHidden = false
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            if hasNotch {
                iconView.isHidden = true
                resetLabel.isHidden = false
                headingLabel.isHidden = true
                captionLabel.isHidden = true
                barsView.isHidden = true
                progressView.isHidden = true
                let wingWidth = (bounds.width - notchWidth) / 2
                valueLabel.alignment = .center
                valueLabel.frame = NSRect(
                    x: 0,
                    y: 9,
                    width: wingWidth,
                    height: 18
                )
                resetLabel.frame = NSRect(
                    x: wingWidth + notchWidth,
                    y: 9,
                    width: wingWidth,
                    height: 18
                )
                headingLabel.frame = .zero
                captionLabel.frame = .zero
                barsView.frame = .zero
            } else {
                iconView.isHidden = false
                resetLabel.isHidden = true
                headingLabel.isHidden = false
                captionLabel.isHidden = false
                barsView.isHidden = false
                progressView.isHidden = true
                iconView.frame = NSRect(x: bodyX + 17, y: 17, width: 24, height: 24)
                headingLabel.stringValue = "Codex"
                captionLabel.stringValue = "剩余"
                headingLabel.frame = NSRect(x: bodyX + 52, y: 30, width: 110, height: 17)
                valueLabel.alignment = .left
                valueLabel.frame = NSRect(x: bodyX + 52, y: 12, width: 64, height: 18)
                captionLabel.frame = NSRect(x: bodyX + 106, y: 12, width: 86, height: 17)
                barsView.frame = NSRect(x: bodyX + bodyWidth - 51, y: 18, width: 35, height: 22)
            }
            progressView.frame = .zero
            detailLabels.forEach {
                $0.isHidden = true
                $0.frame = .zero
            }
            resetCreditLeftLabels.forEach { $0.isHidden = true; $0.frame = .zero }
            resetCreditRightLabels.forEach { $0.isHidden = true; $0.frame = .zero }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()

        if hasNotch {
            // A single continuous notch silhouette keeps the top shoulders and
            // expanded body visually connected without overlapping fill seams.
            // Keep the same horizontal inset in both states so expanding does
            // not visually change the left/right padding around the notch.
            let topRadius: CGFloat = 6
            let bottomRadius: CGFloat = 14
            notchSurfacePath(topRadius: topRadius, bottomRadius: bottomRadius).fill()
        } else {
            let bodyRect = NSRect(x: (bounds.width - bodyWidth) / 2, y: 0, width: bodyWidth, height: bodyHeight)
            NSBezierPath(roundedRect: bodyRect, xRadius: isExpanded ? 14 : 18, yRadius: isExpanded ? 14 : 18).fill()
        }

        if hasNotch && !isExpanded {
            drawCollapsedEdgeProgress()
        }
    }

    private func notchSurfacePath(topRadius: CGFloat, bottomRadius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let left = bounds.minX
        let right = bounds.maxX
        let bottom = bounds.minY
        let top = bounds.maxY

        path.move(to: NSPoint(x: left, y: top))
        appendQuadratic(
            to: NSPoint(x: left + topRadius, y: top - topRadius),
            control: NSPoint(x: left + topRadius, y: top),
            on: path
        )
        path.line(to: NSPoint(x: left + topRadius, y: bottom + bottomRadius))
        appendQuadratic(
            to: NSPoint(x: left + topRadius + bottomRadius, y: bottom),
            control: NSPoint(x: left + topRadius, y: bottom),
            on: path
        )
        path.line(to: NSPoint(x: right - topRadius - bottomRadius, y: bottom))
        appendQuadratic(
            to: NSPoint(x: right - topRadius, y: bottom + bottomRadius),
            control: NSPoint(x: right - topRadius, y: bottom),
            on: path
        )
        path.line(to: NSPoint(x: right - topRadius, y: top - topRadius))
        appendQuadratic(
            to: NSPoint(x: right, y: top),
            control: NSPoint(x: right - topRadius, y: top),
            on: path
        )
        path.close()
        return path
    }

    private func appendQuadratic(to end: NSPoint, control: NSPoint, on path: NSBezierPath) {
        let start = path.currentPoint
        let control1 = NSPoint(
            x: start.x + (control.x - start.x) * 2 / 3,
            y: start.y + (control.y - start.y) * 2 / 3
        )
        let control2 = NSPoint(
            x: end.x + (control.x - end.x) * 2 / 3,
            y: end.y + (control.y - end.y) * 2 / 3
        )
        path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    }

    private func drawCollapsedEdgeProgress() {
        let progress = edgePath(fraction: CGFloat(edgeProgressPercent) / 100)
        progress.lineCapStyle = .round
        progress.lineJoinStyle = .round

        // Two soft under-strokes build a restrained neon bloom without making
        // the edge look thicker or separating it from the black silhouette.
        NSGraphicsContext.saveGraphicsState()
        progress.lineWidth = 6
        NSColor(red: 0.18, green: 0.76, blue: 1, alpha: 0.13).setStroke()
        progress.stroke()
        progress.lineWidth = 3.4
        NSColor(red: 0.30, green: 0.90, blue: 1, alpha: 0.27).setStroke()
        progress.stroke()
        NSGraphicsContext.restoreGraphicsState()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let strokedPath = progress.cgPath.copy(
            strokingWithWidth: 1.7,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        context.addPath(strokedPath)
        context.clip()

        let colors = [
            NSColor(red: 0.20, green: 0.68, blue: 1.00, alpha: 1).cgColor,
            NSColor(red: 0.28, green: 0.92, blue: 1.00, alpha: 1).cgColor,
            NSColor(red: 0.76, green: 1.00, blue: 1.00, alpha: 1).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.72, 1]
        ) {
            let gradientBounds = progress.bounds
            context.drawLinearGradient(
                gradient,
                start: NSPoint(x: gradientBounds.minX, y: gradientBounds.midY),
                end: NSPoint(x: gradientBounds.maxX, y: gradientBounds.midY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()

    }

    private func edgePath(fraction: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let inset: CGFloat = 0.75
        let topRadius: CGFloat = 6
        let bottomRadius: CGFloat = 14
        let topY = bounds.maxY - inset
        let bottomY = bounds.minY + inset
        let verticalX = bounds.minX + topRadius + inset
        let bottomStartX = verticalX + bottomRadius
        let bottomEndX = bounds.maxX - topRadius - bottomRadius - inset
        // The physical cutout participates in the percentage calculation and
        // its bottom edge is drawn continuously as part of the same progress.
        let fullWidthProgressX = bounds.minX + bounds.width * max(0, min(1, fraction))
        let progressX = min(bottomEndX, max(bottomStartX, fullWidthProgressX))

        path.move(to: NSPoint(x: bounds.minX + inset, y: topY))
        appendQuadratic(
            to: NSPoint(x: verticalX, y: topY - topRadius),
            control: NSPoint(x: verticalX, y: topY),
            on: path
        )
        path.line(to: NSPoint(x: verticalX, y: bottomY + bottomRadius))
        appendQuadratic(
            to: NSPoint(x: bottomStartX, y: bottomY),
            control: NSPoint(x: verticalX, y: bottomY),
            on: path
        )
        path.line(to: NSPoint(x: progressX, y: bottomY))
        return path
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
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
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
        let anchor = NSPoint(x: bounds.midX, y: 0)
        menu.popUp(positioning: nil, at: anchor, in: self)
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
    private var isExpanded = false
    private var pendingCollapse: DispatchWorkItem?
    private var hoverPollTimer: Timer?
    private var pointerInside = false

    init(menuProvider: @escaping () -> NSMenu) {
        meterView = NotchMeterView(frame: .zero)
        meterView.menuProvider = menuProvider

        panel = CodexNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
        meterView.hoverChanged = { [weak self] hovering in
            self?.handleNativeHover(hovering)
        }
        panel.orderFrontRegardless()
        reposition()
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPointer() }
        }
    }

    func setValue(_ text: String) {
        meterView.setValue(text)
    }

    func setResetHours(_ text: String) {
        meterView.setResetHours(text)
    }

    func setResetCredits(_ rows: [ResetCreditDisplayRow]) {
        meterView.setResetCredits(rows)
        if isExpanded { applyFrame(animated: true) }
    }

    func setDetails(heading: String, lines: [String]) {
        meterView.setDetails(heading: heading, lines: lines)
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        self.screen = screen
        hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
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
                guard let self else { return }
                guard !self.meterView.containsScreenPoint(NSEvent.mouseLocation) else { return }
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
        // The physical-notch menu-bar region can emit unstable enter/exit events
        // while the window is resizing. Geometry polling is authoritative there.
        guard !hasNotch else { return }
        handleHoverSignal(hovering)
    }

    private func pollPointer() {
        let inside = meterView.containsScreenPoint(NSEvent.mouseLocation)
        guard inside != pointerInside else { return }
        handleHoverSignal(inside)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if expanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        applyFrame(animated: true)
    }

    private func applyFrame(animated: Bool) {
        guard let screen else { return }
        let collapsedWidth: CGFloat = hasNotch ? notchWidth + 128 : 272
        let panelWidth: CGFloat = isExpanded ? max(collapsedWidth, 309) : collapsedWidth
        // The physical cutout masks everything inside the 32pt safe-area band.
        // A 2pt chin places the progress edge just below the hardware boundary.
        let collapsedHeight: CGFloat = hasNotch ? screen.safeAreaInsets.top + 2 : 62
        let expandedBodyHeight = max(42, 16 + CGFloat(meterView.resetCreditRowCount * 22))
        let panelHeight: CGFloat = isExpanded ? (hasNotch ? 32 + expandedBodyHeight : 78) : collapsedHeight
        let physicalNotchCenterX: CGFloat
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            physicalNotchCenterX = (left.maxX + right.minX) / 2
        } else {
            physicalNotchCenterX = screen.frame.midX
        }
        let frame = NSRect(
            x: (physicalNotchCenterX - panelWidth / 2).rounded(),
            y: (screen.frame.maxY - panelHeight).rounded(),
            width: panelWidth.rounded(),
            height: panelHeight.rounded()
        )
        meterView.configure(hasNotch: hasNotch, notchWidth: notchWidth, expanded: isExpanded)
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
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.ryan.codexmeter", category: "usage")
    private let usageClient = CodexUsageClient()
    private var notchPanel: NotchPanelController!
    private var refreshTimer: Timer?
    private var snapshot: UsageSnapshot?
    private var currentError: Error?
    private var isRefreshing = false
    private var cachedRemainingPercent: Int?
    private var cachedResetAt: Date?
    private var cachedResetCreditCount = 0
    private var cachedResetCreditExpirations: [Date] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        notchPanel = NotchPanelController { [weak self] in
            self?.makeMenu() ?? NSMenu()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        cachedRemainingPercent = UserDefaults.standard.object(forKey: "lastRemainingPercent") as? Int
        let cachedResetTimestamp = UserDefaults.standard.double(forKey: "lastResetAt")
        if cachedResetTimestamp > 0 {
            cachedResetAt = Date(timeIntervalSince1970: cachedResetTimestamp)
        }
        cachedResetCreditCount = UserDefaults.standard.integer(forKey: "lastResetCreditCount")
        cachedResetCreditExpirations = (UserDefaults.standard.array(forKey: "lastResetCreditExpirations") as? [NSNumber] ?? [])
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
            .sorted()
        if let cachedRemainingPercent {
            notchPanel.setValue("\(cachedRemainingPercent)%")
        }
        notchPanel.setResetHours(resetHoursText(cachedResetAt))
        notchPanel.setResetCredits(resetCreditRows(
            count: cachedResetCreditCount,
            expirations: cachedResetCreditExpirations
        ))
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        currentError = nil
        if let snapshot {
            notchPanel.setValue(statusTitle(snapshot))
        } else if let cachedRemainingPercent {
            notchPanel.setValue("\(cachedRemainingPercent)%")
        } else {
            notchPanel.setValue("…")
        }
        updateNotchDetails()

        Task.detached(priority: .utility) { [usageClient] in
            let result = Result { try usageClient.fetch() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.currentError = nil
                    self.notchPanel.setValue(self.statusTitle(snapshot))
                    self.cachedRemainingPercent = snapshot.main.primary?.remainingPercent
                    if let remaining = self.cachedRemainingPercent {
                        UserDefaults.standard.set(remaining, forKey: "lastRemainingPercent")
                    }
                    self.cachedResetAt = snapshot.main.primary?.resetsAt
                    if let resetAt = self.cachedResetAt {
                        UserDefaults.standard.set(resetAt.timeIntervalSince1970, forKey: "lastResetAt")
                    }
                    self.notchPanel.setResetHours(self.resetHoursText(self.cachedResetAt))
                    self.cachedResetCreditCount = max(snapshot.resetCreditCount ?? 0, snapshot.resetCredits.count)
                    self.cachedResetCreditExpirations = snapshot.resetCredits.compactMap(\.expiresAt).sorted()
                    UserDefaults.standard.set(self.cachedResetCreditCount, forKey: "lastResetCreditCount")
                    UserDefaults.standard.set(
                        self.cachedResetCreditExpirations.map(\.timeIntervalSince1970),
                        forKey: "lastResetCreditExpirations"
                    )
                    self.notchPanel.setResetCredits(self.resetCreditRows(
                        count: self.cachedResetCreditCount,
                        expirations: self.cachedResetCreditExpirations
                    ))
                    self.logger.info("Fetched Codex remaining percentage: \(snapshot.main.primary?.remainingPercent ?? -1)")
                case .failure(let error):
                    self.currentError = error
                    self.notchPanel.setValue("!")
                    self.logger.error("Failed to fetch Codex usage: \(error.localizedDescription, privacy: .public)")
                }
                self.updateNotchDetails()
            }
        }
    }

    private func statusTitle(_ snapshot: UsageSnapshot) -> String {
        guard let window = snapshot.main.primary else { return "--%" }
        return "\(window.remainingPercent)%"
    }

    private func resetHoursText(_ resetAt: Date?) -> String {
        guard let resetAt else { return "--H" }
        return compactTimeText(until: resetAt)
    }

    private func resetCreditRows(count: Int, expirations: [Date]) -> [ResetCreditDisplayRow] {
        let total = max(count, expirations.count)
        guard total > 0 else {
            return [ResetCreditDisplayRow(title: "暂无可用重置卡", expiry: "--")]
        }
        return (0..<total).map { index in
            ResetCreditDisplayRow(
                title: "重置卡 \(index + 1)",
                expiry: resetCreditExpiryText(index < expirations.count ? expirations[index] : nil)
            )
        }
    }

    private func resetCreditExpiryText(_ expiresAt: Date?) -> String {
        guard let expiresAt else { return "--" }
        return "\(compactTimeText(until: expiresAt)) 后过期"
    }

    private func compactTimeText(until date: Date) -> String {
        let remainingSeconds = max(0, date.timeIntervalSinceNow)
        if remainingSeconds < 3_600 {
            return "\(Int(ceil(remainingSeconds / 60)))M"
        }
        if remainingSeconds <= 86_400 {
            return "\(Int(ceil(remainingSeconds / 3_600)))H"
        }
        return "\(Int(ceil(remainingSeconds / 86_400)))D"
    }

    private func updateNotchDetails() {
        if let snapshot {
            var lines: [String] = []
            if let primary = snapshot.main.primary {
                lines.append("Codex · \(windowText(primary))")
            }
            if let secondary = snapshot.main.secondary {
                lines.append("短周期 · \(windowText(secondary))")
            }
            for bucket in snapshot.buckets where bucket.id != snapshot.main.id {
                if let window = bucket.primary {
                    lines.append("\(bucket.name ?? bucket.id) · 剩余 \(window.remainingPercent)%")
                }
            }
            if let count = snapshot.resetCreditCount {
                lines.append("可用重置卡 · \(count) 张")
            }
            lines.append("更新于 \(Self.timeFormatter.string(from: snapshot.fetchedAt))")
            let plan = snapshot.plan?.uppercased() ?? ""
            notchPanel.setDetails(heading: "Codex 余量 \(plan)", lines: Array(lines.prefix(5)))
        } else if let currentError {
            let message = (currentError as? LocalizedError)?.errorDescription ?? currentError.localizedDescription
            notchPanel.setDetails(heading: "数据读取失败", lines: [message, "移入后点击可打开操作菜单并重试"])
        } else {
            notchPanel.setDetails(heading: "Codex 余量", lines: ["正在读取本机 Codex 数据…"])
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(title: headingText(), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        if let snapshot {
            append(bucket: snapshot.main, title: "Codex", to: menu)
            for bucket in snapshot.buckets where bucket.id != snapshot.main.id {
                menu.addItem(.separator())
                append(bucket: bucket, title: bucket.name ?? bucket.id, to: menu)
            }
            if let count = snapshot.resetCreditCount {
                menu.addItem(.separator())
                addDisabled("重置卡  \(count) 张", to: menu)
            }
            addDisabled("更新于  \(Self.timeFormatter.string(from: snapshot.fetchedAt))", to: menu)
        } else if let currentError {
            let message = (currentError as? LocalizedError)?.errorDescription ?? currentError.localizedDescription
            addDisabled(message, to: menu)
        } else {
            addDisabled("正在读取 Codex 余量…", to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: isRefreshing ? "正在刷新…" : "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshing
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "打开 Codex", action: #selector(openCodex), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Meter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func headingText() -> String {
        if let plan = snapshot?.plan { return "Codex 余量 · \(plan.uppercased())" }
        return "Codex 余量"
    }

    private func append(bucket: RateBucket, title: String, to menu: NSMenu) {
        addDisabled(title, to: menu)
        if let primary = bucket.primary {
            addDisabled(windowText(primary), to: menu)
        } else {
            addDisabled("暂无额度窗口", to: menu)
        }
        if let secondary = bucket.secondary {
            addDisabled(windowText(secondary), to: menu)
        }
    }

    private func windowText(_ window: RateWindow) -> String {
        let label = durationLabel(window.durationMinutes)
        let reset = window.resetsAt.map { Self.resetFormatter.string(from: $0) } ?? "未知"
        return "\(label)  剩余 \(window.remainingPercent)% · \(reset) 重置"
    }

    private func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "额度" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) 周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func refreshFromMenu() { refresh() }

    @objc private func screenParametersChanged() { notchPanel.reposition() }

    @objc private func openCodex() {
        let url = URL(fileURLWithPath: "/Applications/Codex.app")
        let fallback = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(fallback)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

@main
struct CodexMeterApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
