import AVKit
import SwiftUI

/// The "Up Next" panel the player shows near the end of an episode
/// (`AVPlayerItem.nextContentProposal`): the video keeps playing full screen while a
/// panel with the next episode's still, title and a countdown to the end of the
/// episode (when autoplay is on) offers Play / Cancel.
final class UpNextProposalViewController: AVContentProposalViewController {
    private let model: VideoPlayerModel
    private var host: UIHostingController<UpNextPanel>?

    init(model: VideoPlayerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var preferredPlayerViewFrame: CGRect {
        view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        guard let proposal = contentProposal else { return }
        let panel = UpNextPanel(
            title: proposal.title,
            overview: model.upNextOverview,
            image: proposal.previewImage,
            autoplayDate: model.upNextAutoplayDate,
            play: { [weak self] in self?.dismissContentProposal(for: .accept, animated: true, completion: nil) },
            cancel: { [weak self] in self?.dismissContentProposal(for: .reject, animated: true, completion: nil) }
        )
        let host = UIHostingController(rootView: panel)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
        model.proposalController = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if model.proposalController === self {
            model.proposalController = nil
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        host.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

private struct UpNextPanel: View {
    let title: String
    let overview: String
    let image: UIImage?
    let autoplayDate: Date?
    let play: () -> Void
    let cancel: () -> Void

    @FocusState private var focused: Choice?

    private enum Choice { case play, cancel }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55), .black.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            HStack(alignment: .bottom, spacing: 44) {
                thumbnail
                VStack(alignment: .leading, spacing: 12) {
                    Text("UP NEXT")
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .foregroundStyle(Theme.Colors.label2)
                    Text(verbatim: title)
                        .font(Theme.Typography.sectionTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(2)
                    if !overview.isEmpty {
                        Text(verbatim: overview)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                            .lineLimit(2)
                    }
                    HStack(spacing: 24) {
                        Button(action: play) {
                            Label {
                                countdownLabel
                            } icon: {
                                Image(systemName: "play.fill")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .focused($focused, equals: .play)
                        Button(action: cancel) {
                            Text("Cancel")
                        }
                        .buttonStyle(PillButtonStyle(kind: .glass))
                        .focused($focused, equals: .cancel)
                    }
                    .padding(.top, 14)
                }
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 72)
        }
        .defaultFocus($focused, .play)
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.Colors.elevated
                Image(systemName: "tv")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.Colors.label3)
            }
        }
        .frame(width: 480, height: 270)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }

    @ViewBuilder
    private var countdownLabel: some View {
        if let autoplayDate {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = Int(autoplayDate.timeIntervalSince(context.date).rounded(.up))
                if seconds > 0 {
                    Text("Play in \(seconds)")
                } else {
                    Text("Play Now")
                }
            }
        } else {
            Text("Play Now")
        }
    }
}
