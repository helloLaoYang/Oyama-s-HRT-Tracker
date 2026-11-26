import AVFoundation
import Observation
import Speech
import SwiftUI

struct AIAssistantVoiceInput: View {
    var maximumTextLength = 500
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            VoiceInputSheet(maximumTextLength: maximumTextLength, onInsert: onInsert)
        } else {
            unavailable
        }
        #else
        unavailable
        #endif
    }

    private var unavailable: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(voiceLabel("Voice input"), systemImage: "mic.slash")
            } description: {
                Text(voiceLabel("On-device speech recognition is unavailable."))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(voiceLabel("Cancel")) { dismiss() }
                }
            }
        }
    }
}

#if compiler(>=6.4)
@available(iOS 27.0, *)
private struct VoiceInputSheet: View {
    let maximumTextLength: Int
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = VoiceInputSession()

    private var exceedsLimit: Bool { session.trimmedTranscript.count > maximumTextLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch session.phase {
                    case .idle:
                        Button {
                            session.record(locale: locale)
                        } label: {
                            Label(voiceLabel("Record"), systemImage: "mic.fill")
                        }
                        .accessibilityIdentifier("ai.voice.record")
                    case .preparing:
                        ProgressView(voiceLabel("Preparing on-device speech…"))
                    case .recording:
                        Button {
                            session.stop()
                        } label: {
                            Label(voiceLabel("Stop recording"), systemImage: "stop.fill")
                        }
                        .accessibilityIdentifier("ai.voice.stop")
                    case .finishing:
                        ProgressView(voiceLabel("Finishing transcript…"))
                    }
                    if let message = session.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                            .accessibilityIdentifier("ai.voice.status")
                    }
                }
                Section(voiceLabel("Review transcript")) {
                    TextEditor(text: $session.transcript)
                        .frame(minHeight: 140)
                        .disabled(session.phase != .idle)
                        .accessibilityLabel(voiceLabel("Review transcript"))
                        .accessibilityIdentifier("ai.voice.transcript")
                    if exceedsLimit {
                        Text(voiceLabel("Keep the transcript to \(maximumTextLength) characters or fewer."))
                            .font(.footnote)
                            .foregroundStyle(TrackerTheme.muted)
                            .accessibilityIdentifier("ai.voice.length")
                    }
                }
            }
            .navigationTitle(voiceLabel("Voice input"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(voiceLabel("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(voiceLabel("Insert")) {
                        onInsert(session.trimmedTranscript)
                        dismiss()
                    }
                    .disabled(session.phase != .idle || session.trimmedTranscript.isEmpty || exceedsLimit)
                    .accessibilityIdentifier("ai.voice.insert")
                }
            }
        }
        .task(id: session.phase == .recording) {
            guard session.phase == .recording else { return }
            do {
                try await Task.sleep(for: .seconds(30))
                session.stop()
            } catch {
                // Leaving the recording state cancels its time limit.
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { event in
            if event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue,
               session.phase == .recording {
                session.stop()
            }
        }
        .onDisappear { session.cancel() }
    }
}

@available(iOS 27.0, *)
@MainActor
@Observable
private final class VoiceInputSession {
    enum Phase {
        case idle, preparing, recording, finishing
    }

    private(set) var phase = Phase.idle
    private(set) var message: String?
    var transcript = ""

    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var finishingTask: Task<Void, Never>?
    @ObservationIgnored private var inputReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var microphone: VoiceMicrophone?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?

    var trimmedTranscript: String { transcript.trimmingCharacters(in: .whitespacesAndNewlines) }

    func record(locale: Locale) {
        guard phase == .idle else { return }
        let id = UUID()
        runID = id
        phase = .preparing
        message = nil
        let release = inputReleaseTask
        transcriptionTask = Task { [weak self] in
            await release?.value
            guard !Task.isCancelled else { return }
            await self?.transcribe(locale: locale, id: id)
        }
    }

    func stop() {
        guard phase == .recording, let microphone, let analyzer else { return }
        phase = .finishing
        let id = runID
        finishingTask = Task { [weak self] in
            await microphone.stop()
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                guard let self, self.runID == id, !Task.isCancelled else { return }
                self.message = voiceLabel("Could not finish the transcript.")
                self.cancel()
            }
        }
    }

    func cancel() {
        runID = nil
        transcriptionTask?.cancel()
        finishingTask?.cancel()
        transcriptionTask = nil
        finishingTask = nil
        phase = .idle

        let microphone = microphone
        let analyzer = analyzer
        self.microphone = nil
        self.analyzer = nil
        guard microphone != nil || analyzer != nil else { return }
        inputReleaseTask = Task {
            await microphone?.stop()
            await analyzer?.cancelAndFinishNow()
        }
    }

    private func transcribe(locale: Locale, id: UUID) async {
        defer {
            if runID == id { cancel() }
        }
        do {
            guard SpeechTranscriber.isAvailable,
                  let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw VoiceInputFailure.unavailable
            }
            try Task.checkCancellation()
            guard await AVAudioApplication.requestRecordPermission() else { throw VoiceInputFailure.microphoneDenied }
            try Task.checkCancellation()

            let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            try Task.checkCancellation()

            let microphone = VoiceMicrophone()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.microphone = microphone
            self.analyzer = analyzer
            let results = transcriber.results
            try await microphone.start(analyzer: analyzer, transcriber: transcriber)
            try Task.checkCancellation()
            phase = .recording

            var finalized = ""
            var heardSpeech = false
            for try await result in results {
                try Task.checkCancellation()
                let segment = String(result.text.characters)
                if result.isFinal { finalized += segment }
                let recognized = result.isFinal ? finalized : finalized + segment
                if !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcript = recognized
                    heardSpeech = true
                }
            }
            if !heardSpeech { message = voiceLabel("No speech was recognized.") }
        } catch {
            guard runID == id, !Task.isCancelled else { return }
            switch error {
            case VoiceInputFailure.unavailable:
                message = voiceLabel("On-device speech recognition is unavailable for this language or device.")
            case VoiceInputFailure.microphoneDenied:
                message = voiceLabel("Allow microphone access in Settings to record speech.")
            case VoiceInputFailure.microphoneUnavailable:
                message = voiceLabel("No microphone is available.")
            default:
                message = voiceLabel("Could not transcribe speech on this device.")
            }
        }
    }
}

private enum VoiceInputFailure: Error {
    case unavailable, microphoneDenied, microphoneUnavailable
}

@available(iOS 27.0, *)
private actor VoiceMicrophone {
    private var provider: CaptureInputSequenceProvider?
    private var stopped = false

    func start(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber) async throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw VoiceInputFailure.microphoneUnavailable }
        let provider = try await CaptureInputSequenceProvider.providerWithSession(from: device, compatibleWith: [transcriber])
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        self.provider = provider
        try await analyzer.start(inputSequence: provider.analyzerInputs)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        provider.captureSession.startRunning()
        guard provider.captureSession.isRunning else { throw VoiceInputFailure.microphoneUnavailable }
    }

    func stop() {
        stopped = true
        provider?.captureSession.stopRunning()
        // The analyzer input sequence ends when the capture output is released.
        provider = nil
    }
}
#endif

private func voiceLabel(_ key: String.LocalizationValue) -> String {
    label(key, table: "AIVoiceInput")
}
