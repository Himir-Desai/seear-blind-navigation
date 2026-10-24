import AppKit
import Foundation
import AVFoundation
import SeearCore
import ImageIO

func visionCheck() throws {
    let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
    let imageURL = root.appendingPathComponent("build/inference-sample.png")
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL,nil),
          let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
        throw NSError(domain:"Supply the public two-cat sample at build/inference-sample.png (see docs/VALIDATION.md)",code:1)
    }
    let worker = VisionWorker()
    var count = 0, finished = false, failure: String?, times: [Double] = [], frames: [String:Double] = [:], maxPairAge = 0.0
    func submit() {
        let captured = ProcessInfo.processInfo.systemUptime
        worker.submit(CapturedImage(image:image,timestamp:captured,yaw:30),feed:count % 2 == 0 ? "front" : "feet",
                      target:"cat",geometry:CameraGeometry())
    }
    worker.onStatus = { message, ok in
        if ok { print(message); submit() } else { failure = message; finished = true }
    }
    worker.onDiagnostic = { fputs($0,stderr) }
    worker.onScene = { frame in
        let now = ProcessInfo.processInfo.systemUptime
        guard frame.objects.contains(where: { $0.label == "cat" }), frame.objects.allSatisfy(\.valid), frame.coverage > 0.99 else {
            failure = "Real model scene/box/depth validation failed"; finished = true; return
        }
        // Measure the oldest scene just BEFORE replacement as well as after it;
        // reporting only post-reply ages hides the end-of-cycle worst case.
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        frames[frame.feed] = frame.captured
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        times.append(frame.inferenceMS)
        print(String(format:"PASS Swift → cached models → Swift: %@ · %.0f ms · %d cats",frame.feed,frame.inferenceMS,frame.objects.count))
        count += 1
        if count == 8 { finished = true } else { submit() }
    }
    try worker.start(root:root)
    defer { worker.stop() }
    let deadline = Date().addingTimeInterval(90)
    while !finished && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    if let failure { throw NSError(domain:failure,code:1) }
    guard finished else { throw NSError(domain:"Vision smoke timeout",code:1) }
    print(String(format:"Mean inference %.0f ms; maximum pair age at replies %.3f seconds",times.reduce(0,+)/Double(times.count),maxPairAge))
    guard maxPairAge < 1.5 else { throw NSError(domain:"Two-feed reply cadence exceeds the 1.5-second scene deadline",code:1) }
}

func audioCheck() throws {
    func render(bearing: Double, yaw: Double, two: Bool = false, muted: Bool = false) throws -> ([Float],[Float]) {
        let audio = SpatialAudio()
        try audio.start(offline:true)
        defer { audio.stop() }
        let observation = Observation(label:"test",confidence:1,bearing:bearing,distance:1)
        // Hazard has no FOV amplitude gate, making the rotated/static comparison exact.
        let cue = Cue(observation,yaw:0,hazard:true)
        let state = Guidance(target:two ? cue : nil,obstacle:cue,status:"SYNTHETIC AUDIO CHECK",fault:false)
        audio.update(state,yaw:yaw)
        let buffer = AVAudioPCMBuffer(pcmFormat:audio.stereo,frameCapacity:4096)!
        var left: [Float] = [], right: [Float] = []
        for index in 0..<14 {
            if muted && index == 4 { audio.mute() }
            let status = try audio.engine.renderOffline(4096,to:buffer)
            guard status == .success else { throw NSError(domain:"Offline render failed: \(status.rawValue)",code:1) }
            if index >= 10 {
                left += Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
                right += Array(UnsafeBufferPointer(start:buffer.floatChannelData![1],count:Int(buffer.frameLength)))
            }
        }
        return (left,right)
    }
    func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0+Double($1*$1) } / Double(samples.count) }
    func require(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain:message,code:1) }; print("PASS \(message)") }
    let left = try render(bearing:-60,yaw:0), right = try render(bearing:60,yaw:0)
    try require(energy(left.0) > energy(left.1),"Left hazard lateralizes left through the actual HRTF graph")
    try require(energy(right.1) > energy(right.0),"Right hazard lateralizes right through the actual HRTF graph")
    // Cross-correlation distinguishes a delayed HRTF signal from plain volume panning.
    var best = -Double.infinity, bestLag = 0
    for lag in -48...48 {
        var corr = 0.0
        for i in 48..<(right.0.count-48) { corr += Double(right.0[i])*Double(right.1[i+lag]) }
        if corr > best { best = corr; bestLag = lag }
    }
    try require(abs(bestLag) >= 4,"HRTF has interaural delay (\(bestLag) samples), beyond stereo panning")
    let rotated = try render(bearing:60,yaw:90), expected = try render(bearing:-30,yaw:0)
    let difference = zip(rotated.0,expected.0).map { Double(($0-$1)*($0-$1)) }.reduce(0,+) / Double(rotated.0.count)
    try require(difference < 1e-8,"Head yaw rotates the perceived direction once with the correct sign")
    let mix = try render(bearing:0,yaw:0,two:true)
    try require((mix.0+mix.1).allSatisfy { $0.isFinite && abs($0) < 1 },"Two simultaneous voices remain finite and unclipped")
    let muted = try render(bearing:0,yaw:0,muted:true)
    try require(energy(muted.0)+energy(muted.1) < 1e-10,"Fault mute removes both directional voices")
}

if CommandLine.arguments.contains("--audio-check") {
    do { try audioCheck(); exit(0) } catch { fputs("FAIL \(error.localizedDescription)\n",stderr); exit(1) }
}
if CommandLine.arguments.contains("--vision-check") {
    do { try visionCheck(); exit(0) } catch { fputs("FAIL \(error.localizedDescription)\n",stderr); exit(1) }
}
let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
