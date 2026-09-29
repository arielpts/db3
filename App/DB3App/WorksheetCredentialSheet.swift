import SwiftUI

struct WorksheetCredentialSheet: View {
    let model: WorkbenchModel
    let request: WorksheetCredentialRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to \(request.profile.name)").font(.title2.bold()).lineLimit(2)
            Text("\(request.profile.username) · \(request.profile.database) · \(request.profile.host):\(request.profile.port)")
                .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            Text("Keychain couldn’t read the saved password. Enter it to connect.")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).focused($passwordFocused)
            Text("This password is used only for this connection. It won’t be saved to Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    password = ""
                    model.dismissWorksheetCredentialRequest(request.id)
                }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    let value = password; password = ""
                    model.submitWorksheetPassword(value, for: request.id)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { passwordFocused = true }
        .onDisappear { password = "" }
    }
}
