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
