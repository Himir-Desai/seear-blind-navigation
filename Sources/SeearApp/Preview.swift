import AppKit
import SeearCore

final class CameraPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var observations: [Observation] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); bounds.fill()
        guard let image else {
            ("Camera preview" as NSString).draw(at: NSPoint(x: 18, y: 20), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor]); return
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let w = min(bounds.width, bounds.height * aspect), h = w / aspect
        let rect = NSRect(x: (bounds.width - w)/2, y: (bounds.height - h)/2, width: w, height: h)
        NSImage(cgImage: image, size: .zero).draw(in: rect)
        for o in observations where o.box.count == 4 {
            let b = o.box
            let box = NSRect(x: rect.minX + b[0]*w, y: rect.minY + b[1]*h,
                             width: (b[2]-b[0])*w, height: (b[3]-b[1])*h)
            NSColor.systemMint.setStroke(); let path = NSBezierPath(rect: box); path.lineWidth = 2; path.stroke()
            let label = String(format: "%@ · ~%.1f m", o.label, o.distance)
            (label as NSString).draw(at: NSPoint(x: box.minX+4, y: max(rect.minY,box.minY-20)),
                withAttributes: [.foregroundColor: NSColor.systemMint, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        }
    }
}
