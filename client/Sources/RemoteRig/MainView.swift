import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var model: RemoteRigModel
    @State private var showSettings = false
    @State private var showAdvanced = false
    @State private var pressing = false

    private let modes = ["LSB", "USB", "CW", "FM", "AM", "FSK", "CW-R", "USER"]
    private let steps: [Int64] = [1, 10, 100, 1000]

    private var statusColor: Color {
        let s = model.status
        if s.hasPrefix("error") || s.contains("fail") { return .red }
        return model.connected ? .green : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.status).foregroundColor(statusColor)
                Spacer()
                Button(model.connected ? "Disconnect" : "Connect") {
                    if model.connected { model.disconnect() } else { model.connect() }
                }
            }

            FrequencyView()

            HStack(spacing: 8) {
                ForEach(steps, id: \.self) { s in
                    Button("\(s)") { model.stepHz = s }
                        .buttonStyle(.bordered)
                        .background(model.stepHz == s ? Color.accentColor : Color.clear)
                }
                Spacer()
            }

            Picker("Mode", selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) })) {
                ForEach(modes, id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            // PTT (hold to talk)
            Button(action: {}) {
                Text(model.ptt ? "TX (transmitting)" : "Push To Talk")
                    .frame(width: 360, height: 36)
            }
            .background(model.ptt ? Color.red : (pressing ? Color.orange : Color.gray))
            .gesture(LongPressGesture(minimumDuration: 0.01)
                .onChanged { _ in pressing = true; model.setPTT(true) }
                .onEnded { _ in pressing = false; model.setPTT(false) })

            // Radio power supply (PS)
            Button(action: { model.togglePower() }) {
                Text(model.powerOn ? "Power: ON" : "Power: OFF")
                    .frame(width: 360, height: 32)
            }
            .background(model.powerOn ? Color.green : Color.gray)
            .disabled(!model.connected)

            VStack(alignment: .leading) {
                Text("S-meter").font(.caption)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.gray.opacity(0.3))
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: geo.size.width * CGFloat(min(max(model.smeter, 0), 255)) / 255)
                    }
                    .frame(height: 10)
                    .cornerRadius(3)
                }
            }
            .frame(width: 360)

            GroupBox("Levels") {
                labeledSlider("RF", value: model.rf, range: 0...255, set: model.setRF)
                labeledSlider("PWR", value: model.power, range: 0...100, set: model.setPower)
                labeledSlider("SQL", value: model.sql, range: 0...255, set: model.setSQL)
            }

            HStack(spacing: 12) {
                Button(model.audioOn ? "Stop Audio" : "Start Audio") { model.toggleAudio() }
                Button(model.rxPaused ? "Resume Incoming" : "Pause Incoming") { model.toggleRxPause() }
                    .disabled(!model.audioOn)
            }

            HStack {
                Button("Settings") { showSettings = true }
                Button("Advanced / CAT") { showAdvanced = true }
                Spacer()
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 640)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showAdvanced) { AdvancedView().environmentObject(model) }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            installSpacePTT()
        }
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
        HStack {
            Text(title).frame(width: 40)
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(value)").frame(width: 40)
        }
    }
}

struct GroupBox<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
    }
}
