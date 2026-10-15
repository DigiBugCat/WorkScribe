import AppKit
// Ask macOS for an app bundle's icon, as Finder and notifications draw it.
// swiftc -O probe.swift -o probe && ./probe /path/To.app /tmp/out   (writes out-512.png ... out-32.png)
let path = CommandLine.arguments[1], out = CommandLine.arguments[2]
let img = NSWorkspace.shared.icon(forFile: path)
for px in [512, 128, 64, 32] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)-\(px).png"))
}
print("ok")
