// Renders the GTNW Chess app icon (original artwork): a Solar Drone robot eclipsing a Void ring on deep space.
import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let squircle = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
squircle.addClip()
NSGradient(colors: [NSColor(red: 0.03, green: 0.02, blue: 0.08, alpha: 1), NSColor(red: 0.16, green: 0.06, blue: 0.30, alpha: 1)])!
    .draw(in: rect, angle: 70)
// checker floor in perspective
for r in 0..<6 { for f in 0..<8 where (r + f) % 2 == 0 {
    let y0 = 120 + Double(r) * 38, y1 = y0 + 38
    let w0 = 820 - Double(r) * 70, w1 = 820 - Double(r + 1) * 70
    let x0 = 512 - w0 / 2 + Double(f) * w0 / 8, x1 = 512 - w1 / 2 + Double(f) * w1 / 8
    let p = NSBezierPath(); p.move(to: NSPoint(x: x0, y: y0)); p.line(to: NSPoint(x: x0 + w0 / 8, y: y0))
    p.line(to: NSPoint(x: x1 + w1 / 8, y: y1)); p.line(to: NSPoint(x: x1, y: y1)); p.close()
    NSColor(red: 0.55, green: 0.5, blue: 1, alpha: 0.18 - Double(r) * 0.025).setFill(); p.fill()
} }
// stars
var seed: UInt32 = 7
func rnd() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed >> 8) / Double(1 << 24) }
for _ in 0..<90 { let x = 110 + rnd() * 800, y = 420 + rnd() * 500, r = 1.5 + rnd() * 3
    NSColor(white: 1, alpha: 0.4 + rnd() * 0.6).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill() }
// Void eclipse ring
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: NSColor(red: 0.3, green: 0.9, blue: 1, alpha: 0.9).cgColor)
let ring = NSBezierPath(ovalIn: NSRect(x: 262, y: 360, width: 500, height: 500)); ring.lineWidth = 34
NSColor(red: 0.35, green: 0.85, blue: 1, alpha: 1).setStroke(); ring.stroke()
ctx.restoreGState()
NSColor(red: 0.04, green: 0.02, blue: 0.1, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 290, y: 388, width: 444, height: 444)).fill()
// Solar Drone: thruster, orb, eye, antenna
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: NSColor(red: 1, green: 0.7, blue: 0.2, alpha: 0.9).cgColor)
let cone = NSBezierPath(); cone.move(to: NSPoint(x: 452, y: 330)); cone.line(to: NSPoint(x: 572, y: 330)); cone.line(to: NSPoint(x: 540, y: 250)); cone.line(to: NSPoint(x: 484, y: 250)); cone.close()
NSColor(red: 0.85, green: 0.6, blue: 0.2, alpha: 1).setFill(); cone.fill()
let flame = NSBezierPath(ovalIn: NSRect(x: 470, y: 190, width: 84, height: 70)); NSColor(red: 1, green: 0.75, blue: 0.25, alpha: 0.9).setFill(); flame.fill()
NSGradient(colors: [NSColor(red: 1, green: 0.95, blue: 0.8, alpha: 1), NSColor(red: 0.96, green: 0.78, blue: 0.4, alpha: 1), NSColor(red: 0.7, green: 0.45, blue: 0.12, alpha: 1)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 362, y: 320, width: 300, height: 300)), relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
ctx.restoreGState()
let belt = NSBezierPath(ovalIn: NSRect(x: 362, y: 440, width: 300, height: 56)); belt.lineWidth = 12
NSColor(red: 0.7, green: 0.45, blue: 0.12, alpha: 1).setStroke(); belt.stroke()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: NSColor(red: 0.3, green: 0.95, blue: 1, alpha: 1).cgColor)
NSColor(red: 0.12, green: 0.08, blue: 0.2, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 452, y: 470, width: 120, height: 120)).fill()
NSColor(red: 0.4, green: 0.95, blue: 1, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 477, y: 495, width: 70, height: 70)).fill()
NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 492, y: 528, width: 22, height: 22)).fill()
ctx.restoreGState()
let ant = NSBezierPath(); ant.move(to: NSPoint(x: 560, y: 610)); ant.line(to: NSPoint(x: 600, y: 700)); ant.lineWidth = 10
NSColor(red: 0.85, green: 0.6, blue: 0.2, alpha: 1).setStroke(); ant.stroke()
ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 30, color: NSColor.orange.cgColor)
NSColor(red: 1, green: 0.5, blue: 0.1, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 584, y: 690, width: 34, height: 34)).fill()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
