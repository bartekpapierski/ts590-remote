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

    @Test func testColumnMapping() {
        #expect(FrequencyView.column(at: 0) == 0)
        #expect(FrequencyView.column(at: 1) == 1)
        #expect(FrequencyView.column(at: 2) == nil)   // '.'
        #expect(FrequencyView.column(at: 3) == 2)
        #expect(FrequencyView.column(at: 4) == 3)
        #expect(FrequencyView.column(at: 5) == 4)
        #expect(FrequencyView.column(at: 6) == nil)   // '.'
        #expect(FrequencyView.column(at: 7) == 5)
        #expect(FrequencyView.column(at: 8) == 6)
        #expect(FrequencyView.column(at: 9) == 7)
        #expect(FrequencyView.column(at: -1) == nil)
        #expect(FrequencyView.column(at: 10) == nil)
    }

    @Test func testPlaceValues() {
        #expect(FrequencyView.placeValue(for: 0) == 10_000_000)
        #expect(FrequencyView.placeValue(for: 1) == 1_000_000)
        #expect(FrequencyView.placeValue(for: 2) == 100_000)
        #expect(FrequencyView.placeValue(for: 3) == 10_000)
        #expect(FrequencyView.placeValue(for: 4) == 1_000)
        #expect(FrequencyView.placeValue(for: 5) == 100)
        #expect(FrequencyView.placeValue(for: 6) == 10)
        #expect(FrequencyView.placeValue(for: 7) == 1)
        #expect(FrequencyView.placeValue(for: -1) == 1)
        #expect(FrequencyView.placeValue(for: 8) == 1)
    }

    @Test func testScrollStep() {
        // A selected column overrides the step buttons.
        #expect(FrequencyView.scrollStep(deltaY: 1, column: 5, fallback: 1000) == 100)
        #expect(FrequencyView.scrollStep(deltaY: -1, column: 5, fallback: 1000) == -100)
        #expect(FrequencyView.scrollStep(deltaY: 1, column: 0, fallback: 100) == 10_000_000)
        // No column selected: the step-button step applies.
        #expect(FrequencyView.scrollStep(deltaY: 1, column: nil, fallback: 1000) == 1000)
        #expect(FrequencyView.scrollStep(deltaY: -1, column: nil, fallback: 1000) == -1000)
        // Fallback clamped to at least 1 Hz.
        #expect(FrequencyView.scrollStep(deltaY: -1, column: nil, fallback: 0) == -1)
        // A zero-delta scroll event nudges nothing.
        #expect(FrequencyView.scrollStep(deltaY: 0, column: 5, fallback: 1000) == 0)
    }

    @Test func testReadoutCells() {
        let cells = FrequencyView.readoutCells(for: 14000001)
        #expect(cells.count == 10)
        #expect(cells.map { $0.column } == [0, 1, nil, 2, 3, 4, nil, 5, 6, 7])
        #expect(cells.map { String($0.character) }.joined() == "14.000.001")
        #expect(cells.map { $0.id } == Array(0..<10))
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
