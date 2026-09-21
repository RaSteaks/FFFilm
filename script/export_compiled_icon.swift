import AppKit
import Foundation

// Read the icon through the compiled asset catalog so Apple's macOS mask,
// padding and shadow remain intact, including the 1024px rendition in Assets.car.
guard CommandLine.arguments.count == 3,
      let bundle = Bundle(path: CommandLine.arguments[1]),
      let icon = bundle.image(forResource: "AppIcon") else {
    fatalError("Usage: swift export_compiled_icon.swift /path/FFFilm.app /path/output.png")
}
let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon export bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
          from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Exported native AppIcon at 1024px from \(bundle.bundlePath)")
