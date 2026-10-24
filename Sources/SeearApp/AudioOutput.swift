import CoreAudio
import Foundation

struct AudioOutput {
    var id: AudioDeviceID
    var channels: Int
    static var current: AudioOutput {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,
            mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device) == noErr else {
            return AudioOutput(id:0,channels:0)
        }
        address = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,
            mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device,&address,0,nil,&size) == noErr else { return AudioOutput(id:device,channels:0) }
        let storage = UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,storage) == noErr else { return AudioOutput(id:device,channels:0) }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to:AudioBufferList.self))
        return AudioOutput(id:device,channels:buffers.reduce(0) { $0+Int($1.mNumberChannels) })
    }
}
