import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// App packaging: scale generated artwork onto the macOS icon grid and clip the tile.
// The transparent inset avoids square corners and keeps Finder and Dock sizes consistent.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
for stem in ["AppIcon", "AppIcon-dark"] {
    let source = directory.appendingPathComponent(stem + "-source.png")
    guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法读取生成的图标素材：\(source.lastPathComponent)")
    }
    let tile = CGRect(x: 80, y: 80, width: 864, height: 864)
    context.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 192, cornerHeight: 192, transform: nil))
    context.clip(); context.interpolationQuality = .high; context.draw(image, in: tile)
    let output = directory.appendingPathComponent(stem + ".png")
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("无法生成圆角图标")
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("无法保存图标") }
    print("已适配圆角与透明边缘：\(stem).png")
}
