import AntresolKit
import SwiftUI
import UIKit

/// A profile avatar: the profile's photo when it has one, over the first letter of the name
/// on the profile's `grad-N` gradient, which shows while the photo loads, when it fails and
/// when there is none. The photo comes through `ImagePipeline` (memory and disk cache); its
/// address carries the upload's version, so a changed photo is a new address.
struct AvatarView: View {
    let name: String
    let preset: AvatarPreset
    /// The profile's `photo` field; "" draws the letter only.
    var photo: String = ""
    var size: CGFloat = 120
    /// An already loaded photo, for a picture drawn off screen (`ImageRenderer` has no
    /// environment to load `photo` with).
    var loadedPhoto: UIImage?

    var body: some View {
        Circle()
            .fill(Theme.Gradients.avatar(preset))
            .overlay {
                Text(initial)
                    .font(Theme.Typography.avatarInitial(size: size))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
            .overlay {
                if let loadedPhoto {
                    Image(uiImage: loadedPhoto)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if !photo.isEmpty {
                    RemoteImage(path: photo, maxPixelSize: size * 2)
                }
            }
            .clipShape(Circle())
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

extension AvatarView {
    init(profile: Profile, size: CGFloat = 120) {
        self.init(name: profile.name, preset: profile.avatarPreset, photo: profile.photo, size: size)
    }

    init(user: User, size: CGFloat = 120) {
        self.init(name: user.name, preset: user.avatarPreset, photo: user.photo, size: size)
    }
}

#Preview {
    HStack(spacing: 40) {
        ForEach(AvatarPreset.allCases, id: \.self) { preset in
            AvatarView(name: preset.rawValue.dropFirst(5).description, preset: preset)
        }
    }
}
