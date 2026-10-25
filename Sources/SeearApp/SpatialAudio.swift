import AVFoundation
import Foundation
import os
import SeearCore

/// Adapted from P4 Hybrid 2.1. Two mono voices pass through Apple's HRTFHQ;
/// Item: inherited soft single pulse. Hazard: bright two-note double beep, no FOV mute.
final class PulseVoice {
    struct Control { var gain = 0.0; var rate = 1.0; var sharpness = 1.0; var hazard = false; var emergency = false }
    private let control = OSAllocatedUnfairLock(initialState: Control())
    private var current = Control(), gain = 0.0, rate = 1.0, phase = 0.0, tone = 0.0
    private var audioTime = 0.0, hazardStarted = 0.0, nextSoftAllowed = 0.0
    private var noise: UInt64 = 0x1234567
    lazy var node = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!) {
        [weak self] _, _, frames, list -> OSStatus in
        guard let self else { return noErr }
        if let next = self.control.withLockIfAvailable({ $0 }) {
            if next.hazard && next.gain > 0 && (self.current.gain == 0 || next.emergency != self.current.emergency) {
                self.hazardStarted = next.emergency ? self.audioTime : max(self.audioTime,self.nextSoftAllowed)
                self.rate = next.rate
            }
            self.current = next
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for frame in 0..<Int(frames) {
            self.gain += (self.current.gain - self.gain) * 0.001
            self.rate += (self.current.rate - self.rate) * 0.001
            var hazardPhase = self.audioTime-self.hazardStarted
            if self.current.hazard {
                if self.current.gain > 0 && hazardPhase >= 1/max(0.1,self.rate) {
                    self.hazardStarted = self.audioTime; hazardPhase = 0
                }
                if self.current.gain > 0 && !self.current.emergency && hazardPhase >= 0 {
                    self.nextSoftAllowed = self.hazardStarted+3
                }
            } else {
                self.phase += self.rate/48000; self.phase -= floor(self.phase)
            }
            self.audioTime += 1.0/48000
            let frequency = self.current.hazard ? (hazardPhase < 0.11 ? 1200.0 : 1800.0) : 440.0
            self.tone += frequency / 48000; self.tone -= floor(self.tone)
            self.noise ^= self.noise << 13; self.noise ^= self.noise >> 7; self.noise ^= self.noise << 17
            let white = Double(self.noise >> 11) / 9007199254740992 * 2 - 1
            let envelope: Double, carrier: Double
            if self.current.hazard {
                // Fixed-duration taps: slowing the warning rate must not turn
                // brief notes into a long, intrusive tone.
                let duration = self.current.emergency ? 0.07 : 0.045
                let local = hazardPhase < 0.11 ? hazardPhase/duration : (hazardPhase-0.11)/duration
                envelope = local >= 0 && local < 1 ? pow(sin(.pi * local),2) : 0
                let harmonic = (sin(2 * .pi * self.tone) + 0.25 * sin(4 * .pi * self.tone)) / 1.25
                carrier = 0.08 * white + 0.075 * harmonic
            } else {
                envelope = pow(0.5 + 0.5 * cos(2 * .pi * self.phase),8)
                let harmonic = (sin(2 * .pi * self.tone) + 0.35 * self.current.sharpness * sin(4 * .pi * self.tone)) / 1.35
                carrier = 0.1 * white + 0.05 * harmonic
            }
            let sample = Float(self.gain * envelope * carrier)
            for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
        }
        return noErr
    }
    func update(cue: Cue?, relativeAngle: Double) {
        control.withLock { state in
            guard let cue else { state.gain = 0; return }
            let gain = cue.hazard ? ObstacleSound.gain(cue.distance) : SoundMapping.gain(cue.distance) * SoundMapping.visibility(angle:relativeAngle,distance:cue.distance)
            state = Control(gain:gain*cue.level,
                            rate:cue.hazard ? ObstacleSound.rate(cue.distance) : SoundMapping.rate(cue.distance),
                            sharpness:cue.hazard ? 1 : SoundMapping.sharpness(relativeAngle),hazard:cue.hazard,
                            emergency:cue.hazard && cue.distance <= ObstacleSound.emergencyRange)
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
            environment.isListenerHeadTrackingEnabled = false // Full AirPods attitude is applied exactly once.
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
        update(guidance,pose:HeadPose(rotation:.heading(yaw),yaw:yaw))
    }
    func update(_ guidance: Guidance, pose: HeadPose) {
        let forward = pose.rotation.applied(to:SIMD3(0,0,-1)), up = pose.rotation.applied(to:SIMD3(0,1,0))
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward:AVAudio3DVector(x:Float(forward.x),y:Float(forward.y),z:Float(forward.z)),
            up:AVAudio3DVector(x:Float(up.x),y:Float(up.y),z:Float(up.z)))
        for (i, cue) in [guidance.target, guidance.obstacle].enumerated() {
            var relativeAngle = 0.0
            if let cue {
                let a = cue.bearing * .pi / 180
                let position = SIMD3(sin(a)*cue.distance,tan(cue.elevation * .pi/180)*cue.distance,-cos(a)*cue.distance)
                mixers[i].position = AVAudio3DPoint(x:Float(position.x),y:Float(position.y),z:Float(position.z))
                let local = pose.rotation.inverse.applied(to:position)
                relativeAngle = atan2(local.x,-local.z)*180 / .pi
            }
            voices[i].update(cue:cue,relativeAngle:relativeAngle)
        }
    }
    func mute() { for v in voices { v.update(cue: nil, relativeAngle: 0) } }
    func stop() { mute(); engine.stop() }
}
