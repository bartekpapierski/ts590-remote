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

struct FrequencyView: View {
    @EnvironmentObject var model: RemoteRigModel

    var body: some View {
        Text(formatted)
            .font(.system(size: 46, weight: .regular, design: .monospaced))
            .frame(minWidth: 240, minHeight: 56)
            .overlay(ScrollWheelView { dy in
                let step = max(model.stepHz, 1)
                model.nudgeFreq(dy > 0 ? step : -step)
            })
            .help("Scroll to tune. Step: \(model.stepHz) Hz")
    }

    private var formatted: String {
        let f = model.freqA
        let mhz = f / 1_000_000
        let rem = f % 1_000_000
        let khz = rem / 1000
        let hz = rem % 1000
        return String(format: "%02d.%03d.%02d", mhz, khz, hz)
    }
}
