import Foundation

/// Shared by every on-device TTS pipeline (Piper, VieNeu V2, VieNeu V3):
/// none of the underlying engines has a native rate-control param, and all
/// of them need to hand back the same `Data` contract `APIClient.synthesize`
/// already returns for the online voices, so the resample-for-speed step and
/// the WAV encode live here once instead of once per offline service.
enum OfflineWavEncoding {
    /// Cheap linear-interpolation resample used only for the speed slider —
    /// changes playback rate without a pitch-correct time-stretch.
    static func resample(_ pcm: [Float], rateFactor: Double) -> [Float] {
        let outCount = Int(Double(pcm.count) / rateFactor)
        guard outCount > 1 else { return pcm }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * rateFactor
            let i0 = min(Int(srcPos), pcm.count - 1)
            let i1 = min(i0 + 1, pcm.count - 1)
            let frac = Float(srcPos - Double(i0))
            out[i] = pcm[i0] * (1 - frac) + pcm[i1] * frac
        }
        return out
    }

    /// Minimal 16-bit PCM mono WAV writer — same contract
    /// AVAudioPlayer(data:) / APIClient.synthesize's online voices already
    /// return, no external dependency needed for this one-shot encode.
    static func wavData(from pcm: [Float], sampleRate: Int) -> Data {
        var samples = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count {
            let clamped = max(-1.0, min(1.0, pcm[i]))
            samples[i] = Int16(clamped * Float(Int16.max))
        }
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1)) // PCM
        data.append(littleEndian: UInt16(1)) // mono
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2)) // byte rate
        data.append(littleEndian: UInt16(2)) // block align
        data.append(littleEndian: UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataSize))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
