// Redraws Smooth's assignment card (collapsed and opened) with a swappable
// class-code face. A faithful re-draw of AssignmentCardView's numbers, not a
// screenshot. Usage: swift render.swift <repoResources> <downloads> <outDir>
import AppKit
import CoreText

let args = CommandLine.arguments
let res = URL(fileURLWithPath: args[1])
let dl = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])

for u in [res.appendingPathComponent("SpaceMono-Regular.ttf"), res.appendingPathComponent("SpaceMono-Bold.ttf"),
          res.appendingPathComponent("Inter.ttf"), res.appendingPathComponent("FamiljenGrotesk-Variable.ttf"),
          res.appendingPathComponent("Roobert-SemiBold.otf"), res.appendingPathComponent("Satoshi-Variable.ttf"),
          dl.appendingPathComponent("IBMPlexMono-SemiBold.ttf"), dl.appendingPathComponent("AtkinsonNext.ttf"),
          dl.appendingPathComponent("Gambetta-Semibold.otf")] {
    var err: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(u as CFURL, .process, &err) { print("register failed", u.lastPathComponent) }
}

func named(_ n: String, _ s: CGFloat) -> NSFont {
    guard let f = NSFont(name: n, size: s) else { fatalError("missing font \(n)") }
    return f
}
func variable(_ family: String, wght: CGFloat, _ s: CGFloat) -> NSFont {
    let tag = 0x77676874 // 'wght'
    let d = NSFontDescriptor(fontAttributes: [.family: family,
        NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [tag: wght]])
    guard let f = NSFont(descriptor: d, size: s) else { fatalError("missing \(family)") }
    return f
}

struct Candidate { let slug, label, licence: String; let size, tracking: CGFloat; let font: (CGFloat) -> NSFont }
let candidates: [Candidate] = [
    .init(slug: "0-current-space-mono", label: "Current · Space Mono Bold 9.5 / +1.1", licence: "SIL OFL, bundled",
          size: 9.5, tracking: 1.1, font: { named("SpaceMono-Bold", $0) }),
    .init(slug: "1-ibm-plex-mono", label: "A · IBM Plex Mono SemiBold 9.5 / +0.8", licence: "SIL OFL",
          size: 9.5, tracking: 0.8, font: { named("IBMPlexMono-SemiBold", $0) }),
    .init(slug: "2-atkinson-next", label: "B · Atkinson Hyperlegible Next SemiBold 10 / +0.9", licence: "SIL OFL",
          size: 10, tracking: 0.9, font: { variable("Atkinson Hyperlegible Next", wght: 600, $0) }),
    .init(slug: "3-sf-pro-condensed", label: "C · SF Pro Condensed Semibold 11 / +0.5", licence: "Apple system, 0 KB",
          size: 11, tracking: 0.5, font: { NSFont.systemFont(ofSize: $0, weight: .semibold, width: .condensed) }),
    .init(slug: "4-gambetta", label: "D · Gambetta Semibold 10.5 / +0.7", licence: "Fontshare FFL",
          size: 10.5, tracking: 0.7, font: { named("Gambetta-Semibold", $0) }),
    .init(slug: "5-roobert", label: "E · Roobert SemiBold 10 / +0.8", licence: "Displaay, commercial",
          size: 10, tracking: 0.8, font: { named("RoobertTRIAL-SemiBold", $0) }),
]

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}
struct Theme { let paper, ink, muted, accentInk, accent: NSColor; let name: String }
let light = Theme(paper: rgb(0xFFFFFF), ink: rgb(0x1B1714), muted: rgb(0x7C7060), accentInk: rgb(0x176D65), accent: rgb(0x40B3A5), name: "light")
let dark = Theme(paper: rgb(0x0B1020), ink: rgb(0xF8F1E5), muted: rgb(0xAEB8CF), accentInk: rgb(0x76D4C9), accent: rgb(0x40B3A5), name: "dark")

func draw(_ s: String, _ f: NSFont, _ c: NSColor, at p: CGPoint, kern: CGFloat = 0) -> CGSize {
    let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
    a.draw(at: p)
    return a.size()
}
func size(_ s: String, _ f: NSFont, kern: CGFloat = 0) -> CGSize {
    NSAttributedString(string: s, attributes: [.font: f, .kern: kern]).size()
}

let familjen = { (s: CGFloat) in variable("Familjen Grotesk", wght: 500, s) }
let inter9 = variable("Inter", wght: 600, 9)
let monoDue = named("SpaceMono-Regular", 18)

/// Draws one card at (x, y-top) in a flipped context; returns height.
func card(_ c: Candidate, _ t: Theme, x: CGFloat, y: CGFloat, w: CGFloat, opened: Bool, code: String = "PHYS 0151", title: String = "Problem Set 7") -> CGFloat {
    let codeFont = c.font(c.size)
    let codeH = size("P", codeFont).height
    let titleFont = familjen(20)
    let titleH = size("P", titleFont).height
    var h: CGFloat = 10 + codeH + 5 + titleH + 10
    if opened { h += 10 + 18 + 4 + 13 + 12 + 18 + 4 }
    let r = NSRect(x: x, y: y, width: w, height: h)
    t.paper.setFill(); r.fill()
    t.accent.withAlphaComponent(0.26).setFill()
    NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
    var cy = y + 10
    _ = draw(code.uppercased(), codeFont, t.accentInk, at: CGPoint(x: x + 16, y: cy), kern: c.tracking)
    cy += codeH + 5
    _ = draw(title, titleFont, t.ink, at: CGPoint(x: x + 16, y: cy))
    let due = "Thu"
    let ds = size(due, monoDue)
    _ = draw(due, monoDue, t.ink, at: CGPoint(x: x + w - 16 - ds.width, y: y + 10 + (codeH + 5 + titleH - ds.height) / 2))
    cy += titleH
    if opened {
        cy += 10
        _ = draw("Thursday, November 13 at 11:59 pm", familjen(12.5), t.ink, at: CGPoint(x: x + 16, y: cy))
        cy += 18 + 4
        _ = draw("FROM SYLLABUS", inter9, t.muted, at: CGPoint(x: x + 16, y: cy), kern: 0.4)
        cy += 13 + 12
        let b1 = draw("◷ edit date", familjen(12), t.ink, at: CGPoint(x: x + 16, y: cy))
        _ = draw("↗ open in canvas", familjen(12), t.ink, at: CGPoint(x: x + 16 + b1.width + 22, y: cy))
    }
    return h
}

func png(_ w: CGFloat, _ h: CGFloat, scale: CGFloat, _ name: String, _ body: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let flipped = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    ctx.cgContext.translateBy(x: 0, y: h); ctx.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = flipped
    body()
    NSGraphicsContext.current = nil
    // 8-bit palette-free PNG; size checked afterwards.
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}

// One PNG per face: light column and dark column, each with the collapsed
// card, the opened card, and the code enlarged 3x to show the letterforms.
let cardW: CGFloat = 370, colW: CGFloat = 402
for c in candidates {
    let H: CGFloat = 330
    png(colW * 2, H, scale: 2, c.slug) {
        for (i, t) in [light, dark].enumerated() {
            let x0 = CGFloat(i) * colW
            t.paper.setFill(); NSRect(x: x0, y: 0, width: colW, height: H).fill()
            _ = draw(c.label + "  ·  " + t.name, inter9, t.muted, at: CGPoint(x: x0 + 16, y: 10))
            var y: CGFloat = 30
            y += card(c, t, x: x0 + 16, y: y, w: cardW, opened: false) + 12
            y += card(c, t, x: x0 + 16, y: y, w: cardW, opened: true, code: "CIS 2620", title: "Homework 6: Graphs") + 14
            _ = draw("PHYS 0151  CIS 3990", c.font(c.size * 2.3), t.accentInk, at: CGPoint(x: x0 + 16, y: y), kern: c.tracking * 2.3)
        }
    }
}

// Contact sheet: every face, light then dark, collapsed card only plus the
// enlarged code.
let rowH: CGFloat = 112
png(colW * 2, rowH * CGFloat(candidates.count) + 10, scale: 1.5, "contact-sheet") {
    for (r, c) in candidates.enumerated() {
        for (i, t) in [light, dark].enumerated() {
            let x0 = CGFloat(i) * colW, y0 = CGFloat(r) * rowH
            t.paper.setFill(); NSRect(x: x0, y: y0, width: colW, height: rowH + 10).fill()
            _ = draw(c.label, inter9, t.muted, at: CGPoint(x: x0 + 16, y: y0 + 6))
            let h = card(c, t, x: x0 + 16, y: y0 + 22, w: cardW, opened: false)
            _ = draw("PHYS 0151", c.font(c.size * 2), t.accentInk, at: CGPoint(x: x0 + 16, y: y0 + 22 + h + 4), kern: c.tracking * 2)
        }
    }
}
print("done")
