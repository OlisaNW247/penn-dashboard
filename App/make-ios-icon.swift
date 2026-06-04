#!/usr/bin/env swift
// Renders a 1024x1024 opaque app icon (greige background, dark serif "LHF").
// Run on macOS: swift App/make-ios-icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSColor(red: 0xF4/255.0, green: 0xF1/255.0, blue: 0xEC/255.0, alpha: 1) // greige
bg.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let ink = NSColor(red: 0x21/255.0, green: 0x1F/255.0, blue: 0x1B/255.0, alpha: 1)
let font = NSFont(name: "Times New Roman", size: 420)
    ?? NSFont(name: "Georgia", size: 420)
    ?? NSFont.systemFont(ofSize: 420)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
let text = "LHF" as NSString
let textSize = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (CGFloat(size) - textSize.width) / 2,
                      y: (CGFloat(size) - textSize.height) / 2),
          withAttributes: attrs)

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
