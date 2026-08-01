import Foundation

struct OpusParams: Codable, Equatable {
    var sampleRate: Int
    var channels: Int
    var frameMs: Int
    var bitrate: Int
}

struct RadioState: Codable {
    var freqA: Int64 = 0
    var freqB: Int64 = 0
    var mode: String = ""
    var ptt: Bool = false
    var af: Int = 0
    var rf: Int = 0
    var power: Int = 0
    var sql: Int = 0
    var smeter: Int = 0
    var audioOn: Bool = false
    var rxPaused: Bool = false
    var powerOn: Bool = false
}

struct Msg: Codable {
    var t: String
    var token: String? = nil
    var cmd: String? = nil
    var raw: String? = nil
    var state: RadioState? = nil
    var action: String? = nil
    var opus: OpusParams? = nil
    var status: String? = nil
    var dir: String? = nil
    var adjusted: Bool? = nil
    var on: Bool? = nil
    var stateReq: Bool? = nil
    var sampleRate: Int? = nil
    var channels: Int? = nil
    var frameMs: Int? = nil
    var bitrate: Int? = nil
    var msg: String? = nil

    func jsonLine() -> Data {
        let d = try! JSONEncoder().encode(self)
        return d + Data([10])
    }

    static func parse(_ line: String) -> Msg? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Msg.self, from: d)
    }
}
