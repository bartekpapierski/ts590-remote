import Foundation
import Testing
@testable import RemoteRig

@MainActor
struct RemoteRigModelTests {

    @Test func testModeName() {
        let model = RemoteRigModel()
        #expect(model.modeName(0) == "LSB")
        #expect(model.modeName(1) == "USB")
        #expect(model.modeName(2) == "CW")
        #expect(model.modeName(3) == "FM")
        #expect(model.modeName(4) == "AM")
        #expect(model.modeName(5) == "FSK")
        #expect(model.modeName(6) == "CW-R")
        #expect(model.modeName(7) == "USER")
        #expect(model.modeName(8) == nil)
        #expect(model.modeName(-1) == nil)
    }

    @Test func testModeDigit() {
        let model = RemoteRigModel()
        #expect(model.modeDigit("LSB") == "0")
        #expect(model.modeDigit("USB") == "1")
        #expect(model.modeDigit("CW") == "2")
        #expect(model.modeDigit("FM") == "3")
        #expect(model.modeDigit("AM") == "4")
        #expect(model.modeDigit("FSK") == "5")
        #expect(model.modeDigit("CW-R") == "6")
        #expect(model.modeDigit("USER") == "7")
        #expect(model.modeDigit("UNKNOWN") == "1")
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
        model.applyEvent("MD1;")
        #expect(model.mode == "USB")

        model.applyEvent("MD0;")
        #expect(model.mode == "LSB")

        model.applyEvent("MD3;")
        #expect(model.mode == "FM")
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
}
