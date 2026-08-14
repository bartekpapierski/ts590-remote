import Foundation
import Testing
@testable import RemoteRig

struct LayoutTests {

    @Test func testFormatFreqFullHz() {
        #expect(FrequencyView.formatFreq(14000000) == "14.000.000")
        #expect(FrequencyView.formatFreq(14000001) == "14.000.001")
        #expect(FrequencyView.formatFreq(0) == "00.000.000")
        #expect(FrequencyView.formatFreq(7000000) == "07.000.000")
        #expect(FrequencyView.formatFreq(14195000) == "14.195.000")
        #expect(FrequencyView.formatFreq(1_800_000) == "01.800.000")
    }

    @Test func testFormatFreqFullPrecision() {
        // The old `%02d.%03d.%02d` format dropped the last digit; the 1 Hz
        // readout must round-trip the full VFO resolution.
        #expect(FrequencyView.formatFreq(14000000 + 1) == "14.000.001")
        #expect(FrequencyView.formatFreq(14000000 + 9) == "14.000.009")
        #expect(FrequencyView.formatFreq(14000000 + 10) == "14.000.010")
    }

    @Test func testBandName() {
        #expect(FrequencyView.bandName(1_800_000) == "160 m")
        #expect(FrequencyView.bandName(3_600_000) == "80 m")
        #expect(FrequencyView.bandName(7_100_000) == "40 m")
        #expect(FrequencyView.bandName(14_100_000) == "20 m")
        #expect(FrequencyView.bandName(21_200_000) == "15 m")
        #expect(FrequencyView.bandName(28_500_000) == "10 m")
        #expect(FrequencyView.bandName(50_100_000) == "6 m")
    }

    @Test func testBandNameOutsideHamBands() {
        #expect(FrequencyView.bandName(100_000) == "0 MHz")
        #expect(FrequencyView.bandName(144_000_000) == "144 MHz")
    }

    @Test func testSMeterSegments() {
        #expect(MainView.litSegments(0) == 0)
        #expect(MainView.litSegments(255) == 20)
        #expect(MainView.litSegments(128) == 10)
        #expect(MainView.litSegments(-10) == 0)
        #expect(MainView.litSegments(300) == 20)
        // ~half scale
        let mid = MainView.litSegments(255 / 2)
        #expect(mid >= 9 && mid <= 11)
    }
}
