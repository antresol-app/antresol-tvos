import AntresolKit
import SwiftUI

/// A profile avatar: the first letter of the name on the profile's `grad-N` gradient.
struct AvatarView: View {
    let name: String
    let preset: AvatarPreset
    var size: CGFloat = 120

    var body: some View {
        Circle()
            .fill(Theme.Gradients.avatar(preset))
            .overlay {
                Text(initial)
                    .font(Theme.Typography.avatarInitial(size: size))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

extension AvatarView {
    init(profile: Profile, size: CGFloat = 120) {
        self.init(name: profile.name, preset: profile.avatarPreset, size: size)
    }

    init(user: User, size: CGFloat = 120) {
        self.init(name: user.name, preset: user.avatarPreset, size: size)
    }
}

#Preview {
    HStack(spacing: 40) {
        ForEach(AvatarPreset.allCases, id: \.self) { preset in
            AvatarView(name: preset.rawValue.dropFirst(5).description, preset: preset)
        }
    }
}
