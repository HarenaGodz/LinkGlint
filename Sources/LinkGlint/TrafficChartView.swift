import AppKit

final class TrafficChartView: NSView {
    var samples: [TrafficRateSample] = [] {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 46) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 2, bounds.height > 2 else { return }

        let plotRect = bounds.insetBy(dx: 1, dy: 2)
        NSColor.separatorColor.withAlphaComponent(0.16).setStroke()
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            let y = plotRect.minY + plotRect.height * fraction
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plotRect.minX, y: y))
            grid.line(to: NSPoint(x: plotRect.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }

        guard !samples.isEmpty else { return }
        let peak = max(samples.reduce(0) { max($0, $1.downloadBytesPerSecond, $1.uploadBytesPerSecond) }, 1)
        drawSeries(
            samples.map(\.downloadBytesPerSecond),
            in: plotRect,
            peak: peak,
            color: .systemBlue
        )
        drawSeries(
            samples.map(\.uploadBytesPerSecond),
            in: plotRect,
            peak: peak,
            color: .systemOrange
        )
    }

    private func drawSeries(_ values: [Double], in rect: NSRect, peak: Double, color: NSColor) {
        guard !values.isEmpty else { return }
        let points = values.enumerated().map { index, value -> NSPoint in
            let xFraction = values.count == 1 ? 1 : CGFloat(index) / CGFloat(values.count - 1)
            let normalized = CGFloat(log1p(max(value, 0)) / log1p(peak))
            return NSPoint(
                x: rect.minX + rect.width * xFraction,
                y: rect.maxY - rect.height * min(max(normalized, 0), 1)
            )
        }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: points[0].x, y: rect.maxY))
        points.forEach { fill.line(to: $0) }
        if let lastPoint = points.last {
            fill.line(to: NSPoint(x: lastPoint.x, y: rect.maxY))
        }
        fill.close()
        color.withAlphaComponent(0.10).setFill()
        fill.fill()

        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        color.setStroke()
        line.stroke()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("实时流量曲线")
    }

    private var accessibilitySummary: String {
        guard let latest = samples.last else { return "暂无流量数据" }
        return "下载 \(TrafficRateFormatter.string(bytesPerSecond: latest.downloadBytesPerSecond, usesBits: false))，上传 \(TrafficRateFormatter.string(bytesPerSecond: latest.uploadBytesPerSecond, usesBits: false))"
    }
}
