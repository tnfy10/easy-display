import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let outer = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 208, yRadius: 208)
    NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.16, alpha: 1).setFill(); outer.fill()
    let glow = NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.85, blue: 0.69, alpha: 1), ending: NSColor(calibratedRed: 0.1, green: 0.57, blue: 0.84, alpha: 1))!
    let screen = NSBezierPath(roundedRect: NSRect(x: 192, y: 330, width: 640, height: 440), xRadius: 56, yRadius: 56)
    glow.draw(in: screen, angle: -45)
    NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 220, y: 388, width: 584, height: 352), xRadius: 30, yRadius: 30).fill()
    let settings = NSBezierPath(); settings.lineWidth = 22; settings.lineCapStyle = .round
    for (y, knob) in [(CGFloat(610),CGFloat(440)),(CGFloat(510),CGFloat(600))] {
        settings.move(to: NSPoint(x: 320,y: y)); settings.line(to: NSPoint(x: 704,y: y))
        glow.interpolatedColor(atLocation: 0.3).setStroke(); settings.stroke(); settings.removeAllPoints()
        glow.interpolatedColor(atLocation: 0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: knob-30,y: y-30,width: 60,height: 60)).fill()
    }
    NSColor(calibratedRed: 0.65, green: 0.86, blue: 0.87, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 470,y: 230,width: 84,height: 105), xRadius: 12,yRadius: 12).fill()
    NSBezierPath(roundedRect: NSRect(x: 350,y: 208,width: 324,height: 32), xRadius: 16,yRadius: 16).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(name).png"))
}
