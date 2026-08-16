import AppKit
import XCTest
@testable import LinkGlint

final class StatusPanelLayoutTests: XCTestCase {
    func testMidRowCardsFillWidthEquallyAndStayFlush() {
        let leading = StatusPanelCardView()
        let trailing = StatusPanelCardView()
        let row = StatusPanelMidRowLayout.makeRow(leading: leading, trailing: trailing)

        let hostWidth = StatusPanelMidRowLayout.rowWidth
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidth, height: 200))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.frame.width, hostWidth, accuracy: 0.5)
        XCTAssertEqual(leading.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(trailing.frame.maxX, hostWidth, accuracy: 0.5)
        XCTAssertEqual(leading.frame.width, StatusPanelMidRowLayout.cardWidth, accuracy: 0.5)
        XCTAssertEqual(trailing.frame.width, StatusPanelMidRowLayout.cardWidth, accuracy: 0.5)
        XCTAssertEqual(leading.frame.width, trailing.frame.width, accuracy: 0.5)
        XCTAssertEqual(
            leading.frame.width + StatusPanelMidRowLayout.spacing + trailing.frame.width,
            hostWidth,
            accuracy: 0.5
        )
        XCTAssertEqual(leading.frame.height, StatusPanelMidRowLayout.height, accuracy: 0.5)
        XCTAssertEqual(trailing.frame.height, StatusPanelMidRowLayout.height, accuracy: 0.5)
        XCTAssertEqual(leading.frame.minY, trailing.frame.minY, accuracy: 0.5)
        XCTAssertEqual(leading.frame.maxY, trailing.frame.maxY, accuracy: 0.5)
    }

    func testMidRowRealCardsMatchPanelGeometry() {
        let trafficTitle = NSTextField(labelWithString: "实时流量")
        let range = NSTextField(labelWithString: TrafficHistoryWindowFormatter.fixedWidthString(samples: []))
        let trafficTitleRow = StatusPanelTrafficCardLayout.makeTitleRow(
            title: trafficTitle,
            rangeContainer: StatusPanelTrafficCardLayout.makeRangeContainer(label: range)
        )
        let rates = NSTextField(labelWithString: "↓ 960 B/s  ↑ 2.9 KB/s")
        let chart = TrafficChartView()
        let trafficContent = StatusPanelTrafficCardLayout.makeContent(
            titleRow: trafficTitleRow,
            rates: rates,
            chart: chart
        )
        let trafficCard = wrapStatusPanelCard(content: trafficContent)

        let ipTitle = NSTextField(labelWithString: "出口 IP")
        let address = NSTextField(labelWithString: "56.68.99.174")
        let country = NSTextField(labelWithString: "🇲🇾 马来西亚")
        let detail = NSTextField(labelWithString: "Kuala Lumpur · 亚洲")
        let ownership = NSTextField(labelWithString: "Amazon.com, Inc.")
        StatusPanelIPCardLayout.configureMetaLine(country, height: StatusPanelIPCardLayout.countryLineHeight)
        StatusPanelIPCardLayout.configureMetaLine(detail, height: StatusPanelIPCardLayout.detailLineHeight)
        StatusPanelIPCardLayout.configureMetaLine(ownership, height: StatusPanelIPCardLayout.ownershipLineHeight)
        let meta = NSStackView(views: [country, detail, ownership])
        meta.orientation = .vertical
        meta.alignment = .width
        meta.spacing = 2
        meta.translatesAutoresizingMaskIntoConstraints = false
        let ipContent = StatusPanelIPCardLayout.makeContent(title: ipTitle, address: address, meta: meta)
        let ipCard = wrapStatusPanelCard(content: ipContent)

        let row = StatusPanelMidRowLayout.makeRow(leading: trafficCard, trailing: ipCard)
        let hostWidth = StatusPanelMidRowLayout.rowWidth
        let host = NSView(frame: NSRect(x: 0, y: 0, width: hostWidth, height: 200))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.frame.width, hostWidth, accuracy: 0.5)
        XCTAssertEqual(trafficCard.frame.width, StatusPanelMidRowLayout.cardWidth, accuracy: 0.5)
        XCTAssertEqual(ipCard.frame.width, StatusPanelMidRowLayout.cardWidth, accuracy: 0.5)
    }

    private func wrapStatusPanelCard(content: NSView) -> StatusPanelCardView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = StatusPanelCardView()
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    func testTrafficChartUsesNoIntrinsicHeight() {
        let chart = TrafficChartView()
        XCTAssertEqual(chart.intrinsicContentSize.height, NSView.noIntrinsicMetric)
        XCTAssertEqual(chart.intrinsicContentSize.width, NSView.noIntrinsicMetric)
    }

    func testTrafficChartCardPinsChartToBottom() {
        let title = NSTextField(labelWithString: "实时流量")
        let range = NSTextField(labelWithString: TrafficHistoryWindowFormatter.fixedWidthString(samples: []))
        let titleRow = StatusPanelTrafficCardLayout.makeTitleRow(
            title: title,
            rangeContainer: StatusPanelTrafficCardLayout.makeRangeContainer(label: range)
        )
        let rates = NSTextField(labelWithString: "↓ 0 B/s  ↑ 0 B/s")
        let chart = TrafficChartView()
        let content = StatusPanelTrafficCardLayout.makeContent(
            titleRow: titleRow,
            rates: rates,
            chart: chart
        )

        let cardHeight = StatusPanelMidRowLayout.height
        let card = StatusPanelCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: cardHeight),
            card.widthAnchor.constraint(equalToConstant: 170),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(chart.frame.minY, 10, accuracy: 0.5)
        XCTAssertGreaterThan(chart.frame.height, 40)
    }

    func testIPMetaBlockKeepsFixedHeightWhenLinesPopulate() {
        let title = NSTextField(labelWithString: "出口 IP")
        let address = NSTextField(labelWithString: "56.68.99.174")
        let country = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        let ownership = NSTextField(labelWithString: "")
        StatusPanelIPCardLayout.configureMetaLine(country, height: StatusPanelIPCardLayout.countryLineHeight)
        StatusPanelIPCardLayout.configureMetaLine(detail, height: StatusPanelIPCardLayout.detailLineHeight)
        StatusPanelIPCardLayout.configureMetaLine(ownership, height: StatusPanelIPCardLayout.ownershipLineHeight)
        let meta = NSStackView(views: [country, detail, ownership])
        meta.orientation = .vertical
        meta.alignment = .width
        meta.spacing = 2
        meta.translatesAutoresizingMaskIntoConstraints = false

        let content = StatusPanelIPCardLayout.makeContent(title: title, address: address, meta: meta)
        let cardHeight = StatusPanelMidRowLayout.height
        let card = StatusPanelCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: cardHeight),
            card.widthAnchor.constraint(equalToConstant: 170),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        card.layoutSubtreeIfNeeded()
        let emptyMetaHeight = meta.frame.height

        country.stringValue = "🇲🇾 马来西亚"
        detail.stringValue = "Kuala Lumpur · 亚洲"
        ownership.stringValue = "Amazon.com, Inc."
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(meta.frame.height, emptyMetaHeight, accuracy: 0.5)
        XCTAssertEqual(meta.frame.height, StatusPanelIPCardLayout.metaBlockHeight, accuracy: 0.5)
        XCTAssertEqual(StatusPanelIPCardLayout.intranetGeoLineHeight, 14, accuracy: 0.5)
        XCTAssertEqual(StatusPanelIPCardLayout.intranetOwnershipLineHeight, 12, accuracy: 0.5)
        XCTAssertEqual(address.frame.maxY, title.frame.minY - 4, accuracy: 0.5)
    }

    func testTrafficHistoryWindowFormatterFixedWidth() {
        let start = Date(timeIntervalSince1970: 100)
        let samples = [
            TrafficRateSample(date: start, downloadBytesPerSecond: 10, uploadBytesPerSecond: 1),
            TrafficRateSample(date: start.addingTimeInterval(59), downloadBytesPerSecond: 20, uploadBytesPerSecond: 2)
        ]
        let values = [
            TrafficHistoryWindowFormatter.fixedWidthString(samples: []),
            TrafficHistoryWindowFormatter.fixedWidthString(samples: [samples[0]]),
            TrafficHistoryWindowFormatter.fixedWidthString(samples: samples),
            TrafficHistoryWindowFormatter.fixedWidthString(
                samples: [
                    samples[0],
                    TrafficRateSample(
                        date: start.addingTimeInterval(600),
                        downloadBytesPerSecond: 20,
                        uploadBytesPerSecond: 2
                    )
                ]
            )
        ]
        let expectedWidth = TrafficHistoryWindowFormatter.fixedWidth
        for value in values {
            XCTAssertEqual(value.count, expectedWidth, "'\(value)'")
        }
    }

}
