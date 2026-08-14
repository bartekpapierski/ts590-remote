import SwiftUI
import AppKit

// Overlay view that forwards scroll-wheel events to the model so the
// operator can tune the VFO by scrolling over the frequency readout.
struct ScrollWheelView: NSViewRepresentable {
    var onWheel: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelNSView { WheelNSView() }

    func updateNSView(_ nsView: WheelNSView, context: Context) {
        nsView.onWheel = onWheel
    }
}

final class WheelNSView: NSView {
    var onWheel: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onWheel?(event.deltaY)
    }

    // The overlay must not swallow clicks: forward mouse events up the
    // responder chain so the digit columns' onTapGesture still fire.
    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }

    override var acceptsFirstResponder: Bool { true }
}

// One character of the readout. Digits carry the column they sit in
// (0 = most significant, 7 = 1 Hz); group separators have a nil column.
struct ReadoutCell: Identifiable {
    let index: Int
    let column: Int?
    let character: Character
    var id: Int { index }
}

// The VFO readout, grouped to the kHz and MHz, readable to 1 Hz. Click a digit
// column to select it; scroll then tunes in that column's place value,
// overriding the step buttons while selected. A dashed readout means the rig
// is unreachable.
struct FrequencyView: View {
    @EnvironmentObject var model: RemoteRigModel
    @State private var selectedColumn: Int?

    // Place value in Hz of each digit column, most significant first.
    private static let placeValues: [Int64] = [10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1]

    var body: some View {
        VStack(spacing: 4) {
            readout
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
        }
    }

    private var readout: some View {
        VStack(spacing: 0) {
            if model.connected {
                digitCells
            } else {
                Text("–.---.---")
            }
        }
        .font(.system(size: 46, weight: .regular, design: .monospaced))
        .monospacedDigit()
        .foregroundColor(model.connected ? Theme.readout : Theme.dim)
        .frame(minWidth: 300, minHeight: 56)
        .overlay(ScrollWheelView { dy in
            guard model.connected else { return }
            model.nudgeFreq(Self.scrollStep(deltaY: dy, column: selectedColumn, fallback: model.stepHz))
        })
        .help(scrollHelp)
    }

    private var digitCells: some View {
        HStack(spacing: 0) {
            ForEach(Self.readoutCells(for: model.activeFreq)) { cell in
                if let col = cell.column {
                    Text(String(cell.character))
                        .frame(width: 30, height: 56)
                        .background(selectedColumn == col ? Theme.meter.opacity(0.22) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedColumn = (selectedColumn == col) ? nil : col
                        }
                } else {
                    Text(String(cell.character))
                        .frame(height: 56)
                }
            }
        }
    }

    private var scrollHelp: String {
        if let col = selectedColumn {
            return "Scroll to tune \(Self.placeValue(for: col)) Hz. Click the digit again to clear."
        }
        return "Scroll to tune. Step: \(model.stepHz) Hz. Click a digit to tune its column."
    }

    static func formatFreq(_ freq: Int64) -> String {
        let mhz = freq / 1_000_000
        let rem = freq % 1_000_000
        let khz = rem / 1000
        let hz = rem % 1000
        return String(format: "%02d.%03d.%03d", mhz, khz, hz)
    }

    // Build the readout's characters with their digit columns from a frequency.
    static func readoutCells(for freq: Int64) -> [ReadoutCell] {
        formatFreq(max(freq, 0)).enumerated().map { i, ch in
            ReadoutCell(index: i, column: column(at: i), character: ch)
        }
    }

    // Column of the character at `index` in the "xx.xxx.xxx" readout, or nil
    // for a group separator ('.' at index 2 and 6).
    static func column(at index: Int) -> Int? {
        switch index {
        case 0...1: return index
        case 2, 6: return nil
        case 3...5: return index - 1
        case 7...9: return index - 2
        default: return nil
        }
    }

    // Tuning step in Hz for a digit column; out-of-range columns fall back to
    // the 1 Hz column so the nudge stays sane.
    static func placeValue(for column: Int) -> Int64 {
        guard placeValues.indices.contains(column) else { return 1 }
        return placeValues[column]
    }

    // Nudge for a scroll tick: the selected column's place value when a column
    // is active, otherwise the step-button step (clamped to at least 1 Hz).
    static func scrollStep(deltaY: CGFloat, column: Int?, fallback: Int64) -> Int64 {
        guard deltaY != 0 else { return 0 }
        let step = column.map { placeValue(for: $0) } ?? max(fallback, 1)
        return deltaY > 0 ? step : -step
    }

    // Caption line: band + active VFO (A/B).
    private var caption: String {
        guard model.connected else { return "disconnected" }
        let band = Self.bandName(model.activeFreq)
        let label = model.activeVFO == .a ? "VFO A" : "VFO B"
        return "\(band) · \(label)"
    }

    static func bandName(_ freq: Int64) -> String {
        switch freq {
        case 1_800_000..<2_000_000: return "160 m"
        case 3_500_000..<4_000_000: return "80 m"
        case 5_300_000..<5_400_000: return "60 m"
        case 7_000_000..<7_300_000: return "40 m"
        case 10_100_000..<10_150_000: return "30 m"
        case 14_000_000..<14_350_000: return "20 m"
        case 18_068_000..<18_168_000: return "17 m"
        case 21_000_000..<21_450_000: return "15 m"
        case 24_890_000..<24_990_000: return "12 m"
        case 28_000_000..<29_700_000: return "10 m"
        case 50_000_000..<54_000_000: return "6 m"
        default: return String(format: "%.0f MHz", Double(freq) / 1_000_000)
        }
    }
}
