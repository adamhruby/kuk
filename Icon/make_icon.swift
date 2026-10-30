// Draws the Kuk app icon: an eye outline with a lightning bolt for the iris.
// Usage: swift Icon/make_icon.swift out.png [size]
import AppKit

let out = CommandLine.arguments[1]
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let S = CGFloat(size) / 1024

let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

// Monochrome: black squircle, solid white eye, lightning bolt cut out in black.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(color(0x000000))
ctx.fillPath()

// Eye: two arcs meeting at sharp corners.
let cx: CGFloat = 512, cy: CGFloat = 512
let halfW: CGFloat = 340, bulge: CGFloat = 420   // quad control offset; peak = bulge / 2
let eye = CGMutablePath()
eye.move(to: CGPoint(x: cx - halfW, y: cy))
eye.addQuadCurve(to: CGPoint(x: cx + halfW, y: cy), control: CGPoint(x: cx, y: cy + bulge))
eye.addQuadCurve(to: CGPoint(x: cx - halfW, y: cy), control: CGPoint(x: cx, y: cy - bulge))
eye.closeSubpath()
ctx.addPath(eye)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()

// Lightning bolt in place of the iris (unit coords, y down).
let bolt: [CGPoint] = [
    CGPoint(x: 0.60, y: 0.00), CGPoint(x: 0.12, y: 0.58), CGPoint(x: 0.44, y: 0.58),
    CGPoint(x: 0.36, y: 1.00), CGPoint(x: 0.88, y: 0.40), CGPoint(x: 0.56, y: 0.40),
]
let bh: CGFloat = 300, bw: CGFloat = 230
let boltPath = CGMutablePath()
boltPath.addLines(between: bolt.map { CGPoint(x: cx - bw / 2 + $0.x * bw, y: cy + bh / 2 - $0.y * bh) })
boltPath.closeSubpath()
ctx.addPath(boltPath)
ctx.setFillColor(color(0x000000))
ctx.fillPath()

let img = ctx.makeImage()!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, img, nil)
CGImageDestinationFinalize(dst)
