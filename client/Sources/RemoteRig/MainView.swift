import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var model: RemoteRigModel
    @State private var showSettings = false
    @State private var showAdvanced = false
    @State private var pressing = false

    private let modes = ["LSB", "USB", "CW", "FM", "AM", "FSK", "CW-R", "USER"]
    private let steps: [Int64] = [1, 10, 100, 1000]

    var body: some View {
        VStack(spacing: 0) {
            instrumentCluster
            Divider().overlay(Theme.panelEdge)
            controlsZone
            Spacer(minLength: 0)
            Divider().overlay(Theme.panelEdge)
            statusBar
        }
        .background(Theme.background)
        .frame(minWidth: 460, minHeight: 620)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showAdvanced) { AdvancedView().environmentObject(model) }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            installSpacePTT()
        }
    }

    // MARK: instrument cluster — the "flying" state the operator watches.

    private var instrumentCluster: some View {
        VStack(spacing: 14) {
            FrequencyView()

            HStack(spacing: 10) {
                Picker("VFO", selection: Binding(
                    get: { model.activeVFO },
                    set: { model.selectVFO($0) })) {
                    Text("A").tag(VFO.a)
                    Text("B").tag(VFO.b)
                }
                .pickerStyle(.segmented)
                .frame(width: 88)
                .disabled(!model.connected)

                ForEach(steps, id: \.self) { s in
                    Button(stepLabel(s)) { model.stepHz = s }
                        .buttonStyle(.bordered)
                        .tint(model.stepHz == s ? Theme.meter : .primary)
                }
                Spacer(minLength: 0)
                Text("STEP")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.dim)
            }

            Picker("Mode", selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) })) {
                ForEach(modes, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!model.connected)

            sMeter

            if model.ptt {
                Text("TX")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Theme.tx)
                    .cornerRadius(6)
            }
        }
        .padding(20)
    }

    // Segmented S-meter: 0–255 maps to discrete lit segments.
    private var sMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("S").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Theme.dim)
                Spacer()
                Text("S-meter").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(Theme.dim)
            }
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { i in
                    Capsule()
                        .fill(i < litSegments ? Theme.meter : Theme.panel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }
        }
        .disabled(!model.connected)
    }

    private var litSegments: Int { Self.litSegments(model.smeter) }

    static func litSegments(_ value: Int) -> Int {
        Int(round(Double(min(max(value, 0), 255)) / 255.0 * 20))
    }

    // MARK: controls zone — PTT and set-once adjustments.

    private var controlsZone: some View {
        VStack(spacing: 16) {
            pttRow

            DisclosureGroup {
                VStack(spacing: 10) {
                    labeledSlider("RF", value: model.rf, range: 0...255, set: model.setRF)
                    labeledSlider("PWR", value: model.power, range: 0...100, set: model.setPower)
                    labeledSlider("SQL", value: model.sql, range: 0...255, set: model.setSQL)
                    labeledSlider("AF", value: model.af, range: 0...255, set: model.setAF)
                    Divider().overlay(Theme.panelEdge)
                    powerRow
                }
                .padding(.top, 8)
            } label: {
                Label("Levels", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.dim)
            }
            .disabled(!model.connected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var pttRow: some View {
        HStack(spacing: 12) {
            // PTT — hold to talk (spacebar works too).
            Button(action: {}) {
                Text(model.ptt ? "TX — transmitting" : "HOLD TO TALK")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .background(model.ptt ? Theme.tx : (pressing ? Theme.warn : Theme.panel))
            .cornerRadius(8)
            .gesture(LongPressGesture(minimumDuration: 0.01)
                .onChanged { _ in pressing = true; model.setPTT(true) }
                .onEnded { _ in pressing = false; model.setPTT(false) })
            .disabled(!model.connected)

            // TX lock — latch the transmitter on until released (or the rig
            // reports it dropped TX). Separate from the momentary hold pad.
            Button("TX LOCK") { model.toggleTXLock() }
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(model.txLock ? Theme.warn : Theme.dim)
                .buttonStyle(.bordered)
                .tint(model.txLock ? Theme.warn : .primary)
                .frame(width: 88)
                .disabled(!model.connected)
        }
    }

    private var powerRow: some View {
        Button(action: { model.togglePower() }) {
            HStack {
                Text("Power supply")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Circle()
                    .fill(model.powerOn ? Theme.ok : Theme.dim)
                    .frame(width: 8, height: 8)
                Text(model.powerOn ? "ON" : "OFF")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(model.powerOn ? Theme.ok : Theme.dim)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: status / action bar.

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button(model.connected ? "Disconnect" : "Connect") {
                if model.connected { model.disconnect() } else { model.connect() }
            }
            .buttonStyle(.bordered)
            .tint(model.connected ? Theme.tx : Theme.meter)

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(model.status)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button(model.audioOn ? "Stop Audio" : "Start Audio") { model.toggleAudio() }
                .buttonStyle(.bordered)
                .disabled(!model.connected)
            Button(model.rxPaused ? "Resume Incoming" : "Pause Incoming") { model.toggleRxPause() }
                .buttonStyle(.bordered)
                .disabled(!model.audioOn)

            Button("Settings") { showSettings = true }
                .buttonStyle(.bordered)
            Button("Advanced / CAT") { showAdvanced = true }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bar)
    }

    private var statusColor: Color {
        let s = model.status
        if s.hasPrefix("error") || s.contains("fail") { return .red }
        return model.connected ? Theme.ok : Theme.dim
    }

    private func stepLabel(_ s: Int64) -> String {
        s >= 1000 ? String(format: "%gk", s / 1000) : "\(s)"
    }

    private static var spacePTTInstalled = false
    private func installSpacePTT() {
        guard !Self.spacePTTInstalled else { return }
        Self.spacePTTInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak model] ev in
            guard ev.keyCode == 49 else { return ev }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSText || responder is NSTextView {
                return ev
            }
            if ev.type == .keyDown { model?.setPTT(true) } else { model?.setPTT(false) }
            return nil
        }
    }

    private func labeledSlider(_ title: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 36, alignment: .leading)
                .foregroundColor(Theme.dim)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
                .tint(Theme.meter)
            Text("\(value)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
                .foregroundColor(Theme.readout)
        }
    }
}
