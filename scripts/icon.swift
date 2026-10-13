// draws the app icon: print layers whose top layer is a progress bar, with the nozzle at its edge.
// usage: swift scripts/icon.swift <out.png> [size]

import AppKit

let out = CommandLine.arguments[1]
let px = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let s = CGFloat(px) / 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }
func pill(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius * s, yRadius: radius * s) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// body on the macOS icon grid: 824 pt square, 185 pt corners, soft drop shadow
let body = pill(rect(100, 100, 824, 824), 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = rgb(0x000000, 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
shadow.shadowBlurRadius = 28 * s
shadow.set()
rgb(0x15171E).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(starting: rgb(0x2A2E3B), ending: rgb(0x111318))!.draw(in: body, angle: -90)
// faint top sheen
NSGradient(starting: rgb(0xFFFFFF, 0.08), ending: rgb(0xFFFFFF, 0))!.draw(in: rect(100, 600, 824, 324), angle: -90)
NSGraphicsContext.restoreGraphicsState()
rgb(0xFFFFFF, 0.07).setStroke()
let rim = pill(rect(102, 102, 820, 820), 183)
rim.lineWidth = 3 * s
rim.stroke()

// layers: three printed ones, then the layer being printed as a progress bar
let x0: CGFloat = 252, w: CGFloat = 520, h: CGFloat = 62, gap: CGFloat = 22
let printed = [rgb(0xF2EFE9, 0.42), rgb(0xF2EFE9, 0.62), rgb(0xF2EFE9, 0.85)]
for (i, c) in printed.enumerated() {
    c.setFill()
    pill(rect(x0, 236 + CGFloat(i) * (h + gap), w, h), h / 2).fill()
}
let topY = 236 + 3 * (h + gap)
rgb(0xFFFFFF, 0.12).setFill()
pill(rect(x0, topY, w, h), h / 2).fill()
let progress: CGFloat = 0.62
let fill = pill(rect(x0, topY, w * progress, h), h / 2)
NSGradient(starting: rgb(0xFF9A3C), ending: rgb(0xFF6A1F))!.draw(in: fill, angle: 0)

// nozzle right where the bar is filling: flat-ended tip, heat block, heat break
let nx = x0 + w * progress
let tipY = topY + h + 12
let tip = NSBezierPath()
tip.move(to: NSPoint(x: (nx - 12) * s, y: tipY * s))
tip.line(to: NSPoint(x: (nx + 12) * s, y: tipY * s))
tip.line(to: NSPoint(x: (nx + 38) * s, y: (tipY + 48) * s))
tip.line(to: NSPoint(x: (nx - 38) * s, y: (tipY + 48) * s))
tip.close()
rgb(0xF2EFE9).setFill()
tip.fill()
let block = pill(rect(nx - 84, tipY + 46, 168, 104), 16)
NSGradient(starting: rgb(0xF7F5F0), ending: rgb(0xD9D4CA))!.draw(in: block, angle: -90)
rgb(0xBFB9AE).setFill()
pill(rect(nx - 24, tipY + 150, 48, 78), 10).fill()
// glow at the tip, as if the filament were still warm
NSGradient(starting: rgb(0xFF8A2E, 0.55), ending: rgb(0xFF8A2E, 0))!
    .draw(fromCenter: NSPoint(x: nx * s, y: (topY + h) * s), radius: 0,
          toCenter: NSPoint(x: nx * s, y: (topY + h) * s), radius: 70 * s, options: [])

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
