import OpusC

public enum OpusApplication {
    case voIP, audio, restrictedLowDelay
    var raw: Int32 {
        switch self {
        case .voIP: return Int32(OPUS_APPLICATION_VOIP)
        case .audio: return Int32(OPUS_APPLICATION_AUDIO)
        case .restrictedLowDelay: return Int32(OPUS_APPLICATION_RESTRICTED_LOWDELAY)
        }
    }
}

public final class OpusEncoder {
    private let handle: UnsafeMutableRawPointer?
    public let sampleRate: Int
    public let channels: Int
    public let frameSize: Int // samples per channel

    public init?(sampleRate: Int, channels: Int, application: OpusApplication, bitrate: Int, frameMs: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameSize = sampleRate * frameMs / 1000
        var err: Int32 = 0
        guard let h = opus_enc_create(Int32(sampleRate), Int32(channels), application.raw, &err), err == 0 else {
            return nil
        }
        handle = h
        _ = opus_enc_set_bitrate(h, Int32(bitrate))
    }

    public func encode(_ pcm: [Int16]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 4000)
        let n = opus_enc_encode(handle, pcm, Int32(frameSize), &out, Int32(out.count))
        if n < 0 { return nil }
        return Array(out[0..<Int(n)])
    }

    deinit { opus_enc_destroy(handle) }
}

public final class OpusDecoder {
    private let handle: UnsafeMutableRawPointer?
    public let sampleRate: Int
    public let channels: Int
    public let frameSize: Int // samples per channel

    public init?(sampleRate: Int, channels: Int, frameMs: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameSize = sampleRate * frameMs / 1000
        var err: Int32 = 0
        guard let h = opus_dec_create(Int32(sampleRate), Int32(channels), &err), err == 0 else {
            return nil
        }
        handle = h
    }

    public func decode(_ data: [UInt8]) -> [Int16]? {
        var pcm = [Int16](repeating: 0, count: frameSize * channels)
        let n = opus_dec_decode(handle, data, Int32(data.count), &pcm, Int32(frameSize), 0)
        if n < 0 { return nil }
        return Array(pcm[0..<Int(n) * channels])
    }

    public func decodePLC() -> [Int16]? {
        var pcm = [Int16](repeating: 0, count: frameSize * channels)
        let n = opus_dec_decode_plc(handle, &pcm, Int32(frameSize))
        if n < 0 { return nil }
        return Array(pcm[0..<Int(n) * channels])
    }

    deinit { opus_dec_destroy(handle) }
}
