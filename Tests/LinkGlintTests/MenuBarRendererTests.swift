import AppKit
import XCTest
@testable import LinkGlint

final class MenuBarRendererTests: XCTestCase {
    func testDisplayPresetStandardMatchesDefaultPreferences() {
        var preferences = AppPreferences(defaults: UserDefaults(suiteName: "MenuBarRendererTests.standard")!)
        MenuBarDisplayPreset.standard.apply(to: &preferences)
        XCTAssertTrue(preferences.showMenuBarTitle)
        XCTAssertTrue(preferences.showMenuBarSpeed)
        XCTAssertTrue(preferences.menuBarSpeedTwoLines)
        XCTAssertFalse(preferences.menuBarSpeedInBits)
        XCTAssertEqual(preferences.menuBarTrafficIndicatorStyle, .coloredDots)
    }

    func testDisplayPresetMinimalHidesMenuBarText() {
        var preferences = AppPreferences(defaults: UserDefaults(suiteName: "MenuBarRendererTests.minimal")!)
        MenuBarDisplayPreset.minimal.apply(to: &preferences)
        XCTAssertFalse(preferences.showMenuBarTitle)
        XCTAssertFalse(preferences.showMenuBarSpeed)
    }

    func testDisplayPresetMatchesOnlyItsCompleteConfiguration() {
        let suite = "MenuBarRendererTests.matches.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = AppPreferences(defaults: defaults)

        MenuBarDisplayPreset.compact.apply(to: &preferences)
        XCTAssertTrue(MenuBarDisplayPreset.compact.matches(preferences))
        XCTAssertFalse(MenuBarDisplayPreset.standard.matches(preferences))

        preferences.menuBarSpeedInBits = true
        XCTAssertFalse(MenuBarDisplayPreset.compact.matches(preferences))

        MenuBarDisplayPreset.minimal.apply(to: &preferences)
        XCTAssertTrue(MenuBarDisplayPreset.minimal.matches(preferences))
        preferences.menuBarTrafficIndicatorStyle = .coloredTriangles
        XCTAssertFalse(MenuBarDisplayPreset.minimal.matches(preferences))
    }

    func testStatusSemanticsColorsAreDistinct() {
        XCTAssertEqual(MenuBarStatusSemantics.titleColor(for: "检测中"), .tertiaryLabelColor)
        XCTAssertEqual(MenuBarStatusSemantics.titleColor(for: "离线"), .secondaryLabelColor)
        XCTAssertEqual(MenuBarStatusSemantics.titleColor(for: "读取失败"), .systemOrange)
        XCTAssertNil(MenuBarStatusSemantics.titleColor(for: "无线·Office"))
    }

    func testStatusSemanticsToolTipsClarifyOfflineAndLoading() {
        XCTAssertEqual(
            MenuBarStatusSemantics.toolTip(for: "LinkGlint · 离线", networkTitle: "离线"),
            "LinkGlint · 离线 · 当前无可用网络连接"
        )
        XCTAssertEqual(
            MenuBarStatusSemantics.toolTip(for: "LinkGlint · 已连接", networkTitle: "检测中"),
            "LinkGlint · 正在检测网络状态"
        )
    }

    func testSingleLineAttributedTitleUsesDirectionColorForRateNumbers() {
        let renderer = MenuBarRenderer()
        let title = renderer.makeAttributedTitleForTesting(
            text: "无线·Office  ↓1.2 MB/s ↑42 KB/s",
            networkTitle: "无线·Office",
            indicatorStyle: .coloredDots
        )
        let downloadMarker = (title.string as NSString).range(of: "●")
        XCTAssertNotEqual(downloadMarker.location, NSNotFound)
        let downloadColor = title.attribute(.foregroundColor, at: downloadMarker.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(downloadColor, MenuBarTrafficColors.download)
        let mbRange = (title.string as NSString).range(of: "1.2")
        XCTAssertNotEqual(mbRange.location, NSNotFound)
        let numberColor = title.attribute(.foregroundColor, at: mbRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(numberColor, MenuBarTrafficColors.download)
        let unitRange = (title.string as NSString).range(of: "MB/s")
        XCTAssertNotEqual(unitRange.location, NSNotFound)
        let unitColor = title.attribute(.foregroundColor, at: unitRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(unitColor, .secondaryLabelColor)
    }

    func testSingleLineStylingDoesNotTreatArrowsInNetworkNameAsRates() {
        let renderer = MenuBarRenderer()
        let networkTitle = "无线·↓Lab↑"
        let title = renderer.makeAttributedTitleForTesting(
            text: "\(networkTitle)  ↓1.2 MB/s ↑42 KB/s",
            networkTitle: networkTitle,
            indicatorStyle: .coloredDots
        )

        XCTAssertTrue(title.string.hasPrefix(networkTitle))
        XCTAssertEqual(title.string.filter { $0 == "●" }.count, 2)
        let nameDownloadArrow = (title.string as NSString).range(of: "↓")
        let nameUploadArrow = (title.string as NSString).range(of: "↑")
        XCTAssertLessThan(nameDownloadArrow.location, (networkTitle as NSString).length)
        XCTAssertLessThan(nameUploadArrow.location, (networkTitle as NSString).length)
        XCTAssertNil(title.attribute(.foregroundColor, at: nameDownloadArrow.location, effectiveRange: nil))
        XCTAssertNil(title.attribute(.foregroundColor, at: nameUploadArrow.location, effectiveRange: nil))
    }

    func testTrafficRateAttributedStringUsesSharedDirectionColors() {
        let text = MenuBarRenderer.trafficRateAttributedString(
            downloadBytesPerSecond: 1_250_000,
            uploadBytesPerSecond: 42_000,
            usesBits: false,
            indicatorStyle: .coloredDots
        )
        let downloadMarker = (text.string as NSString).range(of: "●")
        let downloadColor = text.attribute(.foregroundColor, at: downloadMarker.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(downloadColor, MenuBarTrafficColors.download)
        let uploadMarker = (text.string as NSString).range(of: "●", options: .backwards)
        let uploadColor = text.attribute(.foregroundColor, at: uploadMarker.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(uploadColor, MenuBarTrafficColors.upload)
    }

    func testPreviewContextUsesStableSampleRates() {
        XCTAssertEqual(MenuBarRenderContext.preview.networkTitle, "无线·Office")
        XCTAssertEqual(MenuBarRenderContext.preview.downloadBytesPerSecond, 1_250_000)
        XCTAssertEqual(MenuBarRenderContext.preview.uploadBytesPerSecond, 42_000)
    }
}
