import AppKit
import CoreGraphics
let width = 1024
let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(red: 0.02, green: 0.28, blue: 0.49, alpha: 1), CGColor(red: 0.12, green: 0.64, blue: 0.82, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0,1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512,y: 0), end: CGPoint(x: 512,y: 1024), options: [])
context.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.46, alpha: 1))
context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: CGColor(red: 0.01,green: 0.15,blue: 0.25,alpha: 0.17))
context.fillEllipse(in: CGRect(x: 333, y: 333, width: 358, height: 358))
context.setShadow(offset: .zero, blur: 0, color: nil)
context.setStrokeColor(CGColor(red: 1, green: 0.90, blue: 0.58, alpha: 1)); context.setLineWidth(36); context.setLineCap(.round)
for ray in 0..<8 {
    let angle = Double(ray) * .pi / 4
    context.move(to: CGPoint(x: 512 + cos(angle) * 259, y: 512 + sin(angle) * 259))
    context.addLine(to: CGPoint(x: 512 + cos(angle) * 327, y: 512 + sin(angle) * 327)); context.strokePath()
}
let image = context.makeImage()!
let bitmap = NSBitmapImageRep(cgImage: image)
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
