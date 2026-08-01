import SwiftUI
import CoreAudio

struct SettingsView: View {
    @EnvironmentObject var model: RemoteRigModel
    @Environment(\.dismiss) private var dismiss
    @State private var audioInput: [AudioDevices.Device] = AudioDevices.inputDevices
    @State private var audioOutput: [AudioDevices.Device] = AudioDevices.outputDevices
    @FocusState private var hostFocused: Bool

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .focused($hostFocused)
                    .onAppear { hostFocused = true }
                Stepper("Port \(model.port)", value: $model.port, in: 1...65535)
                SecureField("Pre-shared key", text: $model.psk)
                    .textFieldStyle(.roundedBorder)
            }
            Section("Audio devices (local)") {
                Picker("Input (microphone)", selection: $model.inputDeviceID) {
                    Text("Default").tag(0)
                    ForEach(audioInput, id: \.id) { d in
                        Text(d.name).tag(Int(d.id))
                    }
                }
                Picker("Output (speakers)", selection: $model.outputDeviceID) {
                    Text("Default").tag(0)
                    ForEach(audioOutput, id: \.id) { d in
                        Text(d.name).tag(Int(d.id))
                    }
                }
            }
            Section("Opus audio parameters") {
                Picker("Sample rate", selection: $model.opusSampleRate) {
                    ForEach([8000, 12000, 16000, 24000, 48000], id: \.self) {
                        Text("\($0) Hz").tag($0)
                    }
                }
                Picker("Channels", selection: $model.opusChannels) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }
                Picker("Frame size", selection: $model.opusFrameMs) {
                    Text("5 ms").tag(5)
                    Text("10 ms").tag(10)
                    Text("20 ms").tag(20)
                    Text("40 ms").tag(40)
                    Text("60 ms").tag(60)
                }
                Stepper(
                    "Bitrate: \(model.opusBitrate / 1000) kbps",
                    value: $model.opusBitrate,
                    in: RemoteRigModel.minOpusBitrate...RemoteRigModel.maxOpusBitrate,
                    step: RemoteRigModel.opusBitrateStep
                )
            }
            Section {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            audioInput = AudioDevices.inputDevices
            audioOutput = AudioDevices.outputDevices
            model.validateDeviceIDs(input: audioInput, output: audioOutput)
        }
        .frame(minWidth: 440, minHeight: 340)
    }
}
