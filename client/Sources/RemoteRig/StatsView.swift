import SwiftUI

// StatsView is a compact, toggleable telemetry panel: link/network conditions
// on top, then the downlink (RX) and uplink (TX-to-rig) jitter buffers.
struct StatsView: View {
    @EnvironmentObject var model: RemoteRigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Network")
            HStack(spacing: 24) {
                stat("Link", model.connected ? "up" : "down",
                     color: model.connected ? Theme.ok : .red)
                stat("RTT", model.rttMs.map { "\($0) ms" } ?? "—")
                stat("Audio", audioLabel)
            }
            HStack(spacing: 24) {
                stat("Downlink", "\(model.downlinkPackets) pkts")
                stat("Bytes", "\(model.downlinkBytes)")
                stat("Uplink", "\(model.uplinkPackets) pkts")
            }

            Divider().overlay(Theme.panelEdge)

            header("Downlink buffer (RX)")
            HStack(spacing: 24) {
                metric("Depth", "\(model.downlinkStats?.depth ?? 0) f")
                metric("Fill", "\(model.downlinkStats?.fill ?? 0) f")
                metric("Drop", "\(model.downlinkStats?.dropouts ?? 0)")
                metric("Skip", "\(model.downlinkStats?.skips ?? 0)")
                metric("Late", "\(model.downlinkStats?.late ?? 0)")
            }

            if let s = model.serverStats {
                Divider().overlay(Theme.panelEdge)
                header("Uplink buffer (TX to rig)")
                HStack(spacing: 24) {
                    metric("Depth", "\(s.depth) f")
                    metric("Fill", "\(s.fill) f")
                    metric("Drop", "\(s.dropouts)")
                    metric("Skip", "\(s.skips)")
                    metric("Late", "\(s.late)")
                }
            }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bar)
    }

    private var audioLabel: String {
        if !model.audioOn { return "off" }
        return model.rxPaused ? "paused" : "running"
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(Theme.dim)
    }

    private func stat(_ label: String, _ value: String, color: Color = Theme.readout) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(Theme.dim)
            Text(value).foregroundColor(color)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(Theme.dim)
            Text(value)
        }
    }
}
