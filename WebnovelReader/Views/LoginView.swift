import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

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
                }
            }
            .navigationTitle("Novel Reader")
        }
    }
}

#Preview {
    LoginView().environmentObject(SessionStore.shared)
}
