import AppKit
import SeearCore

final class RoomMapView: NSView {
    var snapshot: RoomMapSnapshot? { didSet { error = nil; needsDisplay = true } }
    var error: String? { didSet { needsDisplay = true } }
    private var timer: Timer?
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            if self?.window?.isVisible == true { self?.needsDisplay = true }
        }
    }
    deinit { timer?.invalidate() }
    private func label(_ value: String, at point: NSPoint, size: CGFloat = 13, color: NSColor = .labelColor) {
        (value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        label("Estimated room memory · top-down · blank space is unknown",at:NSPoint(x:20,y:16),size:16)
        guard let s = snapshot else {
            label(error ?? "Waiting for front-camera mapping. Live alerts work without a map.",at:NSPoint(x:20,y:50))
            return
        }
        let fresh = s.poseIsFresh(at:ProcessInfo.processInfo.systemUptime)
        let state = ["tracking","relocalized"].contains(s.status) && !fresh ? "pose stale" : s.status.replacingOccurrences(of:"_",with:" ")
        label("\(state) · \(s.confirmed)/\(s.landmarks) landmarks · \(s.savedMaps) saved maps · \(s.keyframes) keyframes",at:NSPoint(x:20,y:44))
        label(error ?? s.detail,at:NSPoint(x:20,y:66),size:11,color:.secondaryLabelColor)
        label("Solid: repeated wall estimates   Dashed: candidate wall   Gray: observed floor   Orange: occupied surface",at:NSPoint(x:20,y:bounds.height-50),size:11)
        label("RGB estimates, partial coverage; saved geometry may have changed. No route planning or clear-path guarantee.",at:NSPoint(x:20,y:bounds.height-28),size:11,color:.secondaryLabelColor)
        let plot = NSRect(x:24,y:100,width:bounds.width-48,height:bounds.height-170)
        var xz = s.points.map { [$0[0],$0[2]] } + s.path.map { [$0[0],$0[2]] }
        xz += s.walls.flatMap { [$0.start,$0.end] }
        xz += (s.floor+s.occupied).map { [Double($0[0])*s.resolution,Double($0[1])*s.resolution] }
        if let p = s.position { xz.append([p[0],p[2]]) }
        guard !xz.isEmpty, plot.height > 0 else { return }
        let minX = (xz.map { $0[0] }.min() ?? 0) - 0.7, maxX = (xz.map { $0[0] }.max() ?? 0) + 0.7
        let minZ = (xz.map { $0[1] }.min() ?? 0) - 0.7, maxZ = (xz.map { $0[1] }.max() ?? 0) + 0.7
        let scale = min(plot.width/max(2,maxX-minX),plot.height/max(2,maxZ-minZ))
        func p(_ x: Double,_ z: Double) -> NSPoint { NSPoint(x:plot.midX+(x-(minX+maxX)/2)*scale,y:plot.midY+(z-(minZ+maxZ)/2)*scale) }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:plot).addClip()
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        if maxX-minX < 100, maxZ-minZ < 100 {
            for x in Int(floor(minX))...Int(ceil(maxX)) { grid.move(to:p(Double(x),minZ)); grid.line(to:p(Double(x),maxZ)) }
            for z in Int(floor(minZ))...Int(ceil(maxZ)) { grid.move(to:p(minX,Double(z))); grid.line(to:p(maxX,Double(z))) }
            grid.stroke()
        }
        for (cells,color) in [(s.floor,NSColor.systemGray.withAlphaComponent(0.25)),(s.occupied,NSColor.systemOrange.withAlphaComponent(0.4))] {
            color.setFill()
            for cell in cells {
                let a = p(Double(cell[0])*s.resolution,Double(cell[1])*s.resolution)
                NSRect(x:a.x,y:a.y,width:max(1,s.resolution*scale),height:max(1,s.resolution*scale)).fill()
            }
        }
        NSColor.systemTeal.withAlphaComponent(0.45).setFill()
        for point in s.points { let q = p(point[0],point[2]); NSBezierPath(ovalIn:NSRect(x:q.x-1,y:q.y-1,width:2,height:2)).fill() }
        for wall in s.walls {
            NSColor.systemGreen.setStroke(); let line = NSBezierPath(); line.lineWidth = 3
            if wall.observations < 3 { line.setLineDash([5,5],count:2,phase:0) }
            line.move(to:p(wall.start[0],wall.start[1])); line.line(to:p(wall.end[0],wall.end[1])); line.stroke()
        }
        let path = NSBezierPath(); path.lineWidth = 2; NSColor.systemBlue.setStroke()
        for (index,point) in s.path.enumerated() { if index == 0 { path.move(to:p(point[0],point[2])) } else { path.line(to:p(point[0],point[2])) } }; path.stroke()
        if fresh, let position = s.position, let heading = s.heading {
            let q = p(position[0],position[2]); NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn:NSRect(x:q.x-5,y:q.y-5,width:10,height:10)).fill()
            let facing = NSBezierPath(); facing.lineWidth = 3; facing.move(to:q)
            facing.line(to:p(position[0]+heading[0]*0.6,position[2]+heading[2]*0.6)); facing.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
