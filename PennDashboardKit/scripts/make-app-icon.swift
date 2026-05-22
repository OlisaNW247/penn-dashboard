import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/AppIcon.iconset")
try? FileManager.default.removeItem(at: outputDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct IconImage {
    let name: String
    let pixels: Int
    let scale: CGFloat
}

let images = [
    IconImage(name: "icon_16x16.png", pixels: 16, scale: 1),
    IconImage(name: "icon_16x16@2x.png", pixels: 32, scale: 2),
    IconImage(name: "icon_32x32.png", pixels: 32, scale: 1),
    IconImage(name: "icon_32x32@2x.png", pixels: 64, scale: 2),
    IconImage(name: "icon_128x128.png", pixels: 128, scale: 1),
    IconImage(name: "icon_128x128@2x.png", pixels: 256, scale: 2),
    IconImage(name: "icon_256x256.png", pixels: 256, scale: 1),
    IconImage(name: "icon_256x256@2x.png", pixels: 512, scale: 2),
    IconImage(name: "icon_512x512.png", pixels: 512, scale: 1),
    IconImage(name: "icon_512x512@2x.png", pixels: 1024, scale: 2),
]

for image in images {
    let size = NSSize(width: image.pixels, height: image.pixels)
    let nsImage = NSImage(size: size)
    nsImage.lockFocus()

    let bounds = NSRect(origin: .zero, size: size)
    NSColor(red: 0.60, green: 0.00, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: size.width * 0.22, yRadius: size.height * 0.22).fill()

    let innerInset = size.width * 0.12
    let card = bounds.insetBy(dx: innerInset, dy: innerInset)
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: card, xRadius: size.width * 0.08, yRadius: size.height * 0.08).fill()

    let headerHeight = size.height * 0.19
    let header = NSRect(x: card.minX, y: card.maxY - headerHeight, width: card.width, height: headerHeight)
    NSColor(red: 0.00, green: 0.12, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(roundedRect: header, xRadius: size.width * 0.08, yRadius: size.height * 0.08).fill()

    NSColor(red: 0.88, green: 0.72, blue: 0.19, alpha: 1).setFill()
    let dotSize = max(2, size.width * 0.055)
    for index in 0..<3 {
        let x = card.minX + size.width * 0.16 + CGFloat(index) * size.width * 0.11
        let y = header.midY - dotSize / 2
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
    }

    let rowHeight = size.height * 0.105
    let rowWidth = card.width * 0.62
    let rowX = card.minX + card.width * 0.18
    let rowYStart = card.minY + card.height * 0.50
    let rowColors = [
        NSColor(red: 0.78, green: 0.05, blue: 0.15, alpha: 1),
        NSColor(red: 0.94, green: 0.48, blue: 0.18, alpha: 1),
        NSColor(red: 0.07, green: 0.36, blue: 0.58, alpha: 1),
    ]

    for index in 0..<3 {
        rowColors[index].setFill()
        let row = NSRect(
            x: rowX,
            y: rowYStart - CGFloat(index) * size.height * 0.16,
            width: rowWidth,
            height: rowHeight
        )
        NSBezierPath(roundedRect: row, xRadius: rowHeight / 2, yRadius: rowHeight / 2).fill()
    }

    if image.pixels >= 128 {
        let text = "P"
        let font = NSFont.systemFont(ofSize: size.width * 0.22, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: card.maxY - headerHeight * 0.83),
            withAttributes: attributes
        )
    }

    nsImage.unlockFocus()

    guard
        let tiff = nsImage.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(image.name)")
    }

    try data.write(to: outputDirectory.appendingPathComponent(image.name))
}
