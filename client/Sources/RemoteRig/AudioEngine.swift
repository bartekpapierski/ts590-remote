import AVFoundation
import AudioToolbox
import OpusWrapper

final class AudioEngine {
    var onUplink: ((Data) -> Void)?
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

    init(inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?) {
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
    }

    func configure(params: OpusParams) {
        guard !started else { return }
        self.params = params
        encoder = OpusEncoder(
            sampleRate: params.sampleRate, channels: params.channels,
            application: .restrictedLowDelay, bitrate: params.bitrate, frameMs: params.frameMs)
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
        let outFmt = engine.outputNode.outputFormat(forBus: 0)

        let source = AVAudioSourceNode(format: outFmt) { [weak self] (_, _, frameCount, bufferList) -> OSStatus in
            self?.renderOutput(bufferList, frameCount: Int(frameCount))
            return 0
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: outFmt)

        let frameSamples = ((params?.sampleRate ?? 48000) * (params?.frameMs ?? 20) / 1000) * (params?.channels ?? 1)
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

    func pushDownlink(seq: UInt16, opus data: Data) {
        guard let dec = decoder, params != nil else { return }
        if downlinkExpected != 0 {
            let gap = seqWrappedDelta(seq, downlinkExpected)
            if gap > 0 && gap < 32 {
                for _ in 0..<gap {
                    if let plc = dec.decodePLC() { enqueue(plc) }
                    downlinkExpected = downlinkExpected &+ 1
                }
            }
        }
        let bytes = [UInt8](data)
        if let pcm = dec.decode(bytes) { enqueue(pcm) }
        downlinkExpected = seq &+ 1
    }

    private func enqueue(_ samples: [Int16]) {
        queueLock.lock()
        downlinkQueue.append(contentsOf: samples)
        let max = ((params?.sampleRate ?? 48000) * (params?.frameMs ?? 20) / 1000) * (params?.channels ?? 1) * 20
        if downlinkQueue.count > max {
            downlinkQueue.removeFirst(downlinkQueue.count - max)
        }
        queueLock.unlock()
    }

    private func renderOutput(_ list: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let channels = params?.channels ?? 1
        var out = [Int16]()
        queueLock.lock()
        let take = min(frameCount * channels, downlinkQueue.count)
        out = Array(downlinkQueue[0..<take])
        downlinkQueue.removeFirst(take)
        queueLock.unlock()

        // Iterate the real (variable-length) buffer list. Copying `list.pointee`
        // truncates to the first inline buffer and yields garbage mData for the rest.
        let abl = UnsafeMutableAudioBufferListPointer(list)
        var chIdx = 0
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let ch = Int(buffer.mNumberChannels)
            let bytesPerFrame = UInt32(MemoryLayout<Float>.stride) * UInt32(ch)
            let frames = Int(buffer.mDataByteSize / max(bytesPerFrame, 1))
            let n = min(frameCount, frames)
            let ptr = raw.assumingMemoryBound(to: Float.self)
            if ch == 1 {
                for i in 0..<n {
                    let idx = i * channels + chIdx
                    let s: Int16 = idx < out.count ? out[idx] : 0
                    ptr[i] = Float(s) / 32768.0
                }
            } else {
                for i in 0..<n {
                    for c in 0..<ch {
                        let idx = i * channels + c
                        let s: Float = idx < out.count ? Float(out[idx]) / 32768.0 : 0
                        ptr[i * ch + c] = s
                    }
                }
            }
            chIdx += ch
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
