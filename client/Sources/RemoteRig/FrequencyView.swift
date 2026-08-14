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

    override var acceptsFirstResponder: Bool { true }
}

// The VFO readout, grouped to the kHz and MHz, readable to 1 Hz. Scroll to
// tune at the current step; a dashed readout means the rig is unreachable.
struct FrequencyView: View {
    @EnvironmentObject var model: RemoteRigModel

    var body: some View {
        VStack(spacing: 4) {
            Text(formatted)
                .font(.system(size: 46, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(model.connected ? Theme.readout : Theme.dim)
                .frame(minWidth: 300, minHeight: 56)
                .overlay(ScrollWheelView { dy in
                    let step = max(model.stepHz, 1)
                    model.nudgeFreq(dy > 0 ? step : -step)
                })
                .help("Scroll to tune. Step: \(model.stepHz) Hz")
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
        }
    }

    private var formatted: String {
        guard model.connected else { return "–.---.---" }
        return Self.formatFreq(max(model.activeFreq, 0))
    }

    static func formatFreq(_ freq: Int64) -> String {
        let mhz = freq / 1_000_000
        let rem = freq % 1_000_000
        let khz = rem / 1000
        let hz = rem % 1000
        return String(format: "%02d.%03d.%03d", mhz, khz, hz)
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
