import AppKit
// Mac icon: same artwork as the iPhone icon, on Apple's rounded-square template (824px tile on a 1024 canvas).
let s: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ h: Int, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: a) }
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: c(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(c(0xEE2A7B)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [c(0xF9CE34), c(0xEE2A7B), c(0x6228D7)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
ctx.restoreGState()
// Same glyph as iOS, scaled to the tile (0.805 of the full-bleed iOS artwork).
ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 0.805, y: 0.805); ctx.translateBy(x: -512, y: -512)
ctx.setStrokeColor(c(0xFFFFFF)); ctx.setFillColor(c(0xFFFFFF)); ctx.setLineWidth(70)
ctx.addPath(CGPath(roundedRect: CGRect(x: 232, y: 232, width: 560, height: 560), cornerWidth: 160, cornerHeight: 160, transform: nil)); ctx.strokePath()
ctx.addEllipse(in: CGRect(x: 407, y: 492, width: 210, height: 210)); ctx.fillPath()
ctx.move(to: CGPoint(x: 457, y: 552)); ctx.addLine(to: CGPoint(x: 567, y: 552))
ctx.addLine(to: CGPoint(x: 597, y: 372)); ctx.addLine(to: CGPoint(x: 427, y: 372)); ctx.closePath(); ctx.fillPath()
ctx.addEllipse(in: CGRect(x: 650, y: 650, width: 52, height: 52)); ctx.fillPath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
