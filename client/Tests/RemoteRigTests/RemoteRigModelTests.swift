import Foundation
import Testing
@testable import RemoteRig

@MainActor
struct RemoteRigModelTests {

    @Test func testModeName() {
        let model = RemoteRigModel()
        #expect(model.modeName(1) == "LSB")
        #expect(model.modeName(2) == "USB")
        #expect(model.modeName(3) == "CW")
        #expect(model.modeName(4) == "FM")
        #expect(model.modeName(5) == "AM")
        #expect(model.modeName(6) == "FSK")
        #expect(model.modeName(7) == "CW-R")
        #expect(model.modeName(9) == "FSK-R")
        #expect(model.modeName(0) == nil)
        #expect(model.modeName(8) == nil)
        #expect(model.modeName(-1) == nil)
    }

    @Test func testModeDigit() {
        let model = RemoteRigModel()
        #expect(model.modeDigit("LSB") == "1")
        #expect(model.modeDigit("USB") == "2")
        #expect(model.modeDigit("CW") == "3")
        #expect(model.modeDigit("FM") == "4")
        #expect(model.modeDigit("AM") == "5")
        #expect(model.modeDigit("FSK") == "6")
        #expect(model.modeDigit("CW-R") == "7")
        #expect(model.modeDigit("FSK-R") == "9")
        #expect(model.modeDigit("UNKNOWN") == "2")
    }

    @Test func testSetModeUpdatesModelOptimistically() {
        // Regression: the mode Picker is bound to model.mode. Selecting a mode
        // must reflect the selection immediately; otherwise the control stays
        // on the last server-reported mode (e.g. LSB on 40 m) even though the
        // rig was commanded to USB — "the command is sent but the control
        // shows the old mode".
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        model.mode = "LSB"

        model.setMode("USB")

        #expect(model.mode == "USB")
        #expect(sent == ["MD2;"])
    }

    @Test func testSetModeNeverChangesModeOnScroll() {
        // Scrolling the VFO only tunes frequency; it must never emit a mode
        // command or touch the mode state (the user's symptom is that the
        // mode control flips to LSB while scrolling).
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        model.mode = "USB"
        model.freqA = 14000000

        model.nudgeFreq(100)
        model.nudgeFreq(-100)

        #expect(model.mode == "USB")
        #expect(sent.allSatisfy { $0.hasPrefix("FA") })
    }

    @Test func testApplyEventFrequencyA() {
        let model = RemoteRigModel()
        model.applyEvent("FA00014000000;")
        #expect(model.freqA == 14000000)
    }

    @Test func testApplyEventFrequencyB() {
        let model = RemoteRigModel()
        model.applyEvent("FB00007000000;")
        #expect(model.freqB == 7000000)
    }

    @Test func testApplyEventMode() {
        let model = RemoteRigModel()
        model.applyEvent("MD2;")
        #expect(model.mode == "USB")

        model.applyEvent("MD1;")
        #expect(model.mode == "LSB")

        model.applyEvent("MD3;")
        #expect(model.mode == "CW")
    }

    @Test func testApplyEventSMeter() {
        let model = RemoteRigModel()
        model.applyEvent("SM005;")
        #expect(model.smeter == 5)

        model.applyEvent("SM025;")
        #expect(model.smeter == 25)
    }

    @Test func testApplyEventIgnoresUnknown() {
        let model = RemoteRigModel()
        let originalFreq = model.freqA
        model.applyEvent("UNKNOWN_EVENT;")
        #expect(model.freqA == originalFreq)
    }

    @Test func testValidateDeviceIDs_ResetsInvalidInput() {
        let model = RemoteRigModel()
        model.inputDeviceID = 99999
        model.validateDeviceIDs(input: [], output: [])
        #expect(model.inputDeviceID == 0)
    }

    @Test func testValidateDeviceIDs_ResetsInvalidOutput() {
        let model = RemoteRigModel()
        model.outputDeviceID = 99999
        model.validateDeviceIDs(input: [], output: [])
        #expect(model.outputDeviceID == 0)
    }

    @Test func testValidateDeviceIDs_KeepsValidInput() {
        let model = RemoteRigModel()
        let devices = [AudioDevices.Device(id: 42, name: "Test Input")]
        model.inputDeviceID = 42
        model.validateDeviceIDs(input: devices, output: [])
        #expect(model.inputDeviceID == 42)
    }

    @Test func testValidateDeviceIDs_KeepsValidOutput() {
        let model = RemoteRigModel()
        let devices = [AudioDevices.Device(id: 75, name: "Test Output")]
        model.outputDeviceID = 75
        model.validateDeviceIDs(input: [], output: devices)
        #expect(model.outputDeviceID == 75)
    }

    @Test func testValidateDeviceIDs_KeepsDefaultZero() {
        let model = RemoteRigModel()
        model.inputDeviceID = 0
        model.outputDeviceID = 0
        model.validateDeviceIDs(input: [], output: [])
        #expect(model.inputDeviceID == 0)
        #expect(model.outputDeviceID == 0)
    }

    @Test func testSetFreq() {
        let model = RemoteRigModel()
        model.setFreq(14000000)
        #expect(model.freqA == 14000000)
    }

    @Test func testNudgeFreq() {
        let model = RemoteRigModel()
        model.freqA = 14000000
        model.nudgeFreq(100)
        #expect(model.freqA == 14000100)

        model.nudgeFreq(-50)
        #expect(model.freqA == 14000050)
    }

    @Test func testSetFreqClampsNegative() {
        let model = RemoteRigModel()
        model.setFreq(-100)
        #expect(model.freqA == 0)
    }

    @Test func testSelectVFOSwitchesTarget() {
        let model = RemoteRigModel()
        #expect(model.activeVFO == .a)
        model.selectVFO(.b)
        #expect(model.activeVFO == .b)
        model.selectVFO(.a)
        #expect(model.activeVFO == .a)
    }

    @Test func testSelectVFOSendsFR() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.selectVFO(.b)
        #expect(sent == ["FR1;"])

        model.selectVFO(.a)
        #expect(sent == ["FR1;", "FR0;"])
    }

    @Test func testSelectVFOSameVFOSendsNothing() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.selectVFO(.a)
        #expect(sent.isEmpty)
    }

    @Test func testSetFreqTargetsActiveVFO() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.selectVFO(.b)
        model.setFreq(7074000)
        #expect(model.freqB == 7074000)
        #expect(model.freqA == 14000000)
        #expect(sent == ["FR1;", "FB00007074000;"])
    }

    @Test func testNudgeAppliesToActiveVFO() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.freqA = 14000000
        model.freqB = 7000000

        model.selectVFO(.b)
        model.nudgeFreq(100)
        #expect(model.freqB == 7000100)
        #expect(model.freqA == 14000000)
        #expect(sent == ["FR1;", "FB00007000100;"])

        model.selectVFO(.a)
        model.nudgeFreq(100)
        #expect(model.freqA == 14000100)
        #expect(model.freqB == 7000100)
        #expect(sent == ["FR1;", "FB00007000100;", "FR0;", "FA00014000100;"])
    }

    @Test func testReconnectDefaultsToVFOA() {
        let model = RemoteRigModel()
        model.selectVFO(.b)
        #expect(model.activeVFO == .b)

        model.connect()
        #expect(model.activeVFO == .a)
    }

    // MARK: TX LOCK latch

    private func stateLine(ptt: Bool) -> String {
        #"{"t":"state","state":{"freqA":14000000,"freqB":7000000,"mode":"USB","ptt":\#(ptt),"af":120,"rf":255,"power":50,"sql":0,"smeter":0,"audioOn":false,"rxPaused":false,"powerOn":true}}"#
    }

    @Test func testTXLockLatchesAndKeysPTT() {
        let model = RemoteRigModel()
        var sentPTT: [Bool] = []
        model.onSendPTT = { sentPTT.append($0) }

        model.toggleTXLock()

        #expect(model.txLock == true)
        #expect(model.ptt == true)
        #expect(sentPTT == [true])
    }

    @Test func testTXLockReleaseSendsPTTOff() {
        let model = RemoteRigModel()
        var sentPTT: [Bool] = []
        model.onSendPTT = { sentPTT.append($0) }

        model.toggleTXLock()
        model.toggleTXLock()

        #expect(model.txLock == false)
        #expect(model.ptt == false)
        #expect(sentPTT == [true, false])
    }

    @Test func testTXLockHoldsPTTTrueAcrossStateRefresh() {
        let model = RemoteRigModel()
        var sentPTT: [Bool] = []
        model.onSendPTT = { sentPTT.append($0) }

        model.toggleTXLock()
        #expect(model.ptt == true)

        // The keyed rig reports PTT on in the state refresh; the latch holds.
        model.handleLine(stateLine(ptt: true))
        #expect(model.ptt == true)
        #expect(model.txLock == true)

        // Releasing sends PTT off.
        model.toggleTXLock()
        #expect(model.txLock == false)
        #expect(model.ptt == false)
        #expect(sentPTT == [true, false])
    }

    @Test func testTXLockFollowsAckUnkey() {
        let model = RemoteRigModel()
        model.toggleTXLock()
        #expect(model.txLock == true)

        // A hold-pad release (or a foreign unkey) drops TX; the latch follows.
        model.handleLine(#"{"t":"ptt_ack","on":false}"#)

        #expect(model.ptt == false)
        #expect(model.txLock == false)
    }

    @Test func testTXLockFollowsStateUnkey() {
        let model = RemoteRigModel()
        model.toggleTXLock()
        #expect(model.txLock == true)

        model.handleLine(stateLine(ptt: false))

        #expect(model.ptt == false)
        #expect(model.txLock == false)
    }

    @Test func testTXLockDoesNotEngageOnForeignKeyUp() {
        let model = RemoteRigModel()
        model.handleLine(#"{"t":"ptt_ack","on":true}"#)

        #expect(model.ptt == true)
        #expect(model.txLock == false)
    }

    @Test func testMomentaryPadDoesNotLatch() {
        let model = RemoteRigModel()
        var sentPTT: [Bool] = []
        model.onSendPTT = { sentPTT.append($0) }

        model.setPTT(true)
        model.setPTT(false)

        #expect(model.txLock == false)
        #expect(model.ptt == false)
        #expect(sentPTT == [true, false])
    }

    @Test func testMomentaryPadInertWhileLatched() {
        let model = RemoteRigModel()
        var sentPTT: [Bool] = []
        model.onSendPTT = { sentPTT.append($0) }

        model.toggleTXLock()
        model.setPTT(true)
        model.setPTT(false)

        // The pad cannot unkey a latched TX (its key-up is dropped); the latch
        // survives until toggled.
        #expect(model.txLock == true)
        #expect(model.ptt == true)
        #expect(sentPTT == [true, true])
    }

    @Test func testDisconnectClearsTXLock() {
        let model = RemoteRigModel()
        model.toggleTXLock()
        #expect(model.txLock == true)

        model.disconnect()

        #expect(model.txLock == false)
        #expect(model.ptt == false)
    }

    @Test func testAuthOKAutoStartsAudio() {
        let model = RemoteRigModel()
        var sentAudio: [String] = []
        model.onSendAudio = { sentAudio.append($0) }

        model.handleLine(#"{"t":"auth_ok"}"#)

        #expect(model.status == "connected")
        #expect(sentAudio == ["start"])
        #expect(model.audio != nil)
    }

    @Test func testAudioStoppedTearsDownEngine() {
        let model = RemoteRigModel()
        model.setupAudioEngine()
        #expect(model.audio != nil)

        model.handleLine(#"{"t":"audio","status":"stopped"}"#)

        #expect(model.audio == nil)
        #expect(model.audioOn == false)
    }

    @Test func testDisconnectTearsDownEngine() {
        let model = RemoteRigModel()
        model.setupAudioEngine()
        #expect(model.audio != nil)

        model.disconnect()

        #expect(model.audio == nil)
        #expect(model.audioOn == false)
    }

    @Test func testAudioStoppedAfterStartedTearsDownEngine() {
        let model = RemoteRigModel()
        model.handleLine(#"{"t":"audio","status":"started"}"#)
        #expect(model.audioOn == true)
        model.setupAudioEngine()
        #expect(model.audio != nil)

        model.handleLine(#"{"t":"audio","status":"stopped"}"#)

        #expect(model.audio == nil)
        #expect(model.audioOn == false)
    }

    // MARK: Power

    @Test func testSetRigPowerOnSendsPS1() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.setRigPower(true)

        #expect(model.powerOn == true)
        #expect(sent == ["PS1;"])
    }

    @Test func testSetRigPowerOnProbesThenFetchesStateOnceReady() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }

        model.setRigPower(true)

        // No immediate refresh — the boot window is a cheap probe, not a full
        // snapshot (which would time out query-by-query while the rig boots).
        #expect(stateReqs == 0)

        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;"])

        // The rig answers the probe; now the panel can sync.
        model.handleLine(#"{"t":"cat_resp","raw":"FA00014000000;"}"#)
        #expect(stateReqs == 1)
    }

    @Test func testPowerOnProbeCancelledOnDisconnect() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }

        model.setRigPower(true)
        model.disconnect()

        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;"])
        #expect(stateReqs == 0)
    }

    private static let notReadyState = #"{"t":"state","state":{"freqA":0,"freqB":0,"mode":"","ptt":false,"af":0,"rf":0,"power":0,"sql":0,"smeter":0,"audioOn":false,"rxPaused":false,"powerOn":true}}"#

    @Test func testPowerOnProbeRetriesWhileRigBooting() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.setRigPower(true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;"])

        // The probe timed out server-side — the rig is still booting; re-probe
        // instead of hammering the full snapshot. The timeout is swallowed, so
        // the status line stays clean.
        model.handleLine(#"{"t":"error","msg":"radio: command timeout"}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;", "FA;"])
        #expect(model.status != "error: radio: command timeout")
    }

    @Test func testPowerOnSnapshotNotReadyReProbes() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }

        model.setRigPower(true)
        try await Task.sleep(for: .milliseconds(200))
        model.handleLine(#"{"t":"cat_resp","raw":"FA00014000000;"}"#)
        #expect(stateReqs == 1)

        // FA; answered but PS; did not — still booting; re-probe, don't
        // refetch the full snapshot.
        model.handleLine(#"{"t":"state","state":{"freqA":14000000,"freqB":14000000,"mode":"USB","ptt":false,"af":120,"rf":255,"power":50,"sql":0,"smeter":0,"audioOn":false,"rxPaused":false,"powerOn":false}}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;", "FA;"])
        #expect(stateReqs == 1)
    }

    @Test func testPowerOffCancelsPendingPowerOnSync() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }

        model.setRigPower(true)
        model.setRigPower(false)

        // Powered back off before the boot window elapsed: no probe, no
        // refresh, and a stale not-ready snapshot must not reopen the cycle.
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "PS0;"])
        #expect(stateReqs == 0)

        model.handleLine(Self.notReadyState)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "PS0;"])
        #expect(stateReqs == 0)
    }

    @Test func testPowerOnSyncStopsOnceRigAnswers() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }

        model.setRigPower(true)
        try await Task.sleep(for: .milliseconds(200))
        model.handleLine(#"{"t":"cat_resp","raw":"FA00014000000;"}"#)
        #expect(stateReqs == 1)

        // A real frequency and power ack mean the rig is up; the cycle ends.
        model.handleLine(#"{"t":"state","state":{"freqA":14000000,"freqB":14000000,"mode":"USB","ptt":false,"af":120,"rf":255,"power":50,"sql":0,"smeter":0,"audioOn":false,"rxPaused":false,"powerOn":true}}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;"])
        #expect(stateReqs == 1)
    }

    @Test func testPowerOnProbeGivesUpAfterExhaustion() async throws {
        let model = RemoteRigModel()
        model.powerOnBootDelay = .milliseconds(50)
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.setRigPower(true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["PS1;", "FA;"])

        // Exhaust the probe budget (maxPowerOnSyncProbes probes in total).
        for _ in 1..<RemoteRigModel.maxPowerOnSyncProbes {
            model.handleLine(#"{"t":"error","msg":"radio: command timeout"}"#)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(sent.filter { $0 == "FA;" }.count == RemoteRigModel.maxPowerOnSyncProbes)

        // Budget spent: another failure must not schedule a further probe, and
        // the user is told the rig never came up.
        model.handleLine(#"{"t":"error","msg":"radio: command timeout"}"#)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.filter { $0 == "FA;" }.count == RemoteRigModel.maxPowerOnSyncProbes)
        #expect(model.status == "power on: rig not responding")
    }

    @Test func testSetRigPowerOffSendsPS0() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        model.powerOn = true

        model.setRigPower(false)

        #expect(model.powerOn == false)
        #expect(sent == ["PS0;"])
    }

    @Test func testSetRigPowerOffSkipsStateRefresh() {
        let model = RemoteRigModel()
        var stateReqs = 0
        model.onSendStateReq = { stateReqs += 1 }
        model.powerOn = true

        model.setRigPower(false)

        #expect(stateReqs == 0)
    }

    @Test func testSetRigPowerNoopOnSameState() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        model.powerOn = true

        model.setRigPower(true)

        #expect(sent.isEmpty)
    }

    @Test func testStateReportPaintsRigPower() {
        let model = RemoteRigModel()
        model.powerOn = true
        model.handleLine(#"{"t":"state","state":{"freqA":14000000,"freqB":7000000,"mode":"USB","ptt":false,"af":120,"rf":255,"power":50,"sql":0,"smeter":0,"audioOn":false,"rxPaused":false,"powerOn":false}}"#)

        #expect(model.powerOn == false)
    }

    @Test func testStaleStatePowerOffSendsPS0() {
        // The client believes the rig is on but it was powered off at the
        // panel. The label is honest ("Power Off"), so the click still targets
        // the last-known state and a redundant PS0; is harmless.
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        model.powerOn = true

        model.setRigPower(false)

        #expect(model.powerOn == false)
        #expect(sent == ["PS0;"])
    }

    @Test func testOpusBitrateRange() {
        // The stepper works in whole kbps and must stay within the server's
        // clamp range [500, 128000] bps.
        #expect(RemoteRigModel.minOpusBitrate >= 500)
        #expect(RemoteRigModel.maxOpusBitrate == 128000)
        #expect(RemoteRigModel.minOpusBitrate % RemoteRigModel.opusBitrateStep == 0)
        #expect(RemoteRigModel.maxOpusBitrate % RemoteRigModel.opusBitrateStep == 0)

        // The default 48000 bps must be selectable in the stepper range.
        let model = RemoteRigModel()
        #expect(model.opusBitrate >= RemoteRigModel.minOpusBitrate)
        #expect(model.opusBitrate <= RemoteRigModel.maxOpusBitrate)
    }

    @Test func testBandModel() {
        #expect(Band.all.count == 12)
        #expect(Band.all[0] == Band(id: 0, label: "160 m"))
        #expect(Band.all[4] == Band(id: 4, label: "20 m"))
        #expect(Band.all[10] == Band(id: -1, label: "60 m"))
        #expect(Band.all[11] == Band(id: 10, label: "GENE"))
        #expect(Band(id: -1, label: "60 m").is60m == true)
        #expect(Band(id: 0, label: "160 m").is60m == false)
        #expect(Band(id: -1, label: "60 m").isBD == false)
        #expect(Band(id: 4, label: "20 m").isBD == true)
        #expect(Band.default60mFreq == 5_330_000)
    }

@Test func testSelectBandBD() {
        let model = RemoteRigModel()
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }
        let band = Band(id: 4, label: "20 m")

        model.selectBand(band)

        #expect(model.selectedBand == band)
        #expect(sent == ["BD04;", "FA;", "MD;"])
    }

    @Test func testSelectBandBDWithVFOB() {
        let model = RemoteRigModel()
        model.activeVFO = .b
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.selectBand(Band(id: 8, label: "10 m"))

        #expect(sent == ["BD08;", "FB;", "MD;"])
    }

    @Test func testSelectBand60m() {
        let model = RemoteRigModel()
        model.band60Freq = 5_330_500
        var sent: [String] = []
        model.onSendCat = { sent.append($0) }

        model.selectBand(Band(id: -1, label: "60 m"))

        #expect(sent.count == 2)
        #expect(sent[0].hasPrefix("FA"))
        #expect(sent[0].contains("05330500"))
        #expect(sent[1] == "MD;")
    }
}
