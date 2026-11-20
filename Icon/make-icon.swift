// Draws the app icon, a white house on a warm squircle, and writes it as
// .icns, plus a 1024 px PNG next to it.
//
//   swift Icon/make-icon.swift Icon/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"

func rgb(_ hex: UInt32) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func drawSymbol(_ name: String, in rect: CGRect, color: NSColor, ctx: CGContext) {
  let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
    .applying(.init(paletteColors: [color]))
  guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
  else { return }
  let scale = min(rect.width / image.size.width, rect.height / image.size.height)
  let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                        height: size.height))
  NSGraphicsContext.restoreGraphicsState()
}

/// The 1024 pt master, on Apple's icon grid: an 824 pt squircle with room
/// for its shadow.
func drawIcon(_ ctx: CGContext) {
  let canvas = CGRect(x: 100, y: 100, width: 824, height: 824)
  let squircle = CGPath(roundedRect: canvas, cornerWidth: 185, cornerHeight: 185, transform: nil)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
  ctx.addPath(squircle)
  ctx.setFillColor(rgb(0xE65100))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(squircle)
  ctx.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [rgb(0xFFCA28), rgb(0xFB8C00), rgb(0xE65100)] as CFArray,
                            locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
  ctx.restoreGState()

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.3))
  drawSymbol("house.fill", in: CGRect(x: 232, y: 262, width: 560, height: 480), color: .white, ctx: ctx)
  ctx.restoreGState()
}

func png(size: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  let ctx = context.cgContext
  ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  ctx.interpolationQuality = .high
  drawIcon(ctx)
  context.flushGraphics()
  return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try! iconutil.run()
iconutil.waitUntilExit()
try! png(size: 1024).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
print("wrote \(output)")
