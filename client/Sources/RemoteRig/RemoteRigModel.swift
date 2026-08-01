import Foundation
import Network
import SwiftUI
import AudioToolbox

@MainActor
final class RemoteRigModel: ObservableObject {
    // MARK: published UI state
    @Published var connected = false
    @Published var freqA: Int64 = 14000000
    @Published var freqB: Int64 = 14000000
    @Published var mode = "USB"
    @Published var ptt = false
    @Published var af = 120
    @Published var rf = 255
    @Published var power = 50
    @Published var sql = 0
    @Published var smeter = 0
    @Published var audioOn = false
    @Published var rxPaused = false
    @Published var powerOn = false
    @Published var stepHz: Int64 = 100
    @Published var audioParams: OpusParams?
    @Published var status = "disconnected"
    @Published var events: [String] = []

    // MARK: connection settings (persisted)
    @Published var host: String = "192.168.1.10" { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: Int = 5900 { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var psk: String = "change-me" { didSet { UserDefaults.standard.set(psk, forKey: "psk") } }
    @Published var inputDeviceID: Int = 0 { didSet { UserDefaults.standard.set(inputDeviceID, forKey: "inputDeviceID") } }
    @Published var outputDeviceID: Int = 0 { didSet { UserDefaults.standard.set(outputDeviceID, forKey: "outputDeviceID") } }

    @Published var opusSampleRate: Int = 48000 { didSet { UserDefaults.standard.set(opusSampleRate, forKey: "opusSampleRate") } }
    @Published var opusChannels: Int = 1 { didSet { UserDefaults.standard.set(opusChannels, forKey: "opusChannels") } }
    @Published var opusFrameMs: Int = 20 { didSet { UserDefaults.standard.set(opusFrameMs, forKey: "opusFrameMs") } }
    @Published var opusBitrate: Int = 48000 { didSet { UserDefaults.standard.set(opusBitrate, forKey: "opusBitrate") } }

    // Opus bitrate bounds for the settings UI, in bps. The server clamps to
    // [500, 128000]; the stepper works in whole kbps.
    static let minOpusBitrate = 5000
    static let maxOpusBitrate = 128000
    static let opusBitrateStep = 1000

    init() {
        let d = UserDefaults.standard
        if let h = d.string(forKey: "host") { host = h }
        if d.object(forKey: "port") != nil { port = d.integer(forKey: "port") }
        if let p = d.string(forKey: "psk") { psk = p }
        if d.object(forKey: "inputDeviceID") != nil { inputDeviceID = d.integer(forKey: "inputDeviceID") }
        if d.object(forKey: "outputDeviceID") != nil { outputDeviceID = d.integer(forKey: "outputDeviceID") }
        if d.object(forKey: "opusSampleRate") != nil { opusSampleRate = d.integer(forKey: "opusSampleRate") }
        if d.object(forKey: "opusChannels") != nil { opusChannels = d.integer(forKey: "opusChannels") }
        if d.object(forKey: "opusFrameMs") != nil { opusFrameMs = d.integer(forKey: "opusFrameMs") }
        if d.object(forKey: "opusBitrate") != nil { opusBitrate = d.integer(forKey: "opusBitrate") }
        validateDeviceIDs(input: AudioDevices.inputDevices, output: AudioDevices.outputDevices)
    }

    func validateDeviceIDs(input: [AudioDevices.Device], output: [AudioDevices.Device]) {
        let validInputIDs = Set(input.map { Int($0.id) })
        if !validInputIDs.contains(inputDeviceID) { inputDeviceID = 0 }
        let validOutputIDs = Set(output.map { Int($0.id) })
        if !validOutputIDs.contains(outputDeviceID) { outputDeviceID = 0 }
    }

    private var control: NWConnection?
    private var audioConn: NWConnection?
    var audio: AudioEngine?
    private var downlinkExpected: UInt16 = 0

    // MARK: lifecycle
    func connect() {
        disconnect()
        status = "connecting…"
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port("\(port)")!,
            using: .tcp)
        control = conn
        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in self?.handleControlState(st) }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        control?.cancel()
        control = nil
        connected = false
        status = "disconnected"
        stopLocalAudio()
    }

    // stopLocalAudio tears down the local audio engine and the audio UDP
    // socket. Called when the server reports `audio stopped` and on
    // disconnect. Without stopping the engine, the AVAudioEngine keeps
    // running (mic tap, uplink packets) and a later start would create a
    // second concurrent engine.
    func stopLocalAudio() {
        audio?.stop()
        audio = nil
        audioOn = false
        audioConn?.cancel()
        audioConn = nil
    }

    private func handleControlState(_ st: NWConnection.State) {
        switch st {
        case .ready:
            connected = true
            status = "authenticating…"
            send(Msg(t: "auth", token: psk))
            send(Msg(t: "state_req"))
            receiveControl()
        case .failed(let err), .waiting(let err):
            status = "error: \(err)"
            connected = false
        default:
            break
        }
    }

    private func receiveControl() {
        control?.receive(minimumIncompleteLength: 0, maximumLength: 65536) { [weak self] data, _, _, err in
            guard let self, err == nil, let data, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                self.handleLine(String(line))
            }
            self.receiveControl()
        }
    }

    func handleLine(_ line: String) {
        guard let m = Msg.parse(line) else { return }
        switch m.t {
        case "auth_ok":
            status = "connected"
        case "auth_fail":
            status = "auth failed"
            disconnect()
        case "cat_resp":
            if let raw = m.raw { appendEvent(raw) }
        case "cat_event":
            if let raw = m.raw { applyEvent(raw); appendEvent(raw) }
        case "state":
            if let s = m.state { applyState(s) }
        case "audio":
            if m.status == "started" { audioOn = true }
            else if m.status == "stopped" { stopLocalAudio() }
        case "audio_rx":
            rxPaused = (m.status == "paused")
        case "audio_params":
            let p = OpusParams(
                sampleRate: m.sampleRate ?? 48000,
                channels: m.channels ?? 1,
                frameMs: m.frameMs ?? 20,
                bitrate: m.bitrate ?? 48000)
            audioParams = p
            audio?.configure(params: p)
            if m.adjusted == true { status = "audio: params adjusted by server" }
        case "ptt_ack":
            if let on = m.on { ptt = on }
        case "error":
            status = "error: \(m.msg ?? "unknown")"
        default:
            break
        }
    }

    private func applyState(_ s: RadioState) {
        freqA = s.freqA
        freqB = s.freqB
        mode = s.mode
        ptt = s.ptt
        af = s.af
        rf = s.rf
        power = s.power
        sql = s.sql
        smeter = s.smeter
        audioOn = s.audioOn
        rxPaused = s.rxPaused
        powerOn = s.powerOn
    }

    func applyEvent(_ raw: String) {
        if raw.hasPrefix("FA") {
            let digits = raw.dropFirst(2).filter { $0.isNumber }
            if let f = Int64(String(digits)) { freqA = f }
        } else if raw.hasPrefix("FB") {
            let digits = raw.dropFirst(2).filter { $0.isNumber }
            if let f = Int64(String(digits)) { freqB = f }
        } else if raw.hasPrefix("MD") {
            if let c = raw.dropFirst(2).first, let i = Int(String(c)), let m = modeName(i) { mode = m }
        } else if raw.hasPrefix("SM0") {
            let digits = raw.dropFirst(3).filter { $0.isNumber }
            if let v = Int(String(digits)) { smeter = v }
        }
    }

    func modeName(_ i: Int) -> String? {
        switch i { case 0: return "LSB"; case 1: return "USB"; case 2: return "CW"; case 3: return "FM"; case 4: return "AM"; case 5: return "FSK"; case 6: return "CW-R"; case 7: return "USER"; default: return nil }
    }

    private func appendEvent(_ raw: String) {
        events.append(raw)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    private func send(_ m: Msg) {
        guard let conn = control else { return }
        conn.send(content: m.jsonLine(), completion: .contentProcessed({ _ in }))
    }

    // MARK: commands
    func sendCat(_ cmd: String) { send(Msg(t: "cat", cmd: cmd)) }

    func setFreq(_ hz: Int64) {
        let clamped = max(hz, 0)
        freqA = clamped
        let s = String(format: "%011d", clamped)
        sendCat("FA" + s + ";")
    }
    func nudgeFreq(_ delta: Int64) { setFreq(freqA + delta) }

    func setMode(_ m: String) { sendCat("MD" + modeDigit(m) + ";") }
    func modeDigit(_ m: String) -> String {
        switch m { case "LSB": return "0"; case "USB": return "1"; case "CW": return "2"; case "FM": return "3"; case "AM": return "4"; case "FSK": return "5"; case "CW-R": return "6"; case "USER": return "7"; default: return "1" }
    }
    func setAF(_ v: Int) { af = v; sendCat("AG" + String(format: "%03d", v) + ";") }
    func setRF(_ v: Int) { rf = v; sendCat("RG" + String(format: "%03d", v) + ";") }
    func setPower(_ v: Int) { power = v; sendCat("PC" + String(format: "%03d", v) + ";") }
    func setSQL(_ v: Int) { sql = v; sendCat("SQL" + String(format: "%03d", v) + ";") }

    func setPTT(_ on: Bool) {
        send(Msg(t: "ptt", on: on))
        if let a = audio { a.pttActive = on }
    }

    func toggleAudio() {
        if audioOn { send(Msg(t: "audio", action: "stop")) }
        else {
            let req = OpusParams(
                sampleRate: opusSampleRate,
                channels: opusChannels,
                frameMs: opusFrameMs,
                bitrate: opusBitrate)
            send(Msg(t: "audio", action: "start", opus: req))
            openAudioUDP()
            setupAudioEngine()
        }
    }

    func toggleRxPause() {
        let next = !rxPaused
        send(Msg(t: "audio_rx", action: next ? "pause" : "resume"))
    }

    func togglePower() {
        let next = !powerOn
        powerOn = next
        sendCat(next ? "PS1;" : "PS0;")
        refreshState()
    }

    func refreshState() {
        send(Msg(t: "state_req"))
    }

    // MARK: audio engine
    func setupAudioEngine() {
        guard audio == nil else { return }
        let inID: AudioDeviceID? = inputDeviceID != 0 ? AudioDeviceID(inputDeviceID) : nil
        let outID: AudioDeviceID? = outputDeviceID != 0 ? AudioDeviceID(outputDeviceID) : nil
        let engine = AudioEngine(inputDevice: inID, outputDevice: outID)
        engine.onUplink = { [weak self] packet in
            self?.audioConn?.send(content: packet, completion: .idempotent)
        }
        audio = engine
    }

    private func openAudioUDP() {
        guard audioConn == nil else { return }
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port("\(port + 1)")!,
            using: .udp)
        audioConn = conn
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: .main)
        receiveAudio()
        // hello so the server learns our address (downlink can flow before PTT)
        conn.send(content: Data([0, 0]), completion: .idempotent)
    }

    private func receiveAudio() {
        audioConn?.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data, data.count > 2 else { self?.receiveAudio(); return }
            let seq = UInt16(data[0]) << 8 | UInt16(data[1])
            let opus = data.subdata(in: 2..<data.count)
            self.audio?.pushDownlink(seq: seq, opus: opus)
            self.receiveAudio()
        }
    }
}
