import AppKit
import SeearCore

/// Private pipes keep frames on this machine. One in-flight request means no video backlog.
final class VisionWorker {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let queue = DispatchQueue(label: "seear.inference", qos: .userInitiated)
    private var buffer = Data()
    private(set) var ready = false, busy = false
    var onScene: ((SceneFrame) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var generation = UUID().uuidString
    func start(root: URL) throws {
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "Run scripts/setup-vision.sh first", code: 1)
        }
        process.executableURL = python
        process.arguments = ["-u", root.appendingPathComponent("vision/worker.py").path]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = env
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let message = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(message) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.ready = false; self?.busy = false
                self?.onStatus?("Vision worker stopped (\(process.terminationStatus)). Check build/vision.log.", false) }
        }
        try process.run()
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 4_000_000 else { buffer.removeAll(); DispatchQueue.main.async { self.onStatus?("Vision protocol error", false) }; return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let type = object["type"] as? String
                if type == "ready" {
                    DispatchQueue.main.async { self.ready = true; self.onStatus?("Local vision ready · \(object["device"] ?? "CPU")", true) }
                } else if type == "scene", let scene = object["scene"], object["id"] as? String == generation {
                    let decoded = try JSONDecoder().decode(SceneFrame.self, from: JSONSerialization.data(withJSONObject: scene))
                    DispatchQueue.main.async { self.busy = false; self.onScene?(decoded) }
                } else if type == "error" {
                    DispatchQueue.main.async { self.busy = false; self.onStatus?(object["message"] as? String ?? "Vision error", false) }
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.onStatus?("Invalid vision response: \(error.localizedDescription)", false) } }
        }
    }
    func submit(_ frame: CapturedImage, feed: String, target: String, geometry: CameraGeometry) {
        guard ready, !busy else { return }
        busy = true
        let id = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let bitmap = NSBitmapImageRep(cgImage: frame.image)
                guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { throw NSError(domain: "JPEG encoding failed", code: 1) }
                let request: [String: Any] = ["id": id, "feed": feed, "captured": frame.timestamp, "yaw": frame.yaw,
                    "target": target, "geometry": geometry.dictionary, "jpeg": jpeg.base64EncodedString()]
                var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
                try self.input.fileHandleForWriting.write(contentsOf: data)
            } catch { DispatchQueue.main.async { self.busy = false; self.onStatus?(error.localizedDescription, false) } }
        }
    }
    func stop() {
        onScene = nil; onStatus = nil; onDiagnostic = nil
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        ready = false
    }
    deinit { stop() }
}
