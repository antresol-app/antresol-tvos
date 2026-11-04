import UIKit

/// Renders side-loaded subtitle cues above the video and below the transport bar
/// (it lives in `AVPlayerViewController.contentOverlayView`).
final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private let plate = UIView()
    private var bottomConstraint: NSLayoutConstraint?

    /// Lifts the subtitles above the transport bar while it is shown.
    var raised = false {
        didSet {
            guard raised != oldValue else { return }
            bottomConstraint?.constant = raised ? -260 : -96
            UIView.animate(withDuration: 0.25) { self.layoutIfNeeded() }
        }
    }

    var text: String? {
        didSet {
            guard text != oldValue else { return }
            if let text, !text.isEmpty {
                label.attributedText = Self.styled(text)
                plate.isHidden = false
            } else {
                label.attributedText = nil
                plate.isHidden = true
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        plate.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        plate.layer.cornerRadius = 10
        plate.layer.cornerCurve = .continuous
        plate.isHidden = true
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)

        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(label)

        let bottom = plate.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -96)
        bottomConstraint = bottom
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottom,
            plate.widthAnchor.constraint(lessThanOrEqualToConstant: 1500),
            label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -22),
            label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func styled(_ text: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
    }
}
