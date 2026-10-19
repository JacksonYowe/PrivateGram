import AppKit
let s: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ h: Int) -> CGColor { CGColor(srgbRed: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: 1) }
// Diagonal warm gradient, bottom-left gold → top-right violet.
let g = CGGradient(colorsSpace: cs, colors: [c(0xF9CE34), c(0xEE2A7B), c(0x6228D7)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])
ctx.setStrokeColor(c(0xFFFFFF)); ctx.setFillColor(c(0xFFFFFF))
// Camera body outline
let lw: CGFloat = 70
ctx.setLineWidth(lw)
let body = CGRect(x: 232, y: 232, width: 560, height: 560)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 160, cornerHeight: 160, transform: nil)); ctx.strokePath()
// Lens drawn as a keyhole (privacy) instead of a circle
ctx.addEllipse(in: CGRect(x: 512-105, y: 512-20, width: 210, height: 210)); ctx.fillPath()
ctx.move(to: CGPoint(x: 512-55, y: 512+40)); ctx.addLine(to: CGPoint(x: 512+55, y: 512+40))
ctx.addLine(to: CGPoint(x: 512+85, y: 512-140)); ctx.addLine(to: CGPoint(x: 512-85, y: 512-140)); ctx.closePath(); ctx.fillPath()
// Flash dot
ctx.addEllipse(in: CGRect(x: 650, y: 650, width: 52, height: 52)); ctx.fillPath()
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
