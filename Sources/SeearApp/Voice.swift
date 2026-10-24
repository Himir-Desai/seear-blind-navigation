import AVFoundation
import Speech
import SeearCore

final class VoiceInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var restart: Timer?
    private var listening = false, tapped = false, handled = false
    private var epoch = 0
    private var authorizationEpoch = 0
    var onCommand: ((VoiceCommand) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {
        authorizationEpoch += 1
        let authorization = authorizationEpoch
        guard recognizer?.supportsOnDeviceRecognition == true else {
            onStatus?("On-device English recognition is unavailable. Use the Find field."); return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard self?.authorizationEpoch == authorization else { return }
                guard status == .authorized else { self?.onStatus?("Speech permission denied"); return }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    DispatchQueue.main.async {
                        guard self?.authorizationEpoch == authorization else { return }
                        guard allowed else { self?.onStatus?("Microphone permission denied"); return }
                        self?.listening = true; self?.listen()
                    }
                }
            }
        }
    }
    private func listen() {
        guard listening else { return }
        tearDown(); epoch += 1
        let currentEpoch = epoch
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Seear", "backpack", "white cane"]
        self.request = request; handled = false
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { onStatus?("Microphone unavailable"); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapped = true
        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.listening, self.epoch == currentEpoch else { return }
                if let text = result?.bestTranscription.formattedString,
                   !self.handled, let command = VoiceCommand.parse(text), result?.isFinal == true {
                    self.handled = true; self.onCommand?(command)
                }
                if error != nil || result?.isFinal == true { self.scheduleRestart(epoch: currentEpoch) }
            }
        }
        do { try engine.start(); onStatus?("Listening locally · say Hey Seear, where is my backpack") }
        catch { onStatus?(error.localizedDescription); stop() }
        restart = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in self?.listen() }
    }
    private func scheduleRestart(epoch: Int) {
        restart?.invalidate()
        restart = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard self?.epoch == epoch else { return }; self?.listen()
        }
    }
    private func tearDown() {
        epoch += 1; restart?.invalidate(); engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil
    }
    func stop() { authorizationEpoch += 1; listening = false; tearDown(); onStatus?("Voice off") }
    deinit { stop() }
}
