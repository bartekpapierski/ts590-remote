import SwiftUI

struct AdvancedView: View {
    @EnvironmentObject var model: RemoteRigModel
    @Environment(\.dismiss) private var dismiss
    @State private var cmd = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("CAT command (e.g. FA00014000000;)", text: $cmd)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    model.sendCat(cmd)
                    cmd = ""
                }
                .disabled(cmd.isEmpty)
            }
            Divider()
            Text("Rig events").font(.caption.bold())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, e in
                        Text(e)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 440)
    }
}
