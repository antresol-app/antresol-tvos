import UIKit

/// Renders side-loaded subtitle cues above the video and below the transport bar
/// (it lives in `AVPlayerViewController.contentOverlayView`), in the viewer's caption
/// style (`CaptionStyle`).
final class SubtitleOverlayView: UIView {
    private let label = UILabel()
    private let plate = UIView()
    private var style = CaptionStyle.current
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
                label.attributedText = styled(text)
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

        plate.backgroundColor = style.plateColor
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
        NotificationCenter.default.addObserver(self, selector: #selector(captionSettingsChanged), name: CaptionStyle.didChange, object: nil)
    }

    @objc private func captionSettingsChanged() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            style = .current
            plate.backgroundColor = style.plateColor
            if let text, !text.isEmpty { label.attributedText = styled(text) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func styled(_ text: String) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: style.fontSize, weight: .semibold),
            .foregroundColor: style.textColor,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
    }
}
