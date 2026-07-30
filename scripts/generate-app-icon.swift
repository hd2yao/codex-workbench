import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift <output.png>\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("unable to create graphics context\n", stderr)
    exit(1)
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

let tile = NSBezierPath(
    roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
    xRadius: 220,
    yRadius: 220
)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.125, green: 0.149, blue: 0.180, alpha: 1), // #20262E
    NSColor(calibratedRed: 0.071, green: 0.086, blue: 0.110, alpha: 1), // #12161C
])!
background.draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
tile.lineWidth = 4
tile.stroke()

let center = NSPoint(x: 512, y: 500)
let ringRadius: CGFloat = 300
let accent = NSColor.systemBlue

// Four segmented white arcs, gaps aligned to the cardinal axes.
NSColor(calibratedWhite: 0.96, alpha: 0.94).setStroke()
for startAngle: CGFloat in [6, 96, 186, 276] {
    let segment = NSBezierPath()
    segment.appendArc(
        withCenter: center,
        radius: ringRadius,
        startAngle: startAngle,
        endAngle: startAngle + 78,
        clockwise: false
    )
    segment.lineCapStyle = .round
    segment.lineWidth = 62
    segment.stroke()
}

// systemBlue highlight arc across the top-right quadrant.
let highlight = NSBezierPath()
highlight.appendArc(
    withCenter: center,
    radius: ringRadius + 84,
    startAngle: 18,
    endAngle: 72,
    clockwise: false
)
highlight.lineCapStyle = .round
highlight.lineWidth = 36
accent.setStroke()
highlight.stroke()

// Four short crosshair ticks on the cardinal axes.
NSColor(calibratedWhite: 1, alpha: 0.66).setStroke()
for angle: CGFloat in [0, 90, 180, 270] {
    let radians = angle * .pi / 180
    let inner = ringRadius + 96
    let outer = ringRadius + 132
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: center.x + cos(radians) * inner,
                          y: center.y + sin(radians) * inner))
    tick.line(to: NSPoint(x: center.x + cos(radians) * outer,
                          y: center.y + sin(radians) * outer))
    tick.lineCapStyle = .round
    tick.lineWidth = 14
    tick.stroke()
}

// Blue center dot with white inner core.
let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 92, y: center.y - 92,
                                      width: 184, height: 184))
accent.setFill()
dot.fill()
let core = NSBezierPath(ovalIn: NSRect(x: center.x - 36, y: center.y - 36,
                                       width: 72, height: 72))
NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
core.fill()

image.unlockFocus()
guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("unable to encode icon\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
