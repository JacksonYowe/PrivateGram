import SwiftUI

struct SettingsView: View {
    @State var shieldsEnabled: Bool
    let onShieldsChange: (Bool) -> Void
    let onClearCache: (@escaping () -> Void) -> Void
    let onWipe: () -> Void
    let onHome: () -> Void
    let onLoginLink: (URL) -> Void

    @State private var confirmWipe = false
    @State private var cacheCleared = false
    @State private var loginText = ""
    @State private var loginError = false

    private func signIn() {
        guard let url = Privacy.loginLink(from: loginText) else { loginError = true; return }
        loginError = false
        onLoginLink(url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste the log-in link from the email", text: $loginText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                    HStack {
                        // Apple's paste button: reads the clipboard only when you tap it, with no prompt.
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { loginText = first; signIn() }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        Spacer()
                        Button("Sign In", action: signIn)
                            .disabled(loginText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Sign in with email link")
                } footer: {
                    Text(loginError
                         ? "That isn't an Instagram link. Copy the log-in link from Instagram's email and try again."
                         : "In Instagram's \"log in\" email, press and hold the button or link, tap Copy Link, then paste it here. You'll be signed in inside this app, not in Safari.")
                        .foregroundStyle(loginError ? .red : .secondary)
                }

                Section {
                    Toggle("Block trackers & logging", isOn: $shieldsEnabled)
                        .onChange(of: shieldsEnabled) { _, value in onShieldsChange(value) }
                } footer: {
                    Text("Blocks every outside tracker, plus Instagram's own activity-logging. Only turn off if something on Instagram stops working.")
                }

                Section("Always on") {
                    Label("Shows Instagram a desktop Safari browser, not your phone model", systemImage: "theatermasks")
                    Label("No advertising ID, no device ID, no analytics", systemImage: "person.crop.circle.badge.xmark")
                    Label("Location, camera, mic & motion sensors blocked for the website", systemImage: "location.slash")
                    Label("Outside links open in your browser, tracking stripped", systemImage: "link")
                    Label("Data sealed in this app, never shared with Safari", systemImage: "lock.shield")
                    Label("Screen hidden in the app switcher", systemImage: "eye.slash")
                }
                .font(.subheadline)

                Section {
                    Button("Back to Home Feed", action: onHome)
                    Button(cacheCleared ? "Cache cleared" : "Clear cache (stay signed in)") {
                        onClearCache { cacheCleared = true }
                    }
                    .disabled(cacheCleared)
                    Button("Erase everything from this app", role: .destructive) { confirmWipe = true }
                }
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Erase all cookies, logins and cached data from this app? You'll need to log in again. (To also end the session on Instagram's side, use Log out inside Instagram first.)",
                                isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive, action: onWipe)
            }
        }
    }
}
