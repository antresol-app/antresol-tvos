import Observation
import SwiftUI

/// Puts a tab back in its first state a while after the user leaves it: its navigation
/// stack popped to the root, its page rebuilt (scrolled to the top, focus on its first
/// element). Coming back within `delay` was an accidental switch and keeps everything.
/// Only a tab that was moved from its first state (a page pushed, a list scrolled) is
/// reset, so an untouched tab does not reload for nothing.
@MainActor
@Observable
final class TabResetCoordinator {
    /// How long a left tab keeps its state.
    nonisolated static let delay: Duration = .seconds(5)

    private var paths: [ShellTab: NavigationPath] = [:]
    private var generations: [ShellTab: Int] = [:]
    @ObservationIgnored private var scrolled: Set<ShellTab> = []
    @ObservationIgnored private var timers: [ShellTab: Task<Void, Never>] = [:]
    @ObservationIgnored private let delay: Duration

    /// UI tests may stretch the delay with `-AntresolTabResetSeconds <n>`.
    init(delay: Duration = TabResetCoordinator.delay) {
        let override = UserDefaults.standard.double(forKey: "AntresolTabResetSeconds")
        self.delay = override > 0 ? .seconds(override) : delay
    }

    /// The tab's navigation path, for its `NavigationStack`.
    func path(for tab: ShellTab) -> Binding<NavigationPath> {
        Binding(
            get: { self.paths[tab] ?? NavigationPath() },
            set: { self.paths[tab] = $0 }
        )
    }

    /// Replaces a tab's stack (a deep link opening a page on Home).
    func setPath(_ path: NavigationPath, for tab: ShellTab) {
        paths[tab] = path
    }

    /// Changes when the tab is reset; its root view is identified by it.
    func generation(of tab: ShellTab) -> Int {
        generations[tab] ?? 0
    }

    /// The tab's page or one of its rows was scrolled away from its start. It stays marked
    /// until the tab is reset: focus may still sit deep in a row scrolled back.
    func markScrolled(_ tab: ShellTab) {
        scrolled.insert(tab)
    }

    /// The selection moved from `old` to `new`.
    func selectionChanged(from old: ShellTab, to new: ShellTab) {
        timers[new]?.cancel()
        timers[new] = nil
        guard old != new, needsReset(old) else { return }
        timers[old]?.cancel()
        timers[old] = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reset(old)
        }
    }

    private func needsReset(_ tab: ShellTab) -> Bool {
        switch tab {
        case .nowPlaying:
            return false
        case .account:
            // Settings pages are pushed by its own stack; rebuilding it is cheap (no loads).
            return true
        default:
            return !(paths[tab]?.isEmpty ?? true) || scrolled.contains(tab)
        }
    }

    private func reset(_ tab: ShellTab) {
        timers[tab] = nil
        paths[tab] = NavigationPath()
        scrolled.remove(tab)
        generations[tab, default: 0] += 1
    }
}

extension EnvironmentValues {
    /// The tab a view is in, for reporting its scroll state to the shell's reset.
    @Entry var shellTab: ShellTab?
    @Entry var tabReset: TabResetCoordinator?
}

extension View {
    /// Tells the shell when this scroll view (a tab's root page or one of its rows) moves
    /// away from its start, so the tab is reset after the user leaves it (tvOS 18 and
    /// later; earlier systems reset a tab only when a page was pushed).
    func reportsTabScroll(_ axis: Axis = .vertical) -> some View {
        modifier(TabScrollReporter(axis: axis))
    }
}

private struct TabScrollReporter: ViewModifier {
    let axis: Axis
    @Environment(\.shellTab) private var tab
    @Environment(\.tabReset) private var coordinator

    /// Focus moves pages a little (a lifted card); more than this counts as scrolled.
    private static let threshold: CGFloat = 60

    func body(content: Content) -> some View {
        if #available(tvOS 18.0, *), let tab, let coordinator {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                let offset = axis == .vertical
                    ? geometry.contentOffset.y + geometry.contentInsets.top
                    : geometry.contentOffset.x + geometry.contentInsets.leading
                return offset > Self.threshold
            } action: { _, isScrolled in
                if isScrolled { coordinator.markScrolled(tab) }
            }
        } else {
            content
        }
    }
}
