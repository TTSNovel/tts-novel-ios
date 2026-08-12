import SwiftUI

/// Presented as a sheet from ReaderSettingsSheet, not the app's root screen
/// — login is optional (see WebnovelReaderApp: guest mode reads the public
/// catalog without ever needing this), reached only when the user actually
/// wants an account (online voices, cross-device progress sync).
/// Auto-dismisses itself on a successful login via the onChange below,
/// same "just close after the thing you opened it for happens" pattern as
/// BugReportView's success alert.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var isPresented: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Tài khoản") {
                    TextField("Tài khoản", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("usernameField")
                    SecureField("Mật khẩu", text: $password)
                        .accessibilityIdentifier("passwordField")
                }
                if let error = session.loginError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Section {
                    Button {
                        Task {
                            isLoggingIn = true
                            await session.login(username: username, password: password)
                            isLoggingIn = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingIn { ProgressView() } else { Text("Đăng nhập") }
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isLoggingIn)
                    .accessibilityIdentifier("loginButton")
                } footer: {
                    Text("Chỉ cần đăng nhập nếu bạn muốn nghe giọng đọc online hoặc đồng bộ tiến độ đọc giữa các thiết bị — duyệt và đọc sách không cần đăng nhập.")
                }
            }
            .navigationTitle("Đăng nhập")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { isPresented = false }
                }
            }
        }
        .onChange(of: session.isLoggedIn) { _, loggedIn in
            if loggedIn { isPresented = false }
        }
    }
}

#Preview {
    LoginView(isPresented: .constant(true)).environmentObject(SessionStore.shared)
}
