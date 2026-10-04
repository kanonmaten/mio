import AVFoundation
import Foundation

/// Converts the microphone format to the private transcription API format.
/// Priming is disabled so conversion does not insert artificial latency into live buffers.
final class BufferConverter {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func reset() { converter = nil }

    func transcriptionPCM(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: true) else {
            throw ConversionError.failedToCreateConverter
        }
        return try pcm(convert(buffer, to: format))
    }

    /// Signal end-of-stream only at a real epoch boundary, preserving the converter's short tail.
    func finishTranscriptionPCM() throws -> Data {
        guard let converter else { return Data() }
        defer { reset() }
        var bytes = Data()
        for _ in 0..<16 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096) else {
                throw ConversionError.failedToCreateBuffer
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream; return nil
            }
            guard status != .error else { throw ConversionError.conversionFailed(error) }
            bytes.append(try pcm(buffer))
            if status == .endOfStream || buffer.frameLength == 0 { return bytes }
        }
        throw ConversionError.conversionFailed(nil)
    }

    private func pcm(_ buffer: AVAudioPCMBuffer) throws -> Data {
        guard let channel = buffer.int16ChannelData else { throw ConversionError.failedToCreateBuffer }
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
    }

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
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
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
