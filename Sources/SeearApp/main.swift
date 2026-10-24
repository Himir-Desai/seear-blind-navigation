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
    let mapping = !CommandLine.arguments.contains("--no-mapping")
    var mapUpdates = 0
    var count = 0, finished = false, failure: String?, times: [Double] = [], frames: [String:Double] = [:], maxPairAge = 0.0
    func submit() {
        let captured = ProcessInfo.processInfo.systemUptime
        worker.submit(CapturedImage(image:image,timestamp:captured,yaw:30),feed:count % 2 == 0 ? "front" : "feet",
                      target:"cat",geometry:CameraGeometry(pitch:count % 2 == 0 ? 0 : 90))
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
        if frame.feed == "feet" {
            guard let filter = frame.wearerFilter, filter.valid else {
                failure = "Footwear filter did not run on the actual feet path"; finished = true; return
            }
            print("PASS footwear filter protocol: \(filter.status)")
        }
        // Measure the oldest scene just BEFORE replacement as well as after it;
        // reporting only post-reply ages hides the end-of-cycle worst case.
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        frames[frame.feed] = frame.captured
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        times.append(frame.inferenceMS)
        print(String(format:"PASS Swift → cached models → Swift: %@ · %.0f ms · %d cats",frame.feed,frame.inferenceMS,frame.objects.count))
        count += 1
        if count == 8 { finished = !mapping || mapUpdates > 0 } else { submit() }
    }
    worker.onMap = { snapshot in
        mapUpdates += 1; print("PASS optional mapping response: \(snapshot.status)")
        if count == 8 { finished = true }
    }
    worker.onMapError = { message in failure = message; finished = true }
    try worker.start(root:root,mapping:mapping,mapDirectory:root.appendingPathComponent("build/mapping-smoke-"+UUID().uuidString))
    defer { worker.stop() }
    let deadline = Date().addingTimeInterval(90)
    while !finished && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    if let failure { throw NSError(domain:failure,code:1) }
    guard finished else { throw NSError(domain:"Vision smoke timeout",code:1) }
    print(String(format:"Mean inference %.0f ms; maximum pair age at replies %.3f seconds",times.reduce(0,+)/Double(times.count),maxPairAge))
    guard maxPairAge < 1.5 else { throw NSError(domain:"Two-feed reply cadence exceeds the 1.5-second scene deadline",code:1) }
}

func audioCheck() throws {
    func render(bearing: Double, yaw: Double, two: Bool = false, muted: Bool = false, hazard: Bool = true, long: Bool = false) throws -> ([Float],[Float]) {
        let audio = SpatialAudio()
        try audio.start(offline:true)
        defer { audio.stop() }
        let observation = Observation(label:"test",confidence:1,bearing:bearing,distance:1)
        // Hazard has no FOV amplitude gate, making the rotated/static comparison exact.
        let cue = Cue(observation,yaw:0,hazard:true), item = Cue(observation,yaw:0)
        let state = Guidance(target:two || !hazard ? item : nil,obstacle:hazard || two ? cue : nil,status:"SYNTHETIC AUDIO CHECK",fault:false)
        audio.update(state,yaw:yaw)
        let buffer = AVAudioPCMBuffer(pcmFormat:audio.stereo,frameCapacity:4096)!
        var left: [Float] = [], right: [Float] = []
        for index in 0..<(long ? 40 : 14) {
            if muted && index == 4 { audio.mute() }
            let status = try audio.engine.renderOffline(4096,to:buffer)
            guard status == .success else { throw NSError(domain:"Offline render failed: \(status.rawValue)",code:1) }
            if index >= (long ? 8 : 10) {
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
    let item = try render(bearing:0,yaw:0,hazard:false,long:true)
    let hazard = try render(bearing:0,yaw:0,long:true)
    func toneEnergy(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i,sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(i) / 48000
            real += Double(sample)*cos(phase); imaginary += Double(sample)*sin(phase)
        }
        return (real*real+imaginary*imaginary)/pow(Double(samples.count),2)
    }
    func mono(_ stereo: ([Float],[Float])) -> [Float] { zip(stereo.0,stereo.1).map { ($0+$1)*0.5 } }
    let itemMono = mono(item), hazardMono = mono(hazard)
    try require(toneEnergy(itemMono,frequency:440) > 10*toneEnergy(itemMono,frequency:1200),"Item cue retains its 440 Hz single-pulse identity")
    try require(toneEnergy(hazardMono,frequency:1200) > 10*toneEnergy(hazardMono,frequency:440) &&
                toneEnergy(hazardMono,frequency:1800) > 10*toneEnergy(hazardMono,frequency:440),"Hazard cue has distinct 1200/1800 Hz notes through HRTF")
    func countBursts(_ samples: [Float]) -> Int {
        let size = 240 // 5 ms RMS bins, measured after the actual HRTF graph.
        var levels: [Double] = []
        for start in stride(from:0,to:samples.count-size,by:size) {
            levels.append(samples[start..<(start+size)].reduce(0) { $0+Double($1*$1) }/Double(size))
        }
        let threshold = (levels.max() ?? 0)*0.15
        var active = false, count = 0
        for level in levels { let next = level > threshold; if next && !active { count += 1 }; active = next }
        return count
    }
    let itemBursts = countBursts(itemMono), hazardBursts = countBursts(hazardMono)
    try require(hazardBursts >= itemBursts*2,"Hazard double beeps remain temporally distinct (\(hazardBursts) vs \(itemBursts) item pulses)")
    func writeExample(_ samples: ([Float],[Float]), name: String) throws {
        let url = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/"+name+".wav")
        let file = try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:48000,
            AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(samples.0.count))!
        buffer.frameLength = buffer.frameCapacity
        for (channel,values) in [samples.0,samples.1].enumerated() {
            values.withUnsafeBufferPointer { source in buffer.floatChannelData![channel].update(from:source.baseAddress!,count:values.count) }
        }
        try file.write(from:buffer)
    }
    try writeExample(item,name:"item-cue"); try writeExample(hazard,name:"obstacle-cue")
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
