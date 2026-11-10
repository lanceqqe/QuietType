import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.05, green: 0.33, blue: 0.35, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
let configuration = NSImage.SymbolConfiguration(pointSize: 480, weight: .medium)
if let symbol = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()
    let ratio = 560 / tinted.size.width
    let height = tinted.size.height * ratio
    tinted.draw(in: NSRect(x: 232, y: (1024-height)/2, width: 560, height: height))
}
image.unlockFocus()
if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
   let png = bitmap.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
