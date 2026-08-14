import Foundation
import Testing
@testable import RemoteRig

struct ProtocolTests {

    @Test func testParseValidMessage() {
        let json = #"{"t":"auth","token":"change-me"}"#
        let msg = Msg.parse(json)
        #expect(msg != nil)
        #expect(msg?.t == "auth")
        #expect(msg?.token == "change-me")
    }

    @Test func testParseMessageWithOpusParams() {
        let json = #"{"t":"audio","action":"start","opus":{"sampleRate":48000,"channels":1,"frameMs":20,"bitrate":48000}}"#
        let msg = Msg.parse(json)
        #expect(msg != nil)
        #expect(msg?.t == "audio")
        #expect(msg?.action == "start")
        #expect(msg?.opus?.sampleRate == 48000)
        #expect(msg?.opus?.channels == 1)
        #expect(msg?.opus?.frameMs == 20)
        #expect(msg?.opus?.bitrate == 48000)
    }

    @Test func testParseMessageWithPTT() {
        let json = #"{"t":"ptt","on":true}"#
        let msg = Msg.parse(json)
        #expect(msg != nil)
        #expect(msg?.t == "ptt")
        #expect(msg?.on == true)
    }

    @Test func testParseMessageWithAudioParams() {
        let json = #"{"t":"audio_params","sampleRate":16000,"channels":2,"frameMs":10,"bitrate":32000,"adjusted":true}"#
        let msg = Msg.parse(json)
        #expect(msg != nil)
        #expect(msg?.t == "audio_params")
        #expect(msg?.sampleRate == 16000)
        #expect(msg?.channels == 2)
        #expect(msg?.frameMs == 10)
        #expect(msg?.bitrate == 32000)
        #expect(msg?.adjusted == true)
    }

    @Test func testParseInvalidJSON() {
        let msg = Msg.parse("not json")
        #expect(msg == nil)
    }

    @Test func testParseEmptyString() {
        let msg = Msg.parse("")
        #expect(msg == nil)
    }

    @Test func testJsonLineEncoding() {
        let msg = Msg(t: "auth", token: "my-secret")
        let data = msg.jsonLine()
        let str = String(data: data, encoding: .utf8)
        #expect(str != nil)
        #expect(str?.hasSuffix("\n") == true)

        let line = str?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Msg.parse(line ?? "")
        #expect(parsed != nil)
        #expect(parsed?.t == "auth")
        #expect(parsed?.token == "my-secret")
    }

    @Test func testOpusParamsEquality() {
        let p1 = OpusParams(sampleRate: 48000, channels: 1, frameMs: 20, bitrate: 48000)
        let p2 = OpusParams(sampleRate: 48000, channels: 1, frameMs: 20, bitrate: 48000)
        #expect(p1 == p2)

        let p3 = OpusParams(sampleRate: 16000, channels: 1, frameMs: 20, bitrate: 48000)
        #expect(p1 != p3)
    }

    @Test func testParseStatsMessage() {
        let json = #"{"t":"stats","stats":{"depth":3,"minDepth":1,"maxDepth":64,"dropouts":7,"skips":2,"late":1,"fill":1,"occupancy":2}}"#
        let msg = Msg.parse(json)
        #expect(msg != nil)
        #expect(msg?.t == "stats")
        #expect(msg?.stats?.depth == 3)
        #expect(msg?.stats?.dropouts == 7)
        #expect(msg?.stats?.skips == 2)
        #expect(msg?.stats?.fill == 1)
        #expect(msg?.stats?.occupancy == 2)
    }

    @Test func testRigStateDefaults() {
        let state = RigState()
        #expect(state.freqA == 0)
        #expect(state.freqB == 0)
        #expect(state.mode == "")
        #expect(state.ptt == false)
        #expect(state.powerOn == false)
        #expect(state.audioOn == false)
    }
}