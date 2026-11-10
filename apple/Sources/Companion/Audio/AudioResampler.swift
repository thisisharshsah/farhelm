import AVFoundation

/// Converts any incoming PCM buffer to 16 kHz mono Float32 (what Parakeet expects).
/// Keeps the converter alive between calls so streamed audio stays continuous.
final class AudioResampler {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: false)!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        if converter == nil || inputFormat != format {
            converter = AVAudioConverter(from: format, to: Self.targetFormat)
            inputFormat = format
        }
        guard let converter else { return [] }

        let ratio = Self.targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return [] }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
