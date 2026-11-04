import SwiftUI

/// Brand splash: purple gradient, the Antresol mark and wordmark, and a status line.
struct SplashView: View {
    let status: LocalizedStringKey?
    let isWorking: Bool
    /// Shown as a "Try Again" button when set.
    var retry: (() -> Void)?

    var body: some View {
        ZStack {
            Theme.Gradients.brand.ignoresSafeArea()
            VStack(spacing: 36) {
                HStack(spacing: 28) {
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                    Text("Antresol")
                        .font(.system(size: 76, weight: .bold))
                        .foregroundStyle(.white)
                }
                Group {
                    if isWorking {
                        ProgressView()
                            .tint(.white)
                    } else if let status {
                        VStack(spacing: 28) {
                            Text(status)
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.8))
                            if let retry {
                                Button("Try Again", action: retry)
                            }
                        }
                    }
                }
                .frame(minHeight: 120, alignment: .top)
            }
        }
    }
}

#Preview {
    SplashView(status: "The server is not responding", isWorking: false) {}
}
