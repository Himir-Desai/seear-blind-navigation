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
    var began = 0.0, identities: [String:String] = [:], trackedFrames = 0
    var classifications: [String:Set<Double>] = [:]
    let smokeRotation = Rotation3D.axis(SIMD3(0,0,1),degrees:25)
        .followed(by:.axis(SIMD3(1,0,0),degrees:20)).followed(by:.heading(30))
    let moving = CommandLine.arguments.contains("--moving-sample")
    func sample() -> CGImage {
        guard moving,
              let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
                                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.setFillColor(CGColor(gray:0.2,alpha:1)); context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
        context.translateBy(x:sin(Double(count)*0.2)*12,y:cos(Double(count)*0.15)*6)
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return context.makeImage() ?? image
    }
    func submit() {
        let captured = ProcessInfo.processInfo.systemUptime
        if began == 0 { began = captured }
        worker.submit(CapturedImage(image:sample(),timestamp:captured,yaw:30,rotation:smokeRotation),feed:count % 2 == 0 ? "front" : "feet",
                      target:"cat",geometry:CameraGeometry(pitch:count % 2 == 0 ? 0 : 90),searchID:"vision-smoke",selectedTrackID:identities["front"])
    }
    worker.onStatus = { message, ok in
        if ok { print(message); submit() } else { failure = message; finished = true }
    }
    worker.onDiagnostic = { fputs($0,stderr) }
    worker.onScene = { frame in
        let now = ProcessInfo.processInfo.systemUptime
        guard frame.objects.allSatisfy(\.valid), frame.coverage > 0.99,
              let rotation = frame.rotation, rotation.difference(from:smokeRotation) < 0.001,
              let stats = frame.perception, stats.classifierError.isEmpty else {
            failure = "Real model scene/attitude/tracker validation failed"; finished = true; return
        }
        if let classified = stats.classified { classifications[frame.feed,default:[]].insert(classified) }
        if let identity = identities[frame.feed], frame.feed == "front" {
            guard frame.objects.contains(where: { $0.trackID == identity }) else {
                failure = "Sample lost selected identity on \(frame.feed), gap \(frame.captured-(frames[frame.feed] ?? frame.captured)) s, IDs \(frame.objects.compactMap(\.trackID))"; finished = true; return
            }
        } else if let first = frame.objects.max(by: { $0.confidence < $1.confidence }), let identity = first.trackID {
            identities[frame.feed] = identity
        }
        if !frame.objects.isEmpty { trackedFrames += 1 }
        if frame.feed == "feet", !(frame.wearerFilter?.valid ?? false) {
            failure = "Footwear filtering metadata missing"; finished = true; return
        }
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        frames[frame.feed] = frame.captured
        if frames.count == 2 { maxPairAge = max(maxPairAge,now-(frames.values.min() ?? now)) }
        times.append(frame.inferenceMS)
        print(String(format:"PASS live %@ · %.0f ms · %@ · %d tracked items",frame.feed,frame.inferenceMS,stats.mode,frame.objects.count))
        count += 1
        if now-began >= (moving ? 20 : 6), count >= (moving ? 64 : 24) {
            finished = true
            if identities.count != 2 || trackedFrames < 12 || classifications.values.filter({ $0.count>=2 }).count != 2 {
                failure = "Background classification and persistent tracking did not complete on both feeds"
            } else if mapping && mapUpdates == 0 { failure = "Optional mapping did not return a snapshot" }
        } else { submit() }
    }
    worker.onMap = { snapshot in mapUpdates += 1; print("PASS optional mapping response: \(snapshot.status)") }
    worker.onMapError = { message in failure = message; finished = true }
    try worker.start(root:root,mapping:mapping,mapDirectory:root.appendingPathComponent("build/mapping-smoke-"+UUID().uuidString))
    defer { worker.stop() }
    let deadline = Date().addingTimeInterval(90)
    while !finished && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
    if let failure { throw NSError(domain:failure,code:1) }
    guard finished else { throw NSError(domain:"Vision smoke timeout",code:1) }
    print(String(format:"Mean live-path inference %.0f ms; maximum pair age at replies %.3f seconds",times.reduce(0,+)/Double(times.count),maxPairAge))
    guard maxPairAge < 1.5 else { throw NSError(domain:"Two-feed reply cadence exceeds the 1.5-second scene deadline",code:1) }
}

func audioCheck() throws {
    func render(bearing: Double, yaw: Double, rotation: Rotation3D? = nil, elevation: Double = 0, distance: Double = 0.15, itemDistance: Double? = nil, two: Bool = false, muted: Bool = false, hazard: Bool = true, long: Bool = false, flicker: Bool = false) throws -> ([Float],[Float]) {
        let audio = SpatialAudio()
        try audio.start(offline:true)
        defer { audio.stop() }
        let observation = Observation(label:"test",confidence:1,bearing:bearing,elevation:elevation,distance:distance)
        // Hazard has no FOV amplitude gate, making the rotated/static comparison exact.
        let cue = Cue(observation,yaw:0,hazard:true)
        var itemObservation = observation; itemObservation.distance = itemDistance ?? distance
        let item = Cue(itemObservation,yaw:0)
        let state = Guidance(target:two || !hazard ? item : nil,obstacle:hazard || two ? cue : nil,status:"SYNTHETIC AUDIO CHECK",fault:false)
        audio.update(state,pose:HeadPose(rotation:rotation ?? .heading(yaw),yaw:yaw))
        let buffer = AVAudioPCMBuffer(pcmFormat:audio.stereo,frameCapacity:4096)!
        var left: [Float] = [], right: [Float] = []
        for index in 0..<(long ? 40 : 14) {
            if muted && index == 4 { audio.mute() }
            if flicker {
                if index % 2 == 1 { audio.mute() }
                else { audio.update(state,pose:HeadPose(rotation:rotation ?? .heading(yaw),yaw:yaw)) }
            }
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
    for (pitch,roll) in [(35.0,40.0),(90.0,0.0),(-90.0,70.0),(130.0,180.0)] {
        let attitude = Rotation3D.axis(SIMD3(0,0,1),degrees:roll)
            .followed(by:.axis(SIMD3(1,0,0),degrees:pitch)).followed(by:.heading(55))
        let source = SIMD3(sin(60 * Double.pi/180),tan(20 * Double.pi/180),-cos(60 * Double.pi/180))
        let relative = attitude.inverse.applied(to:source)
        let bearing = atan2(relative.x,-relative.z)*180 / .pi
        let elevation = atan2(relative.y,hypot(relative.x,relative.z))*180 / .pi
        for hazard in [true,false] {
            let actual = try render(bearing:60,yaw:55,rotation:attitude,elevation:20,hazard:hazard)
            // Rolloff is disabled, so only normalized direction matters to HRTF.
            let expected = try render(bearing:bearing,yaw:0,elevation:elevation,hazard:hazard)
            let error = zip(actual.0+actual.1,expected.0+expected.1).reduce(0.0) { $0+Double(($1.0-$1.1)*($1.0-$1.1)) } / Double(actual.0.count*2)
            try require(error < 1e-8 && (actual.0+actual.1).allSatisfy(\.isFinite),"Full attitude \(hazard ? "hazard" : "item") HRTF agrees with head-relative source at pitch \(pitch)°, roll \(roll)°")
        }
    }
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
    let hazardBursts = countBursts(hazardMono)
    let expectedHazardBursts = Double(hazardMono.count)/48000*ObstacleSound.rate(0.15)*2
    try require(abs(Double(hazardBursts)-expectedHazardBursts)<=2,"Emergency cue retains two distinct short taps per cycle (\(hazardBursts) bursts)")
    let flicker = try render(bearing:0,yaw:0,distance:0.35,long:true,flicker:true)
    try require(countBursts(mono(flicker)) <= 2 && energy(mono(flicker))>1e-12,"Flickering obstacle detections cannot repeatedly retrigger soft warnings")
    let far = try render(bearing:0,yaw:0,distance:1,long:true)
    let quiet = try render(bearing:0,yaw:0,distance:0.35,long:true)
    let guidance = try render(bearing:0,yaw:0,distance:2,hazard:false,long:true)
    let mixQuiet = try render(bearing:0,yaw:0,distance:0.35,itemDistance:2,two:true,long:true)
    try require(energy(far.0)+energy(far.1)<1e-12,"Obstacle audio is silent beyond 0.50 m")
    try require(energy(mono(quiet)) < energy(mono(guidance))*0.04,"Soft obstacle warning stays at least 14 dB below a 2 m item cue")
    try require(energy(hazardMono) > 100*energy(mono(quiet)),"Emergency warning is over 20 dB above the sparse soft warning")
    try require(toneEnergy(mono(mixQuiet),frequency:440)>10*toneEnergy(mono(mixQuiet),frequency:1200),"A soft warning leaves the item cue dominant in the actual mix")
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
