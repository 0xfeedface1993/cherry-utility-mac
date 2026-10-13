// Renders Design/icons/DMGBackground.svg (660×400 pt) to the 1x / 2x PNGs that Scripts/release.sh puts in the DMG.
// AppKit draws SVG natively (macOS 14+), text included. Run after editing the SVG:
//   swift Scripts/render-dmg-background.swift
import AppKit

let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Design/icons")
guard let svg = NSImage(contentsOf: icons.appending(path: "DMGBackground.svg")) else { fatalError("cannot read DMGBackground.svg") }
let points = CGSize(width: 660, height: 400)

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    // sRGB, and a point size of 660×400 for both (72 / 144 dpi) so `tiffutil -cathidpicheck` pairs them.
    let output = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    output.size = points
    let url = icons.appending(path: scale == 1 ? "DMGBackground.png" : "DMGBackground@2x.png")
    try output.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
