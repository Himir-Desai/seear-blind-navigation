import AVFoundation
import Foundation
import os
import SeearCore

/// Adapted from P4 Hybrid 2.1. Two mono voices pass through Apple's HRTFHQ;
/// hazard voices deliberately have no FOV mute and use a distinct higher tone.
final class PulseVoice {
    struct Control { var gain = 0.0; var rate = 1.0; var sharpness = 1.0; var hazard = false }
    private let control = OSAllocatedUnfairLock(initialState: Control())
    private var current = Control(), gain = 0.0, rate = 1.0, phase = 0.0, tone = 0.0
    private var noise: UInt64 = 0x1234567
    lazy var node = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!) {
        [weak self] _, _, frames, list -> OSStatus in
        guard let self else { return noErr }
        if let next = self.control.withLockIfAvailable({ $0 }) { self.current = next }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for frame in 0..<Int(frames) {
            self.gain += (self.current.gain - self.gain) * 0.001
            self.rate += (self.current.rate - self.rate) * 0.001
            self.phase += self.rate / 48000; self.phase -= floor(self.phase)
            self.tone += (self.current.hazard ? 880 : 440) / 48000; self.tone -= floor(self.tone)
            self.noise ^= self.noise << 13; self.noise ^= self.noise >> 7; self.noise ^= self.noise << 17
            let white = Double(self.noise >> 11) / 9007199254740992 * 2 - 1
            let envelope = pow(0.5 + 0.5 * cos(2 * .pi * self.phase), 8)
            let harmonic = (sin(2 * .pi * self.tone) + 0.35 * self.current.sharpness * sin(4 * .pi * self.tone)) / 1.35
            let sample = Float(self.gain * envelope * (0.1 * white + 0.05 * harmonic))
            for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
        }
        return noErr
    }
    func update(cue: Cue?, relativeAngle: Double) {
        control.withLock { state in
            guard let cue else { state.gain = 0; return }
            state = Control(gain: SoundMapping.gain(cue.distance) * cue.level *
                            (cue.hazard ? 1 : SoundMapping.visibility(angle: relativeAngle, distance: cue.distance)),
                            rate: cue.hazard ? min(8, SoundMapping.rate(cue.distance) * 1.4) : SoundMapping.rate(cue.distance),
                            sharpness: cue.hazard ? 1 : SoundMapping.sharpness(relativeAngle), hazard: cue.hazard)
        }
    }
}

final class SpatialAudio {
    let engine = AVAudioEngine(), environment = AVAudioEnvironmentNode()
    let voices = [PulseVoice(), PulseVoice()]
    let mixers = [AVAudioMixerNode(), AVAudioMixerNode()]
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    init() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.renderingAlgorithm = .HRTFHQ
        environment.reverbParameters.enable = false
        if #available(macOS 15.0, *) {
            environment.isListenerHeadTrackingEnabled = false // AirPods yaw is applied exactly once.
        }
        environment.distanceAttenuationParameters.rolloffFactor = 0 // Explicit P4 distance mapping.
        for i in voices.indices {
            engine.attach(voices[i].node); engine.attach(mixers[i])
            engine.connect(voices[i].node, to: mixers[i], format: mono)
            engine.connect(mixers[i], to: environment, format: mono)
            mixers[i].renderingAlgorithm = .HRTFHQ
            mixers[i].sourceMode = .pointSource
            mixers[i].pointSourceInHeadMode = .mono
            mixers[i].reverbBlend = 0
        }
    }
    func start(offline: Bool = false) throws {
        if offline { try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4096) }
        try engine.start()
        guard environment.applicableRenderingAlgorithms.contains(where: {
            $0.intValue == AVAudio3DMixingRenderingAlgorithm.HRTFHQ.rawValue
        }) else { engine.stop(); throw NSError(domain: "HRTFHQ unavailable", code: 1) }
    }
    func update(_ guidance: Guidance, yaw: Double) {
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: Float(Geometry.wrap(yaw)), pitch: 0, roll: 0)
        for (i, cue) in [guidance.target, guidance.obstacle].enumerated() {
            if let cue {
                let a = cue.bearing * .pi / 180
                mixers[i].position = AVAudio3DPoint(x: Float(sin(a) * cue.distance),
                    y: Float(tan(cue.elevation * .pi / 180) * cue.distance), z: Float(-cos(a) * cue.distance))
            }
            voices[i].update(cue: cue, relativeAngle: cue.map { Geometry.relative($0.bearing, yaw: yaw) } ?? 0)
        }
    }
    func mute() { for v in voices { v.update(cue: nil, relativeAngle: 0) } }
    func stop() { mute(); engine.stop() }
}
