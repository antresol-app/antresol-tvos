import SwiftUI

/// Brand splash: purple gradient, the Antresol mark and wordmark, and a status line.
struct SplashView: View {
    let status: LocalizedStringKey?
    let isWorking: Bool
    /// Shown as a "Try Again" button when set.
    var retry: (() -> Void)?
    /// Shown as a "Change Server" button when set.
    var changeServer: (() -> Void)?

    var body: some View {
        ZStack {
            Theme.Gradients.brand.ignoresSafeArea()
            VStack(spacing: 36) {
                HStack(spacing: 28) {
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                    Text(verbatim: "Antresol")
                        .font(.system(size: 76, weight: .bold))
                        .foregroundStyle(.white)
                }
                Group {
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                    } else if let status {
                        VStack(spacing: 40) {
                            Text(status)
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.8))
                            HStack(spacing: 28) {
                                if let retry {
                                    Button(action: retry) {
                                        Label("Try Again", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(PillButtonStyle(kind: .primary))
                                }
                                if let changeServer {
                                    Button(action: changeServer) {
                                        Label("Change Server", systemImage: "server.rack")
                                    }
                                    .buttonStyle(PillButtonStyle(kind: .glass))
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 160, alignment: .top)
            }
        }
    }
}

#Preview {
    SplashView(status: "The server is not responding", isWorking: false, retry: {}, changeServer: {})
}
