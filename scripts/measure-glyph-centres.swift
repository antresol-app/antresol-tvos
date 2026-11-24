// Where does an SF Symbol's ink sit in a round button? Draws each symbol the way `CircleButtonStyle` does
// (semibold, centred in a square frame) and prints, in em, how far the middle of the ink's box and the ink's centre
// of mass lie from the frame's centre. `GlyphOptics.table` (AntresolTV/Design/RoundGlyph.swift) moves a symbol by
// minus the mean of the two, where that is 0.02 em or more.
//
//     swiftc -O scripts/measure-glyph-centres.swift -o /tmp/measure-glyph-centres
//     /tmp/measure-glyph-centres chevron.right star.fill captions.bubble
//
// Runs on the Mac (SwiftUI's ImageRenderer); the symbols are the same on tvOS.
import AppKit
import SwiftUI

@MainActor
func measure(_ name: String, size: CGFloat = 100) -> (box: CGPoint, mass: CGPoint, width: CGFloat, height: CGFloat)? {
    let frame: CGFloat = 400
    let renderer = ImageRenderer(content: Image(systemName: name)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(width: frame, height: frame))
    renderer.scale = 1
    guard let image = renderer.cgImage else { return nil }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var minX = w, maxX = -1, minY = h, maxY = -1
    var weight = 0.0, sumX = 0.0, sumY = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let alpha = Double(pixels[(y * w + x) * 4 + 3]) / 255
            if alpha > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            weight += alpha
            sumX += alpha * (Double(x) + 0.5)
            sumY += alpha * (Double(y) + 0.5)
        }
    }
    guard weight > 0 else { return nil }
    let centreX = Double(w) / 2, centreY = Double(h) / 2, em = Double(size)
    // Rows run downwards: +y is down, as in SwiftUI.
    let box = CGPoint(x: (Double(minX + maxX + 1) / 2 - centreX) / em, y: (Double(minY + maxY + 1) / 2 - centreY) / em)
    let mass = CGPoint(x: (sumX / weight - centreX) / em, y: (sumY / weight - centreY) / em)
    return (box, mass, CGFloat(maxX - minX + 1) / size, CGFloat(maxY - minY + 1) / size)
}

MainActor.assumeIsolated {
    print("symbol, box.x, box.y, mass.x, mass.y, move.x, move.y, width, height   (em; +x right, +y down)")
    for name in CommandLine.arguments.dropFirst() {
        guard let m = measure(name) else {
            print("\(name): no ink")
            continue
        }
        func move(_ box: CGFloat, _ mass: CGFloat) -> CGFloat { abs(box + mass) / 2 >= 0.02 ? -(box + mass) / 2 : 0 }
        print(String(format: "%@, %.3f, %.3f, %.3f, %.3f, %.3f, %.3f, %.2f, %.2f", name, m.box.x, m.box.y, m.mass.x, m.mass.y,
                     move(m.box.x, m.mass.x), move(m.box.y, m.mass.y), m.width, m.height))
    }
}
