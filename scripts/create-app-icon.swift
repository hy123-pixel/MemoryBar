import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()

let bounds = NSRect(x: 28, y: 28, width: 968, height: 968)
let background = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.40, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.37, blue: 0.48, alpha: 1)
])!.draw(in: background, angle: 315)

let border = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
NSColor.white.withAlphaComponent(0.18).setStroke()
border.lineWidth = 5
border.stroke()

let chipRect = NSRect(x: 272, y: 285, width: 480, height: 454)
let chip = NSBezierPath(roundedRect: chipRect, xRadius: 92, yRadius: 92)
NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.91, blue: 0.85, alpha: 1),
    NSColor(calibratedRed: 0.17, green: 0.67, blue: 0.81, alpha: 1)
])!.draw(in: chip, angle: 135)

let chipOutline = NSBezierPath(roundedRect: chipRect.insetBy(dx: 2, dy: 2), xRadius: 90, yRadius: 90)
NSColor.white.withAlphaComponent(0.72).setStroke()
chipOutline.lineWidth = 8
chipOutline.stroke()

let pinsColor = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.91, alpha: 1)
pinsColor.setFill()
for x in [366.0, 485.0, 604.0] {
    NSBezierPath(roundedRect: NSRect(x: x, y: 205, width: 54, height: 105), xRadius: 25, yRadius: 25).fill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 714, width: 54, height: 105), xRadius: 25, yRadius: 25).fill()
}
for y in [365.0, 485.0, 605.0] {
    NSBezierPath(roundedRect: NSRect(x: 192, y: y, width: 105, height: 54), xRadius: 25, yRadius: 25).fill()
    NSBezierPath(roundedRect: NSRect(x: 727, y: y, width: 105, height: 54), xRadius: 25, yRadius: 25).fill()
}

let screen = NSBezierPath(roundedRect: NSRect(x: 346, y: 366, width: 332, height: 292), xRadius: 48, yRadius: 48)
NSColor(calibratedRed: 0.07, green: 0.20, blue: 0.34, alpha: 1).setFill()
screen.fill()

let barColors = [
    NSColor(calibratedRed: 0.31, green: 0.79, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.35, green: 0.91, blue: 0.81, alpha: 1),
    NSColor(calibratedRed: 0.62, green: 0.96, blue: 0.66, alpha: 1)
]
let barHeights: [CGFloat] = [100, 166, 222]
for index in 0..<3 {
    let x = CGFloat(394 + index * 82)
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 414, width: 54, height: barHeights[index]), xRadius: 24, yRadius: 24)
    barColors[index].setFill()
    bar.fill()
}

let baseline = NSBezierPath()
baseline.move(to: NSPoint(x: 388, y: 406))
baseline.line(to: NSPoint(x: 636, y: 406))
NSColor.white.withAlphaComponent(0.32).setStroke()
baseline.lineWidth = 8
baseline.lineCapStyle = .round
baseline.stroke()

image.unlockFocus()
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL)
