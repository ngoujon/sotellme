import AVFoundation
import AudioToolbox

/// Captures microphone audio and downsamples it to 16kHz mono Float32,
/// the format expected by Whisper.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let samplesLock = NSLock()
    private var samples: [Float] = []
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    var onLevel: ((Float) -> Void)?

    /// CoreAudio device UID to record from. `nil` means "use the system's
    /// current default input device". Applied on the next `start()`.
    var preferredDeviceUID: String?

    func start() throws {
        samplesLock.lock()
        samples.removeAll()
        samplesLock.unlock()
        let input = engine.inputNode
        applyPreferredDeviceIfNeeded(to: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
    }

    private func process(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return }

        guard let channelData = outputBuffer.floatChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        let pointer = channelData[0]
        var peak: Float = 0
        samplesLock.lock()
        samples.reserveCapacity(samples.count + frameLength)
        for i in 0..<frameLength {
            let v = pointer[i]
            samples.append(v)
            peak = max(peak, abs(v))
        }
        samplesLock.unlock()
        onLevel?(peak)
    }

    /// A non-destructive snapshot of the audio captured so far, for live
    /// (in-progress) transcription while still recording.
    func currentSamples() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples
    }

    private func applyPreferredDeviceIfNeeded(to input: AVAudioInputNode) {
        guard let uid = preferredDeviceUID, let deviceID = MicrophoneManager.deviceID(forUID: uid) else { return }
        guard let audioUnit = input.audioUnit else {
            NSLog("SoTellMe: no audio unit available to select preferred microphone")
            return
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("SoTellMe: failed to select preferred microphone (status \(status)), using system default")
        }
    }
}

enum AudioRecorderError: Error {
    case converterCreationFailed
}
