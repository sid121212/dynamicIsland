import AppKit

// Compare the user-supplied Nook reference with the actual offscreen 2x render.
let args = CommandLine.arguments
guard args.count == 4, let reference = NSImage(contentsOfFile: args[1]), let updated = NSImage(contentsOfFile: args[2]) else {
    fatalError("Usage: compare-previews reference.png expanded-wallpaper@2x.png output.png")
}
let size = NSSize(width: 1160, height: 240)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2320, pixelsHigh: 480, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
("Provided Nook reference" as NSString).draw(at: NSPoint(x: 20, y: 214), withAttributes: attrs)
("Updated dashboard · 2× render" as NSString).draw(at: NSPoint(x: 600, y: 214), withAttributes: attrs)
// The supplied 738x414 image has its reference panel in the top 180 pixels.
let referenceCrop = NSRect(x: 45, y: reference.size.height - 185, width: 650, height: 185)
reference.draw(in: NSRect(x: 20, y: 44, width: 550, height: 156.5), from: referenceCrop, operation: .sourceOver, fraction: 1)
updated.draw(in: NSRect(x: 590, y: 35, width: 550, height: 165))
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print(args[3])
