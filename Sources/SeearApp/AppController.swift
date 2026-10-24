import AppKit
import AVFoundation
import SeearCore

final class AppController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mapWindow: NSWindow?
    private let mapView = RoomMapView()
    private let mapEnabled = NSButton(checkboxWithTitle:"Build room memory",target:nil,action:nil)
    private let guidance = GuidanceEngine(), tracker = HeadTracker(), voice = VoiceInput()
    private let speaker = AVSpeechSynthesizer()
    private var audio: SpatialAudio?, worker: VisionWorker?
    private var cameras: [Camera] = [], devices: [AVCaptureDevice] = []
    private var images: [String: CapturedImage] = [:]
    private var cameraGeometry: [String: CameraGeometry] = [:]
    private var running = false, nextFeed = "front", visionOK = false
    private var referenceGeneration = 0
    private var timer: Timer?, lastAnnouncement = "", lastSpoken = 0.0
    private var started = 0.0
    private var previouslyFaulted = true
    private var outputRoute = AudioOutput.current
    private let status = NSTextField(labelWithString: "Ready to configure"), tracking = NSTextField(labelWithString: ""),
                visionStatus = NSTextField(labelWithString: "Local vision off"), voiceStatus = NSTextField(labelWithString: "Voice off"),
                detail = NSTextField(labelWithString: ""), frontSelect = NSPopUpButton(), feetSelect = NSPopUpButton(),
                startButton = NSButton(title: "Start backend", target: nil, action: nil),
                target = NSTextField(string: "backpack"), frontPreview = CameraPreview(), feetPreview = CameraPreview()
    private let itemMinimum = NSTextField(string:"0.50"), itemSwitchMargin = NSTextField(string:"0.10")
    private var geometryFields: [[NSTextField]] = []
    private var settings: [NSControl] = []
    private var root: URL {
        let path = Bundle.main.object(forInfoDictionaryKey: "SeearProjectRoot") as? String ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        if CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--ui-preview") || CommandLine.arguments.contains("--ui-map-smoke") || CommandLine.arguments.contains("--ui-map-preview") || CommandLine.arguments.contains("--ui-item-preview") || CommandLine.arguments.contains("--ui-item-smoke") {
            status.stringValue = "UI verification · synthetic preview"
            if CommandLine.arguments.contains("--ui-map-smoke") || CommandLine.arguments.contains("--ui-map-preview") {
                if let data = try? Data(contentsOf:root.appendingPathComponent("build/map-ui-fixture.json")),
                   let fixture = try? JSONDecoder().decode(RoomMapSnapshot.self,from:data), fixture.valid {
                    mapView.snapshot = fixture
                } else { mapView.error = "Missing synthetic mapping UI fixture" }
                showRoomMap()
            }
            if CommandLine.arguments.contains("--ui-item-preview") || CommandLine.arguments.contains("--ui-item-smoke") {
                let image = NSImage(contentsOf:root.appendingPathComponent("build/inference-sample.png"))
                frontPreview.image = image?.cgImage(forProposedRect:nil,context:nil,hints:nil)
                feetPreview.image = frontPreview.image
                let now = ProcessInfo.processInfo.systemUptime
                guidance.search("cat")
                let best = Observation(label:"cat",confidence:0.65,bearing:-15,distance:2,box:[0.1,0.1,0.5,0.85])
                let other = Observation(label:"cat",confidence:0.55,bearing:15,distance:2,box:[0.5,0.1,0.95,0.85])
                guidance.ingest(SceneFrame(feed:"front",captured:now,yaw:0,target:"cat",objects:[other,best],obstacles:[]))
                guidance.ingest(SceneFrame(feed:"feet",captured:now,yaw:0,target:"cat",objects:[other],obstacles:[]))
                _ = guidance.evaluate(now:now,yaw:0,tracking:true)
                var current = best; current.confidence = 0.60
                var challenger = other; challenger.confidence = 0.75
                guidance.ingest(SceneFrame(feed:"front",captured:now+0.1,yaw:0,target:"cat",objects:[current,challenger],obstacles:[]))
                _ = guidance.evaluate(now:now+0.1,yaw:0,tracking:true); updateItemPreview()
                detail.stringValue = "Synthetic QA · switched one item from 0.60 to 0.75 · min 0.50, margin 0.10"
            }
            if CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--ui-map-smoke") || CommandLine.arguments.contains("--ui-item-smoke") {
                DispatchQueue.main.asyncAfter(deadline: .now()+0.6) { self.captureUI(); NSApp.terminate(nil) }
            }
            return
        }
        tracker.start()
        voice.onStatus = { [weak self] in self?.voiceStatus.stringValue = $0 }
        voice.onUnavailable = { [weak self] reason in self?.announce("Voice commands unavailable. \(reason)",force:true) }
        voice.onCommand = { [weak self] in self?.command($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(cameraDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func text(_ value: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSTextField {
        let v = NSTextField(wrappingLabelWithString: value); v.font = .systemFont(ofSize: size, weight: weight); return v
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    private func row(_ views: [NSView]) -> NSStackView { let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = 10; s.alignment = .centerY; return s }
    private func buildUI() {
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:1040,height:850), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.title = "Seear · Demo 1"; window.minSize = NSSize(width: 940, height: 820); window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor,constant:-24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor,constant:20)])
        stack.addArrangedSubview(text("Seear",size:32,weight:.bold))
        stack.addArrangedSubview(text("Backend setup and debugging · Wearer controls by voice",size:16,weight:.medium))
        stack.addArrangedSubview(text("Supervised RGB experiment. Distances are estimates. Keep using your cane and a sighted guide. Silence never means a clear path.",size:14))
        refreshDevices()
        settings = [frontSelect,feetSelect]
        let refresh = button("Refresh cameras",#selector(refreshCameras)); settings.append(refresh)
        frontSelect.setAccessibilityLabel("Front camera"); feetSelect.setAccessibilityLabel("Feet camera")
        stack.addArrangedSubview(row([text("Front"),frontSelect,text("Feet"),feetSelect,refresh]))
        let previews = row([frontPreview, feetPreview]); previews.distribution = .fillEqually
        stack.addArrangedSubview(previews)
        previews.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        previews.heightAnchor.constraint(equalToConstant:215).isActive = true
        frontPreview.setAccessibilityLabel("Front camera preview"); feetPreview.setAccessibilityLabel("Feet camera preview")
        stack.addArrangedSubview(text("Camera geometry — enter measured FOV, downward mount angle, cap height and depth scale before starting",size:13,weight:.semibold))
        for (i, name) in ["Front", "Feet"].enumerated() {
            let defaults = [70.0, i == 0 ? 0.0 : 90.0, 1.6, 1.0]
            let labels = ["FOV °", "Down °", "Height m", "Scale"]
            var views: [NSView] = [text(name)]
            let fields = zip(defaults,labels).map { value, label -> NSTextField in
                let f = NSTextField(string:String(format:"%.2f",value)); f.widthAnchor.constraint(equalToConstant:64).isActive = true
                f.setAccessibilityLabel("\(name) \(label)"); views += [text(label,size:12),f]; settings.append(f); return f
            }
            geometryFields.append(fields); stack.addArrangedSubview(row(views))
        }
        stack.addArrangedSubview(tracking)
        startButton.target = self; startButton.action = #selector(toggle); startButton.bezelStyle = .rounded
        mapEnabled.state = .on; settings.append(mapEnabled)
        stack.addArrangedSubview(row([startButton,button("Retry voice",#selector(enableVoice)),button("Disable voice (debug)",#selector(disableVoice)),mapEnabled,button("Room map (debug)",#selector(showRoomMap))]))
        target.widthAnchor.constraint(equalToConstant:240).isActive = true; target.setAccessibilityLabel("Item to find")
        for field in [itemMinimum,itemSwitchMargin] { field.widthAnchor.constraint(equalToConstant:48).isActive = true; settings.append(field) }
        itemMinimum.setAccessibilityLabel("Item minimum confidence x")
        itemSwitchMargin.setAccessibilityLabel("Item switching margin y")
        itemMinimum.toolTip = "Only show or sound an item with a model score strictly above x."
        itemSwitchMargin.toolTip = "Switch only when the best candidate exceeds the current item's score by more than y."
        stack.addArrangedSubview(row([text("Find an item"),target,button("Find",#selector(find)),button("Cancel search",#selector(cancelSearch)),text("Min x",size:12),itemMinimum,text("Switch +y",size:12),itemSwitchMargin]))
        stack.addArrangedSubview(text("Voice starts with the backend. Say “Hey Seear, where is my backpack”, “pause guidance”, or “resume guidance”. “Hey Seear, stop” cancels search. Forward follows the cap as you turn.",size:13))
        status.font = .systemFont(ofSize:20,weight:.semibold); status.setAccessibilityLabel("Guidance status")
        stack.addArrangedSubview(status); stack.addArrangedSubview(detail)
        stack.addArrangedSubview(row([visionStatus,voiceStatus]))
        stack.addArrangedSubview(text("Setup: wear AirPods and select stereo output. Choose a microphone that can hear the wearer. Check left/right audio before use. No heading calibration or turn reset is required; large pitch changes still pause guidance.",size:12))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let menu = NSMenu(), item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle:"Quit Seear",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); item.submenu = appMenu; NSApp.mainMenu = menu
    }
    private func refreshDevices() {
        devices = Camera.devices
        frontSelect.removeAllItems(); feetSelect.removeAllItems()
        let names = devices.enumerated().map { "\($0.offset+1). \($0.element.localizedName)" }
        frontSelect.addItems(withTitles:names); feetSelect.addItems(withTitles:names)
        if devices.count > 1 { feetSelect.selectItem(at:1) }
    }
    @objc private func refreshCameras() { refreshDevices() }
    @objc private func showRoomMap() {
        if mapWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.title = "Seear · Room memory (debug)"; window.minSize = NSSize(width:780,height:560)
            window.isReleasedWhenClosed = false; window.contentView = mapView; window.center(); mapWindow = window
        }
        mapWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func enableVoice() { voice.start() }
    @objc private func disableVoice() { voice.stop() }
    @objc private func find() { command(.find(target.stringValue)) }
    @objc private func cancelSearch() { command(.cancel) }
    private func command(_ command: VoiceCommand) {
        switch command {
        case .find(let value):
            let value = VoiceCommand.canonicalTarget(value)
            guard !value.isEmpty, value.count <= 64 else { announce("Enter an item name up to 64 characters",force:true); return }
            target.stringValue = value; guidance.search(value); audio?.mute()
            announce(guidance.isPaused ? "Will search for \(value) when guidance resumes" : "Searching for \(value)",force:true)
        case .cancel:
            guidance.search(""); audio?.mute()
            announce(!running ? "Search cancelled. Backend is stopped." : guidance.isPaused ? "Search cancelled. Guidance remains paused." : "Search cancelled. Obstacle monitoring remains active.",force:true)
        case .pauseGuidance:
            guidance.pause(); audio?.mute()
            announce("Guidance paused. Say Hey Seear, resume guidance to continue.",force:true)
        case .resumeGuidance:
            if !running { toggle(); return }
            guidance.resume(); previouslyFaulted = true
            announce("Resuming guidance. Waiting for fresh camera views.",force:true)
        }
    }
    @objc private func toggle() {
        if running { stop(); return }
        guard devices.indices.contains(frontSelect.indexOfSelectedItem), devices.indices.contains(feetSelect.indexOfSelectedItem),
              frontSelect.indexOfSelectedItem != feetSelect.indexOfSelectedItem else { announce("Choose two different connected cameras",force:true); return }
        guard let minimum = Double(itemMinimum.stringValue), minimum >= 0.15,
              let margin = Double(itemSwitchMargin.stringValue),
              let policy = ItemConfidencePolicy(minimum:minimum,switchMargin:margin) else {
            announce("Set item minimum x from 0.15 to below 1, margin y at least zero, and x plus y below 1.",force:true); return
        }
        guidance.itemConfidencePolicy = policy
        for (i,feed) in ["front","feet"].enumerated() {
            let v = geometryFields[i].map { Double($0.stringValue) ?? .nan }
            guard v.allSatisfy(\.isFinite), (20...140).contains(v[0]), (-30...90).contains(v[1]), (0.5...2.5).contains(v[2]), (0.1...5).contains(v[3]) else {
                announce("Check camera geometry values",force:true); return
            }
            cameraGeometry[feed] = CameraGeometry(hfov:v[0],pitch:v[1],height:v[2],scale:v[3])
        }
        AVCaptureDevice.requestAccess(for:.video) { allowed in
            DispatchQueue.main.async {
                guard allowed else { self.announce("Camera permission denied. Enable Seear in System Settings.",force:true); return }
                if !self.running { self.start() }
            }
        }
    }
    private func start() {
        do {
            outputRoute = AudioOutput.current
            guard outputRoute.channels >= 2 else {
                announce("Select stereo AirPods output in macOS Sound settings first",force:true); return
            }
            tracker.beginSession()
            let audio = SpatialAudio(); try audio.start(); self.audio = audio
            guidance.resume(); images.removeAll(); visionOK = false; started = ProcessInfo.processInfo.systemUptime
            running = true; previouslyFaulted = true; startButton.title = "Stop backend"; settings.forEach { $0.isEnabled = false }
            let worker = VisionWorker(); self.worker = worker
            mapView.snapshot = nil
            mapView.error = mapEnabled.state == .on ? nil : "Room memory disabled. Live alerts continue without a map."
            worker.onMap = { [weak self] snapshot in self?.mapView.snapshot = snapshot }
            worker.onMapError = { [weak self] message in self?.mapView.error = message }
            worker.onScene = { [weak self] frame in
                guard let self, self.running, frame.captured >= self.tracker.referenceStarted else { return }
                self.guidance.ingest(frame)
                if frame.feed == "feet", let filter = frame.wearerFilter, filter.valid {
                    self.visionStatus.stringValue = "Local vision · feet: \(filter.shoes) shoe candidates, \(filter.excludedPixels) pixels excluded"
                }
                self.visionOK = true
            }
            worker.onStatus = { [weak self] message, ok in
                guard let self else { return }; self.visionStatus.stringValue = message; self.visionOK = ok
                if !ok { self.guidance.reset(); self.audio?.mute(); self.announce("Vision unavailable. Guidance paused.") }
            }
            worker.onDiagnostic = { [weak self] message in self?.logDiagnostic(message) }
            visionStatus.stringValue = "Loading local models…"
            try worker.start(root:root,mapping:mapEnabled.state == .on)
            for (feed,index) in [("front",frontSelect.indexOfSelectedItem),("feet",feetSelect.indexOfSelectedItem)] {
                let camera = Camera()
                camera.onFrame = { [weak self] image, stamp in
                    guard let self, self.running else { return }
                    (feed == "front" ? self.frontPreview : self.feetPreview).image = image
                    guard let captureYaw = self.tracker.yaw(at:stamp) else { self.images.removeValue(forKey:feed); return }
                    self.images[feed] = CapturedImage(image:image,timestamp:stamp,yaw:captureYaw)
                }
                camera.onError = { [weak self] message in self?.stop(); self?.announce(message,force:true) }
                cameras.append(camera); camera.start(device:devices[index])
            }
            voice.start()
        } catch { stop(); announce(error.localizedDescription,force:true) }
    }
    private func stop() {
        running = false; cameras.forEach { $0.onFrame = nil; $0.onError = nil; $0.stop() }; cameras.removeAll()
        worker?.stop(); worker = nil; audio?.stop(); audio = nil; guidance.reset(); images.removeAll()
        startButton.title = "Start backend"; settings.forEach { $0.isEnabled = true }; status.stringValue = "Backend stopped"
        visionStatus.stringValue = "Local vision off"; detail.stringValue = ""
        frontPreview.observations = []; feetPreview.observations = []
    }
    private func tick() {
        tracking.stringValue = tracker.instruction
        if referenceGeneration != tracker.generation {
            referenceGeneration = tracker.generation
            guidance.reset(); images.removeAll(); audio?.mute()
            frontPreview.observations = []; feetPreview.observations = []
        }
        guard running else { return }
        if guidance.isPaused {
            updateItemPreview()
            audio?.mute(); status.stringValue = "Guidance paused"
            detail.stringValue = "Say Hey Seear, resume guidance"; return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let route = AudioOutput.current
        if route.id != outputRoute.id || route.channels < 2 {
            stop(); announce("Audio output changed. Restore AirPods output, then say Hey Seear, resume guidance.",force:true); return
        }
        let poseOK = tracker.usable && abs(tracker.pitchOffset) < 12
        if worker?.ready == true, worker?.busy == false, poseOK {
            if let image = images[nextFeed], now-image.timestamp < 0.4, let geometry = cameraGeometry[nextFeed] {
                worker?.submit(image,feed:nextFeed,target:guidance.target,geometry:geometry)
                nextFeed = nextFeed == "front" ? "feet" : "front"
            }
        }
        var state = guidance.evaluate(now:now,yaw:tracker.yaw,tracking:poseOK)
        if !visionOK { state = Guidance(target:nil,obstacle:nil,status:"Loading or waiting for local vision. Guidance paused.",fault:true) }
        if tracker.usable && abs(tracker.pitchOffset) >= 12 {
            state = Guidance(target:nil,obstacle:nil,status:"Head tilted. Return to the starting head pitch.",fault:true)
        }
        updateItemPreview()
        audio?.update(state,yaw:tracker.yaw); status.stringValue = state.status
        if let obstacle = state.obstacle { detail.stringValue = String(format:"%@ · obstacle ~%.1f m horizontally · %.0f° relative to head",obstacle.feed == "feet" ? "Feet camera" : "Front camera",obstacle.distance,Geometry.relative(obstacle.bearing,yaw:tracker.yaw)) }
        else if let item = state.target { detail.stringValue = String(format:"%@ ~%.1f m · %.0f° relative to head · estimated",guidance.target,item.distance,Geometry.relative(item.bearing,yaw:tracker.yaw)) }
        else if !guidance.target.isEmpty && !state.fault {
            detail.stringValue = String(format:"No current item match above %.2f",guidance.itemConfidencePolicy.minimum)
        } else { detail.stringValue = "No current directional cue" }
        if state.fault && now-started > 4 { announce(state.status) }
        else if !state.fault && previouslyFaulted { announce("Guidance active") }
        else if !guidance.target.isEmpty && state.target == nil && state.obstacle == nil && !state.fault {
            announce(guidance.needsItemReselection ? "Item tracking reset. Say Hey Seear, find \(guidance.target) to select again." : "Target not currently located. Continue scanning.")
        }
        previouslyFaulted = state.fault
    }
    private func updateItemPreview() {
        let selected = guidance.selectedItem
        let front = selected?.feed == "front" ? [selected!.observation] : []
        let feet = selected?.feed == "feet" ? [selected!.observation] : []
        if frontPreview.observations != front { frontPreview.observations = front }
        if feetPreview.observations != feet { feetPreview.observations = feet }
    }
    private func announce(_ message: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || (message != lastAnnouncement && now-lastSpoken > 5) else { return }
        lastAnnouncement = message; lastSpoken = now
        if force { status.stringValue = message; speaker.stopSpeaking(at:.immediate) }
        speaker.speak(AVSpeechUtterance(string:message))
    }
    private func logDiagnostic(_ message: String) {
        let url = root.appendingPathComponent("build/vision.log")
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
        if let file = try? FileHandle(forWritingTo:url) { _ = try? file.seekToEnd(); try? file.write(contentsOf:Data(message.utf8)); try? file.close() }
    }
    @objc private func cameraDisconnected() {
        DispatchQueue.main.async { if self.running { self.stop(); self.announce("Camera disconnected. Guidance stopped.",force:true) } }
    }
    private func captureUI() {
        let mapping = CommandLine.arguments.contains("--ui-map-smoke")
        guard let view = mapping ? mapWindow?.contentView : window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:rep)
        if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:root.appendingPathComponent(mapping ? "build/map-ui-smoke.png" : CommandLine.arguments.contains("--ui-item-smoke") ? "build/item-ui-smoke.png" : "build/ui-smoke.png")) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stop(); timer?.invalidate(); tracker.stop(); voice.stop() }
}
