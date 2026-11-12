// Renders the Maben Base app icon: swift Resources/make-icon.swift <out.png>
// A Maben product icon: the Gate mark in black on Base pink (#FF5CA8),
// on Apple's Mac icon grid (824pt body, 100pt margin). Mark width is 62% of
// the body and the corner radius 22.5%, as in the Maben brand guidelines.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius = body.width * 0.225
ctx.setFillColor(CGColor(srgbRed: 0xFF / 255, green: 0x5C / 255, blue: 0xA8 / 255, alpha: 1))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.fillPath()

// The Gate mark, in the units of brand/logo/maben-mark-black.svg (viewBox 16 22 68 58, y down).
let mark = CGMutablePath()
mark.move(to: CGPoint(x: 16, y: 80))
mark.addLine(to: CGPoint(x: 16, y: 46))
mark.addQuadCurve(to: CGPoint(x: 40, y: 22), control: CGPoint(x: 16, y: 22))
mark.addLine(to: CGPoint(x: 60, y: 22))
mark.addQuadCurve(to: CGPoint(x: 84, y: 46), control: CGPoint(x: 84, y: 22))
mark.addLine(to: CGPoint(x: 84, y: 80))
for centre in [CGFloat(64), 36] {            // the two arched openings, right then left
    mark.addLine(to: CGPoint(x: centre + 8, y: 80))
    mark.addLine(to: CGPoint(x: centre + 8, y: 50))
    mark.addArc(center: CGPoint(x: centre, y: 50), radius: 8, startAngle: 0, endAngle: .pi, clockwise: true)
    mark.addLine(to: CGPoint(x: centre - 8, y: 80))
}
mark.closeSubpath()

let scale = body.width * 0.62 / 68
ctx.translateBy(x: body.midX - 34 * scale, y: body.midY + 29 * scale)
ctx.scaleBy(x: scale, y: -scale)
ctx.translateBy(x: -16, y: -22)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.addPath(mark)
ctx.fillPath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
