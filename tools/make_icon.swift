// make_icon.swift <out.icns> — draws SimRun's app icon (a phone on a gradient squircle) and packs it with iconutil.
import AppKit
let out = CommandLine.arguments[1]
let set = NSTemporaryDirectory() + "SimRun.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px), inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
  NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1), ending: NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.95, alpha: 1))!
    .draw(in: shape, angle: -90)
  // phone outline
  let pw = r.width * 0.34, ph = r.width * 0.62
  let phone = NSRect(x: r.midX - pw / 2, y: r.midY - ph / 2, width: pw, height: ph)
  NSColor.white.setStroke()
  let body = NSBezierPath(roundedRect: phone, xRadius: pw * 0.2, yRadius: pw * 0.2); body.lineWidth = max(1, s * 0.03); body.stroke()
  NSColor.white.withAlphaComponent(0.9).setFill()
  NSBezierPath(roundedRect: NSRect(x: phone.midX - pw * 0.18, y: phone.maxY - ph * 0.1, width: pw * 0.36, height: ph * 0.04), xRadius: ph * 0.02, yRadius: ph * 0.02).fill()
  // play triangle
  let t = NSBezierPath(); let c = NSPoint(x: phone.midX + pw * 0.04, y: phone.midY), a = pw * 0.22
  t.move(to: NSPoint(x: c.x - a * 0.6, y: c.y + a)); t.line(to: NSPoint(x: c.x + a, y: c.y)); t.line(to: NSPoint(x: c.x - a * 0.6, y: c.y - a)); t.close(); t.fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
  try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit(); exit(p.terminationStatus)
