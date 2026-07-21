import AVFoundation

/// Captures microphone audio and downsamples it to 16kHz mono Float32,
/// the format expected by Whisper.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    var onLevel: ((Float) -> Void)?

    func start() throws {
        samples.removeAll()
        let input = engine.inputNode
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
        samples.reserveCapacity(samples.count + frameLength)
        for i in 0..<frameLength {
            let v = pointer[i]
            samples.append(v)
            peak = max(peak, abs(v))
        }
        onLevel?(peak)
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return samples
    }
}

enum AudioRecorderError: Error {
    case converterCreationFailed
}
