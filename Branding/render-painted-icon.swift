import AppKit
import Foundation

let source = URL(fileURLWithPath: "Branding/source/kiln-painted-original.png")
let destination = URL(fileURLWithPath: "Branding/export/kiln-icon-1024.png")
guard let image = NSImage(contentsOf: source),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot prepare icon") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186).addClip()
image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try data.write(to: destination, options: .atomic)
