import AVFoundation

/// Converts the microphone format to the format requested by SpeechAnalyzer.
/// Priming is disabled so conversion does not insert artificial latency into live buffers.
final class BufferConverter {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.inputFormat != inputFormat || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw ConversionError.failedToCreateConverter
        }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ConversionError.failedToCreateBuffer
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            defer { suppliedInput = true }
            inputStatus.pointee = suppliedInput ? .noDataNow : .haveData
            return suppliedInput ? nil : buffer
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(conversionError)
        }
        return convertedBuffer
    }
}
