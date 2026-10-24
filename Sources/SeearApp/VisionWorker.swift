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
    var onMap: ((RoomMapSnapshot) -> Void)?
    var onMapError: ((String) -> Void)?
    var generation = UUID().uuidString
    func start(root: URL, mapping: Bool = true, mapDirectory: URL? = nil) throws {
        let python = root.appendingPathComponent(".venv/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "Run scripts/setup-vision.sh first", code: 1)
        }
        process.executableURL = python
        process.arguments = ["-u", root.appendingPathComponent("vision/worker.py").path]
        if !mapping { process.arguments?.append("--no-mapping") }
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        if let mapDirectory { env["SEEAR_MAPS"] = mapDirectory.path }
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
                } else if type == "map", let snapshot = object["map"] {
                    // Optional mapping cannot invalidate a good live guidance scene.
                    if let data = try? JSONSerialization.data(withJSONObject:snapshot),
                       let decoded = try? JSONDecoder().decode(RoomMapSnapshot.self,from:data), decoded.valid {
                        DispatchQueue.main.async { self.onMap?(decoded) }
                    } else { DispatchQueue.main.async { self.onMapError?("Invalid optional map update; live alerts continue") } }
                } else if type == "map_error" {
                    DispatchQueue.main.async { self.onMapError?(object["message"] as? String ?? "Room memory unavailable") }
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
                    "target": target, "geometry": geometry.dictionary, "tilt": frame.tilt.matrix,
                    "rotation": ["x":frame.rotation.x,"y":frame.rotation.y,"z":frame.rotation.z,"w":frame.rotation.w],
                    "jpeg": jpeg.base64EncodedString()]
                var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
                try self.input.fileHandleForWriting.write(contentsOf: data)
            } catch { DispatchQueue.main.async { self.busy = false; self.onStatus?(error.localizedDescription, false) } }
        }
    }
    func stop() {
        onScene = nil; onStatus = nil; onDiagnostic = nil; onMap = nil; onMapError = nil
        // Keep draining pipes during graceful EOF/checkpoint; callbacks are cleared.
        try? input.fileHandleForWriting.close()
        // EOF lets the mapper checkpoint after the last live inference. Do not
        // block the main/audio thread if a backend does not exit promptly.
        let child = process
        if child.isRunning { DispatchQueue.global().asyncAfter(deadline:.now()+3) { if child.isRunning { child.terminate() } } }
        ready = false
    }
    deinit { stop() }
}
