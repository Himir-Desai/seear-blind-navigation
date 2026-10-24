import AVFoundation
import AppKit
import SeearCore

struct CameraGeometry {
    var hfov = 70.0
    var pitch = 0.0
    var height = 1.6
    var scale = 1.0
    var dictionary: [String: Double] { ["hfov": hfov, "pitch": pitch, "height": height, "scale": scale] }
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "seear.camera", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame = 0.0
    var onFrame: ((CGImage, Double) -> Void)?
    var onError: ((String) -> Void)?
    static var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }
    func start(device: AVCaptureDevice) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .medium
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw CameraError.unavailable }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else { throw CameraError.unavailable }
                self.session.addOutput(output)
                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.1, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        lastFrame = now
        // Preserve the sample's presentation clock, rather than giving a delayed
        // driver buffer a new timestamp when it reaches our callback.
        guard let clock = session.synchronizationClock else { return }
        let converted = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from:clock, to:CMClockGetHostTimeClock())
        let captured = CMTimeGetSeconds(converted)
        guard captured.isFinite, captured <= now+0.02 else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, 640 / image.extent.width)
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(resized, from: resized.extent) else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(cg, captured) }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
    enum CameraError: LocalizedError { case unavailable; var errorDescription: String? { "Camera cannot be opened. Check its connection and macOS Camera permission." } }
}

struct CapturedImage {
    var image: CGImage
    var timestamp: Double
    var yaw: Double
    var rotation: Rotation3D
    init(image: CGImage, timestamp: Double, yaw: Double, rotation: Rotation3D? = nil) {
        self.image = image; self.timestamp = timestamp; self.yaw = yaw; self.rotation = rotation ?? .heading(yaw)
    }
    var tilt: Rotation3D { rotation.followed(by:.heading(-yaw)) }
}
