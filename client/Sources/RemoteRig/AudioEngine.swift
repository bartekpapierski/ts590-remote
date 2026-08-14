import AVFoundation
import AudioToolbox
import OpusWrapper

// DownlinkStats is a snapshot of the client's downlink jitter buffer, surfaced
// to the UI so the operator can see the audio path adapting to the network.
struct DownlinkStats {
    var depth: Int
    var dropouts: Int
    var skips: Int
    var late: Int
    var fill: Int
}

final class AudioEngine {
    var onUplink: ((Data) -> Void)?
    var onStats: ((DownlinkStats) -> Void)?
    var pttActive = false

    private let inputDevice: AudioDeviceID?
    private let outputDevice: AudioDeviceID?

    private var engine: AVAudioEngine?
    private var encoder: OpusEncoder?
    private var decoder: OpusDecoder?
    private var params: OpusParams?
    private var started = false

    private let queueLock = NSLock()
    private var downlinkQueue = [Int16]()
    private var micResidue = [Int16]()

    private var uplinkSeq: UInt16 = 0
    private var downlinkExpected: UInt16 = 0

    // Downlink jitter handling. The buffer pre-buffers `downlinkDepth` frames
    // once at start, then plays through in real time: an underrun is concealed
    // with a single PLC frame instead of pausing to re-buffer. This keeps a
    // dropout a short blip regardless of how long the stream runs — growing a
    // target depth and pausing to refill just adds latency (and longer pauses)
    // without fixing the underlying clock drift.
    private static let downlinkDepth = 5
    private var downlinkStarted = false
    private var downlinkDropouts = 0
    private var downlinkSkips = 0
    private var downlinkLate = 0
    private var statsFrames = 0

    init(inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }

    func configure(params: OpusParams) {
        guard !started else { return }
        self.params = params
        encoder = OpusEncoder(
            sampleRate: params.sampleRate, channels: params.channels,
            application: .audio, bitrate: params.bitrate, frameMs: params.frameMs)
        decoder = OpusDecoder(
            sampleRate: params.sampleRate, channels: params.channels, frameMs: params.frameMs)
        startEngine()
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        self.engine = engine

        // Selecting a non-default device changes the host's default I/O device.
        if let id = inputDevice { AudioDevices.setDefaultInput(id) }
        if let id = outputDevice { AudioDevices.setDefaultOutput(id) }

        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        // Fallback hardware format for the source node when Opus format
        // construction fails (should never happen for standard rates).
        let defFmt = engine.outputNode.outputFormat(forBus: 0)
        let p = params

        // Create the source node at the Opus sample rate so AVAudioEngine
        // inserts a sample-rate converter when the hardware rate differs.
        // Without this the render callback reads frameCount samples at the
        // Opus rate but writes them at the hardware rate, causing a pitch
        // shift and cyclical underruns that sound metallic.
        let opusRate = Double(p?.sampleRate ?? 48000)
        let opusCh = AVAudioChannelCount(p?.channels ?? 1)
        let opusFmt = AVAudioFormat(
            standardFormatWithSampleRate: opusRate, channels: opusCh)
            ?? defFmt

        let source = AVAudioSourceNode(format: opusFmt) { [weak self] (_, _, frameCount, bufferList) -> OSStatus in
            self?.renderOutput(bufferList, frameCount: Int(frameCount))
            return 0
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: opusFmt)

        let frameSamples = ((p?.sampleRate ?? 48000) * (p?.frameMs ?? 20) / 1000) * (p?.channels ?? 1)
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(frameSamples), format: inFmt) { [weak self] buffer, _ in
            self?.captureInput(buffer)
        }

        do {
            try engine.start()
            started = true
        } catch {
            print("audio engine start failed: \(error)")
        }
    }

    private func captureInput(_ buffer: AVAudioPCMBuffer) {
        guard pttActive, let enc = encoder, let p = params else { return }
        let frameSamples = ((p.sampleRate * p.frameMs / 1000) * p.channels)
        micResidue.append(contentsOf: bufferToInt16(buffer, channels: p.channels))
        while micResidue.count >= frameSamples {
            let frame = Array(micResidue[0..<frameSamples])
            micResidue.removeFirst(frameSamples)
            if let coded = enc.encode(frame) {
                var packet = Data(capacity: coded.count + 2)
                packet.append(UInt8((uplinkSeq >> 8) & 0xFF))
                packet.append(UInt8(uplinkSeq & 0xFF))
                packet.append(contentsOf: coded)
                uplinkSeq = uplinkSeq &+ 1
                onUplink?(packet)
            }
        }
        if micResidue.count > frameSamples * 4 {
            micResidue.removeFirst(micResidue.count - frameSamples * 4)
        }
    }

    private func pushStats() {
        var s: DownlinkStats?
        queueLock.lock()
        s = DownlinkStats(
            depth: Self.downlinkDepth,
            dropouts: downlinkDropouts,
            skips: downlinkSkips,
            late: downlinkLate,
            fill: downlinkQueue.count / max(frameSamples, 1))
        queueLock.unlock()
        if let s { onStats?(s) }
    }

    func pushDownlink(seq: UInt16, opus data: Data) {
        guard let dec = decoder, params != nil else { return }
        if downlinkExpected != 0 {
            let gap = seqWrappedDelta(seq, downlinkExpected)
            if gap > 0 && gap < 32 {
                for _ in 0..<gap {
                    if let plc = dec.decodePLC() { enqueue(plc) }
                    downlinkSkips += 1
                    downlinkExpected = downlinkExpected &+ 1
                }
            }
        }
        let bytes = [UInt8](data)
        if let pcm = dec.decode(bytes) { enqueue(pcm) }
        downlinkExpected = seq &+ 1

        statsFrames += 1
        if statsFrames >= 250 { // ~5 s at 20 ms frames
            statsFrames = 0
            pushStats()
        }
    }

    private var frameSamples: Int {
        ((params?.sampleRate ?? 48000) * (params?.frameMs ?? 20) / 1000) * (params?.channels ?? 1)
    }

    private func enqueue(_ samples: [Int16]) {
        let fs = frameSamples
        queueLock.lock()
        if downlinkStarted && downlinkQueue.isEmpty {
            // Playback starved: the sender's clock is running behind ours.
            // Conceal the gap with one PLC frame and keep playing — pausing to
            // re-buffer would turn the dropout into a growing silence gap.
            downlinkDropouts += 1
            if let plc = decoder?.decodePLC() {
                downlinkQueue.append(contentsOf: plc)
            }
        }
        downlinkQueue.append(contentsOf: samples)
        let bufferCap = fs * 20
        if downlinkQueue.count > bufferCap {
            let excess = downlinkQueue.count - bufferCap
            if downlinkStarted && excess >= fs {
                downlinkLate += 1
            }
            downlinkQueue.removeFirst(downlinkQueue.count - bufferCap)
        }
        queueLock.unlock()
    }

    private func renderOutput(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let channels = params?.channels ?? 1
        let fs = frameSamples

        queueLock.lock()
        // Pre-buffer once at start so an initial burst of jitter is absorbed;
        // afterwards we play through in real time.
        if !downlinkStarted {
            if downlinkQueue.count < Self.downlinkDepth * fs {
                queueLock.unlock()
                fillSilence(list, frameCount: frameCount, channels: channels)
                return
            }
            downlinkStarted = true
        }
        var out = [Int16]()
        let take = min(frameCount * channels, downlinkQueue.count)
        out = Array(downlinkQueue[0..<take])
        downlinkQueue.removeFirst(take)
        queueLock.unlock()

        // Iterate the real (variable-length) buffer list. Copying `list.pointee`
        // truncates to the first inline buffer and yields garbage mData for the rest.
        let abl = UnsafeMutableAudioBufferListPointer(list)
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let ch = Int(buffer.mNumberChannels)
            let bytesPerFrame = UInt32(MemoryLayout<Float>.stride) * UInt32(ch)
            let frames = Int(buffer.mDataByteSize / max(bytesPerFrame, 1))
            let n = min(frameCount, frames)
            let ptr = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                for c in 0..<ch {
                    // Clamp the source channel so mono Opus playing to a
                    // stereo output doesn't read past the available samples.
                    let srcC = c < channels ? c : (channels - 1)
                    let idx = i * channels + srcC
                    let s: Float = idx < out.count ? Float(out[idx]) / 32768.0 : 0
                    ptr[i * ch + c] = s
                }
            }
        }
    }

    private func fillSilence(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int, channels: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(list)
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let ch = Int(buffer.mNumberChannels)
            let bytesPerFrame = UInt32(MemoryLayout<Float>.stride) * UInt32(ch)
            let frames = Int(buffer.mDataByteSize / max(bytesPerFrame, 1))
            let n = min(frameCount, frames)
            for i in 0..<n {
                let ptr = raw.assumingMemoryBound(to: Float.self)
                for c in 0..<ch { ptr[i * ch + c] = 0 }
            }
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        encoder = nil
        decoder = nil
        started = false
        micResidue.removeAll()
        queueLock.lock()
        downlinkQueue.removeAll()
        queueLock.unlock()
        downlinkStarted = false
        downlinkDropouts = 0
        downlinkSkips = 0
        downlinkLate = 0
        statsFrames = 0
    }

    private func bufferToInt16(_ buffer: AVAudioPCMBuffer, channels: Int) -> [Int16] {
        guard let ch = buffer.floatChannelData else { return [] }
        let devChannels = Int(buffer.format.channelCount)
        let actualChannels = min(devChannels, channels)
        let frames = Int(buffer.frameLength)
        var out = [Int16](repeating: 0, count: frames * channels)
        for c in 0..<actualChannels {
            let ptr = ch[c]
            for i in 0..<frames {
                var v = ptr[i]
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                out[i * channels + c] = Int16(v * 32767)
            }
        }
        return out
    }

    private func seqWrappedDelta(_ a: UInt16, _ b: UInt16) -> Int {
        var d = Int(a) - Int(b)
        if d > 32767 { d -= 65536 }
        if d < -32768 { d += 65536 }
        return d
    }
}
