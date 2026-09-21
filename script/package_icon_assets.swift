import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Package fallbacks only. Xcode 26 compiles FFFilm/AppIcon.icon directly;
// iOS raster fallbacks must remain square and opaque for system masking.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift package_icon_assets.swift /path/to/FFFilm")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = root.appendingPathComponent("FFFilm/Assets.xcassets/AppIcon.appiconset")
let source = root.appendingPathComponent("design/icon/source/time-slices-grayscale-1024.png")
let macMaster = root.appendingPathComponent("design/icon/exports/macOS-Default.png")

func export(_ input: URL, to output: URL, size: Int, alpha: Bool, gray: Bool = false) throws {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
    let alphaInfo: CGImageAlphaInfo = gray ? .none : (alpha ? .premultipliedLast : .noneSkipLast)
    // Core Graphics supports opaque RGB in a padded 32-bit buffer and writes
    // the resulting PNG without an alpha channel; a 24-bit drawing context does not.
    guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
          let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: alphaInfo.rawValue) else {
        fatalError("Unable to prepare \(output.lastPathComponent)")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Unable to encode \(output.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Unable to write \(output.lastPathComponent)")
    }
}

// Read existing slot mappings, preserving filenames and platform declarations.
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("Contents.json"))) as! [String: Any]
let slots = manifest["images"] as! [[String: Any]]
for slot in slots {
    let filename = slot["filename"] as! String
    let output = assets.appendingPathComponent(filename)
    if slot["idiom"] as? String == "mac" {
        let points = Int((slot["size"] as! String).split(separator: "x")[0])!
        let scale = Int((slot["scale"] as! String).dropLast())!
        // The native master already includes macOS margins and shadow.
        try export(macMaster, to: output, size: points * scale, alpha: true)
    } else {
        let appearances = slot["appearances"] as? [[String: String]] ?? []
        let tinted = appearances.contains { $0["value"] == "tinted" }
        // The approved artwork already has a dark field. Preserve it in both
        // normal/dark fallbacks; provide neutral luminance for system tinting.
        try export(source, to: output, size: 1024, alpha: false, gray: tinted)
    }
}
print("Updated \(slots.count) AppIcon raster slots")
