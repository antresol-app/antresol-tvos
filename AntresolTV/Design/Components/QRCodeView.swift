import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code of `text` (CoreImage's generator), black modules on a white plate with the
/// quiet zone around them, drawn pixel-sharp at any size.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 520

    var body: some View {
        Group {
            if let image = QRCodeImage.make(text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.Colors.qrModule)
                    .padding(size * 0.2)
            }
        }
        .padding(size * 0.07)
        .frame(width: size, height: size)
        .background(Theme.Colors.qrBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .accessibilityElement()
        .accessibilityLabel(Text("QR code"))
    }
}

enum QRCodeImage {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// One pixel per module (scaled up without smoothing when drawn); medium error
    /// correction, which a phone across the room reads easily.
    static func make(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
