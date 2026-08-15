import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fputs("Usage: render-dmg-background.swift SOURCE.png OUTPUT.png\n", stderr)
    exit(EXIT_FAILURE)
}

let sourceURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])
let canvasSize = NSSize(width: 660, height: 400)

guard let source = NSImage(contentsOf: sourceURL),
      let sourceRep = source.representations.first else {
    fputs("Unable to read source background.\n", stderr)
    exit(EXIT_FAILURE)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Unable to allocate output bitmap.\n", stderr)
    exit(EXIT_FAILURE)
}
guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create output graphics context.\n", stderr)
    exit(EXIT_FAILURE)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
defer { NSGraphicsContext.restoreGraphicsState() }

let sourceSize = NSSize(width: sourceRep.pixelsWide, height: sourceRep.pixelsHigh)
let scale = max(canvasSize.width / sourceSize.width, canvasSize.height / sourceSize.height)
let drawnSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
let sourceRect = NSRect(
    x: (canvasSize.width - drawnSize.width) / 2,
    y: (canvasSize.height - drawnSize.height) / 2,
    width: drawnSize.width,
    height: drawnSize.height
)
source.draw(in: sourceRect, from: .zero, operation: .copy, fraction: 1)

// Keep the system-rendered copy and arrow readable over either generated source.
NSColor.black.withAlphaComponent(0.12).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 316, width: canvasSize.width, height: 84)).fill()

let title = NSAttributedString(
    string: "安装 LinkGlint",
    attributes: [
        .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        .paragraphStyle: centeredParagraph()
    ]
)
let subtitle = NSAttributedString(
    string: "将 LinkGlint 拖到 Applications 文件夹即可安装",
    attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.28, alpha: 1),
        .paragraphStyle: centeredParagraph()
    ]
)
title.draw(in: NSRect(x: 30, y: 350, width: 600, height: 24))
subtitle.draw(in: NSRect(x: 30, y: 328, width: 600, height: 18))

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 274, y: 190))
arrow.curve(
    to: NSPoint(x: 386, y: 190),
    controlPoint1: NSPoint(x: 300, y: 216),
    controlPoint2: NSPoint(x: 360, y: 216)
)
arrow.lineWidth = 3.5
NSColor(calibratedWhite: 0.24, alpha: 0.72).setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 378, y: 200))
arrowHead.line(to: NSPoint(x: 392, y: 190))
arrowHead.line(to: NSPoint(x: 378, y: 180))
arrowHead.lineWidth = 3.5
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode rendered background.\n", stderr)
    exit(EXIT_FAILURE)
}
try! png.write(to: outputURL, options: .atomic)

func centeredParagraph() -> NSMutableParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    return paragraph
}
