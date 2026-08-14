import Foundation
import Network
import SwiftUI
import AudioToolbox

// The rig's two tunable registers. The active VFO drives the front end, so a
// switch sends FR0;/FR1; to keep S-meter and mode in agreement with the readout.
enum VFO: Equatable {
    case a
    case b
}

// A frequency band addressable via the BD/BU CAT command, or the special 60 m
// band (no BD code — handled by writing a frequency directly).
struct Band: Equatable, Identifiable {
    let id: Int          // BD band number, or -1 for 60 m
    let label: String

    var is60m: Bool { id == -1 }
    var isBD: Bool { id >= 0 && id <= 10 }

    static let all: [Band] = [
        Band(id: 0, label: "160 m"),
        Band(id: 1, label: "80 m"),
        Band(id: 2, label: "40 m"),
        Band(id: 3, label: "30 m"),
        Band(id: 4, label: "20 m"),
        Band(id: 5, label: "17 m"),
        Band(id: 6, label: "15 m"),
        Band(id: 7, label: "12 m"),
        Band(id: 8, label: "10 m"),
        Band(id: 9, label: "6 m"),
        Band(id: -1, label: "60 m"),
        Band(id: 10, label: "GENE"),
    ]

    static let default60mFreq: Int64 = 5_330_000
}

@MainActor
final class RemoteRigModel: ObservableObject {
    // MARK: published UI state
    @Published var connected = false
    @Published var activeVFO: VFO = .a
    @Published var freqA: Int64 = 14000000
    @Published var freqB: Int64 = 14000000
    @Published var mode = "USB"
    @Published var selectedBand: Band?
    @Published var ptt = false
    @Published var txLock = false
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

    // MARK: link / streaming telemetry
    @Published var serverStats: JitterStats?
    @Published var downlinkStats: DownlinkStats?
    @Published var rttMs: Int?
    @Published var downlinkPackets = 0
    @Published var downlinkBytes = 0
    @Published var uplinkPackets = 0
    @Published var showStats = true { didSet { UserDefaults.standard.set(showStats, forKey: "showStats") } }

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
    @Published var band60Freq: Int64 = Band.default60mFreq { didSet { UserDefaults.standard.set(band60Freq, forKey: "band60Freq") } }

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
        if d.object(forKey: "band60Freq") != nil { band60Freq = Int64(d.integer(forKey: "band60Freq")) }
        if d.object(forKey: "showStats") != nil { showStats = d.bool(forKey: "showStats") }
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
    private var pendingStateRefresh: Task<Void, Never>?
    private var powerOnSyncPending = false
    private var powerOnSyncProbesLeft = 0
    private var probeInFlight = false
    static let maxPowerOnSyncProbes = 5

    private var pingTask: Task<Void, Never>?
    private var lastPingSentAt: Date?

    // Test seam: record the timestamp a ping was sent so pong RTT can be
    // asserted without a live connection.
    func primePingSent(at: Date) { lastPingSentAt = at }

    // Test seam: invoked for every CAT command sent, so tests can assert what
    // reaches the wire without a live connection.
    var onSendCat: ((String) -> Void)?

    // Test seam: invoked for every PTT message sent, so tests can assert the
    // momentary pad and the TX lock latch without a live connection.
    var onSendPTT: ((Bool) -> Void)?

    // Test seam: invoked with the action ("start"/"stop") for every audio
    // message sent, so tests can assert auto-start without a live connection.
    var onSendAudio: ((String) -> Void)?

    // Test seam: invoked for every state refresh request, so tests can assert
    // when the panel re-syncs without a live connection.
    var onSendStateReq: (() -> Void)?

    // The rig's DSP takes seconds to boot after PS1;. Sync attempts space
    // themselves by this much. Tests shorten it to avoid real sleeps.
    var powerOnBootDelay: Duration = .seconds(3)

    // MARK: lifecycle
    func connect() {
        disconnect()
        activeVFO = .a
        status = "connecting…"
        serverStats = nil
        downlinkStats = nil
        rttMs = nil
        downlinkPackets = 0
        downlinkBytes = 0
        uplinkPackets = 0
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
        pendingStateRefresh?.cancel()
        pendingStateRefresh = nil
        powerOnSyncPending = false
        probeInFlight = false
        pingTask?.cancel()
        pingTask = nil
        lastPingSentAt = nil
        control?.cancel()
        control = nil
        connected = false
        status = "disconnected"
        updatePTT(false)
        stopLocalAudio()
        serverStats = nil
        downlinkStats = nil
        rttMs = nil
        downlinkPackets = 0
        downlinkBytes = 0
        uplinkPackets = 0
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

    // Ping the control channel periodically so the UI can show link latency.
    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                lastPingSentAt = Date()
                send(Msg(t: "ping"))
                try? await Task.sleep(for: .seconds(5))
            }
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
            startAudio()
            // Only start pinging once authenticated, so the control channel is
            // never used before the auth handshake (which would fail auth).
            startPing()
        case "auth_fail":
            status = "auth failed"
            disconnect()
        case "cat_resp":
            // TCP ordering guarantees the first reply after the probe is the
            // probe's. Resolve it on any cat_resp so a nil-raw reply cannot
            // leave probeInFlight stuck (which would swallow later errors).
            if probeInFlight { handleProbeResult(true) }
            if let raw = m.raw { applyEvent(raw); appendEvent(raw) }
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
            if let on = m.on { updatePTT(on) }
        case "stats":
            if let st = m.stats { serverStats = st }
        case "pong":
            if let t = lastPingSentAt {
                rttMs = Int(Date().timeIntervalSince(t) * 1000)
            }
        case "error":
            // A timed-out probe is expected while the rig boots; it is not a
            // connection error and must not dirty the status line.
            if probeInFlight {
                handleProbeResult(false)
            } else {
                status = "error: \(m.msg ?? "unknown")"
            }
        default:
            break
        }
    }

    private func applyState(_ s: RigState) {
        freqA = s.freqA
        freqB = s.freqB
        mode = s.mode
        updatePTT(s.ptt)
        af = s.af
        rf = s.rf
        power = s.power
        sql = s.sql
        smeter = s.smeter
        audioOn = s.audioOn
        rxPaused = s.rxPaused
        powerOn = s.powerOn
        retryPowerOnSyncIfNeeded(s)
    }

    // After a power-on sync, the snapshot says "not ready" when either the
    // frequency read (FA;) or the power read (PS;) failed — freqA == 0 or
    // powerOn == false. The rig can never sit at 0 Hz, and a power-on cycle
    // expects PS1;, so either signals it was still booting when the server
    // snapshot ran. Re-probe a bounded number of times instead of leaving the
    // panel stale for however long the boot actually takes.
    private func retryPowerOnSyncIfNeeded(_ s: RigState) {
        guard powerOnSyncPending else { return }
        let rigNotReady = s.freqA == 0 || !s.powerOn
        if rigNotReady {
            probeAgainOrGiveUp()
        } else {
            powerOnSyncPending = false
        }
    }

    // A PTT report from the wire (state or ack). If the rig says the latch is
    // no longer keying TX, drop the latch so the indicator stays honest.
    private func updatePTT(_ on: Bool) {
        ptt = on
        if !on { txLock = false }
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
        switch i { case 1: return "LSB"; case 2: return "USB"; case 3: return "CW"; case 4: return "FM"; case 5: return "AM"; case 6: return "FSK"; case 7: return "CW-R"; case 9: return "FSK-R"; default: return nil }
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
    func sendCat(_ cmd: String) {
        onSendCat?(cmd)
        send(Msg(t: "cat", cmd: cmd))
    }

    // The frequency of the active VFO, for readout/band and nudge arithmetic.
    var activeFreq: Int64 { activeVFO == .a ? freqA : freqB }

    func setFreq(_ hz: Int64) {
        let clamped = max(hz, 0)
        switch activeVFO {
        case .a:
            freqA = clamped
        case .b:
            freqB = clamped
        }
        let prefix = activeVFO == .a ? "FA" : "FB"
        sendCat(prefix + String(format: "%011d", clamped) + ";")
    }
    func nudgeFreq(_ delta: Int64) { setFreq(activeFreq + delta) }

    // Select the active VFO and tell the rig (FR0;/FR1;) so S-meter and mode
    // track the readout.
    func selectVFO(_ vfo: VFO) {
        guard vfo != activeVFO else { return }
        activeVFO = vfo
        sendCat(vfo == .a ? "FR0;" : "FR1;")
    }

    func setMode(_ m: String) { mode = m; sendCat("MD" + modeDigit(m) + ";") }
    func modeDigit(_ m: String) -> String {
        switch m { case "LSB": return "1"; case "USB": return "2"; case "CW": return "3"; case "FM": return "4"; case "AM": return "5"; case "FSK": return "6"; case "CW-R": return "7"; case "FSK-R": return "9"; default: return "2" }
    }
    func setAF(_ v: Int) { af = v; sendCat("AG" + String(format: "%03d", v) + ";") }
    func setRF(_ v: Int) { rf = v; sendCat("RG" + String(format: "%03d", v) + ";") }
    func setPower(_ v: Int) { power = v; sendCat("PC" + String(format: "%03d", v) + ";") }
    func setSQL(_ v: Int) { sql = v; sendCat("SQ" + String(format: "%03d", v) + ";") }

    // Select a band via BD (standard bands) or FA (60 m, no BD code).
    func selectBand(_ band: Band) {
        selectedBand = band
        if band.is60m {
            setFreq(band60Freq)
            sendCat("MD;")
        } else {
            sendCat(String(format: "BD%02d;", band.id))
            // BD jumps the VFO to the band's stored frequency without
            // broadcasting it. Query the active VFO and the mode so the
            // readout and mode picker refresh for whatever the rig recalls
            // per-band.
            let prefix = activeVFO == .a ? "FA" : "FB"
            sendCat("\(prefix);")
            sendCat("MD;")
        }
    }

    func setPTT(_ on: Bool) {
        // While latched, the latch owns TX: the momentary pad (or spacebar)
        // cannot unkey it. Release only via the TX LOCK toggle or a rig report.
        if txLock && !on { return }
        ptt = on
        onSendPTT?(on)
        send(Msg(t: "ptt", on: on))
        if let a = audio { a.pttActive = on }
    }

    // TX LOCK — latch the transmitter on until released. Distinct from the
    // momentary hold pad: the latch survives until the operator toggles it off
    // (or the rig reports it is no longer keying).
    func toggleTXLock() {
        txLock.toggle()
        setPTT(txLock)
    }

    func startAudio() {
        let req = OpusParams(
            sampleRate: opusSampleRate,
            channels: opusChannels,
            frameMs: opusFrameMs,
            bitrate: opusBitrate)
        onSendAudio?("start")
        send(Msg(t: "audio", action: "start", opus: req))
        openAudioUDP()
        setupAudioEngine()
    }

    func stopAudio() {
        onSendAudio?("stop")
        send(Msg(t: "audio", action: "stop"))
    }

    func toggleAudio() {
        if audioOn { stopAudio() } else { startAudio() }
    }

    func toggleRxPause() {
        let next = !rxPaused
        send(Msg(t: "audio_rx", action: next ? "pause" : "resume"))
    }

    // Rig power — the PS command. Powering the rig off drops it into standby,
    // so the state refresh is skipped (the rig would not answer for seconds);
    // powering on probes for readiness before syncing the panel.
    func setRigPower(_ on: Bool) {
        pendingStateRefresh?.cancel()
        pendingStateRefresh = nil
        guard on != powerOn else { return }
        powerOn = on
        sendCat(on ? "PS1;" : "PS0;")
        if on {
            powerOnSyncPending = true
            // The initial probe is free; the budget counts re-probes.
            powerOnSyncProbesLeft = Self.maxPowerOnSyncProbes - 1
            schedulePowerOnProbe()
        } else {
            powerOnSyncPending = false
        }
    }

    // The rig's DSP is still booting right after PS1;. A full state snapshot
    // (nine queries, ~20 s, stalling the control link) would time out one
    // query after another, so probe with FA; — a single cheap 1.5 s query and
    // the very command that fails first — and only fetch state once it answers.
    private func schedulePowerOnProbe() {
        pendingStateRefresh = Task { @MainActor in
            do {
                try await Task.sleep(for: powerOnBootDelay)
            } catch {
                return
            }
            probeRig()
        }
    }

    private func probeRig() {
        probeInFlight = true
        sendCat("FA;")
    }

    private func handleProbeResult(_ answered: Bool) {
        guard powerOnSyncPending else {
            probeInFlight = false
            return
        }
        probeInFlight = false
        if answered {
            refreshState()
        } else {
            probeAgainOrGiveUp()
        }
    }

    // Shared budget check: probe again while probes remain, else end the
    // power-on sync cycle and tell the user the rig never came up.
    private func probeAgainOrGiveUp() {
        if powerOnSyncProbesLeft > 0 {
            powerOnSyncProbesLeft -= 1
            schedulePowerOnProbe()
        } else {
            powerOnSyncPending = false
            status = "power on: rig not responding"
        }
    }

    func refreshState() {
        onSendStateReq?()
        send(Msg(t: "state_req"))
    }

    // MARK: audio engine
    func setupAudioEngine() {
        guard audio == nil else { return }
        let inID: AudioDeviceID? = inputDeviceID != 0 ? AudioDeviceID(inputDeviceID) : nil
        let outID: AudioDeviceID? = outputDeviceID != 0 ? AudioDeviceID(outputDeviceID) : nil
        let engine = AudioEngine(inputDevice: inID, outputDevice: outID)
        engine.onUplink = { [weak self] packet in
            // The audio tap runs on a background thread; publish on main.
            Task { @MainActor in self?.uplinkPackets += 1 }
            self?.audioConn?.send(content: packet, completion: .idempotent)
        }
        engine.onStats = { [weak self] s in
            Task { @MainActor in self?.downlinkStats = s }
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
            self.downlinkPackets += 1
            self.downlinkBytes += data.count - 2
            let seq = UInt16(data[0]) << 8 | UInt16(data[1])
            let opus = data.subdata(in: 2..<data.count)
            self.audio?.pushDownlink(seq: seq, opus: opus)
            self.receiveAudio()
        }
    }
}
