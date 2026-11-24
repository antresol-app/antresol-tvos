import AntresolKit
import SwiftUI

/// A channel number typed as on a TV (the TV page and the live player): digits from a
/// remote or keyboard that sends them, or from the on-screen `NumberPad`. «23_» shows at
/// the top right; the number is taken `ChannelNumberEntry.timeout` after the last digit, on
/// OK / Select, or as soon as it has as many digits as the list's highest number. A number
/// no channel has shows «No channel 23» for a moment.
@MainActor
@Observable
final class ChannelNumberInput {
    /// The number being typed (nil: none).
    private(set) var entry: ChannelNumberEntry?
    /// A number just taken that no channel has.
    private(set) var missing: Int?
    /// Counts the numbers taken (the pad closes on each).
    private(set) var commits = 0

    /// Tunes to the channel of a number; false when there is none.
    @ObservationIgnored var tune: (Int) -> Bool = { _ in false }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var missingTimer: Task<Void, Never>?

    /// A digit typed; `channels` gives the most digits a number has.
    func type(_ digit: Character, channels: [Channel]) {
        var next = entry ?? ChannelNumberEntry(channels: channels)
        missing = nil
        let complete = next.append(digit)
        guard !next.isEmpty else { return }
        entry = next
        timer?.cancel()
        if complete {
            commit()
        } else {
            timer = Task { [weak self] in
                try? await Task.sleep(for: ChannelNumberEntry.timeout)
                guard !Task.isCancelled else { return }
                self?.commit()
            }
        }
    }

    /// The pad's ⌫: the last digit back; nothing left, the entry goes.
    func deleteLast() {
        guard var next = entry else { return }
        next.deleteLast()
        timer?.cancel()
        if next.isEmpty {
            entry = nil
            return
        }
        entry = next
        timer = Task { [weak self] in
            try? await Task.sleep(for: ChannelNumberEntry.timeout)
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    /// Takes the number now (OK / Select, the timeout, the last digit).
    func commit() {
        timer?.cancel()
        guard let number = entry?.number else {
            entry = nil
            return
        }
        entry = nil
        commits += 1
        guard !tune(number) else { return }
        missing = number
        missingTimer?.cancel()
        missingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.missing = nil
        }
    }

    /// Menu while typing: the number is dropped.
    func cancel() {
        timer?.cancel()
        entry = nil
    }

    var isTyping: Bool { entry != nil }
}

/// «23_» (or «No channel 23»), large, on glass at the top right of the screen.
struct ChannelNumberOverlay: View {
    let input: ChannelNumberInput

    var body: some View {
        VStack {
            HStack {
                Spacer()
                if let entry = input.entry {
                    Text(verbatim: entry.display)
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Colors.label)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 16)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
                        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous), highlighted: false, interactive: false)
                        .accessibilityLabel(Text(verbatim: String(localized: "Channel \(entry.digits)", bundle: .localized)))
                        .accessibilityIdentifier("channel.number")
                } else if let missing = input.missing {
                    Text(verbatim: String(localized: "No channel \(String(missing))", bundle: .localized))
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 22)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
                        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous), highlighted: false, interactive: false)
                        .accessibilityIdentifier("channel.number.missing")
                }
            }
            Spacer()
        }
        .padding(.top, 60)
        .padding(.trailing, Theme.Layout.margin)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(Theme.Motion.easeOut, value: input.entry)
        .animation(Theme.Motion.easeOut, value: input.missing)
    }
}

/// The on-screen number pad, for a remote without digits (the Siri Remote): 1–9, then ⌫, 0
/// and OK, as a phone's keypad. Each key adds to the number shown at the top right; OK (or
/// the pause after the last digit) tunes in and closes the pad; Menu closes it, the number
/// dropped. Digits a keyboard types count too.
struct NumberPad: View {
    let input: ChannelNumberInput
    let channels: [Channel]
    let close: () -> Void

    @FocusState private var focused: String?

    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["delete", "0", "ok"]]
    private static let key: CGFloat = 112

    var body: some View {
        VStack(spacing: 28) {
            Text("Channel Number")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 24) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { key in
                            button(key)
                        }
                    }
                }
            }
            .focusSection()
        }
        .padding(48)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous))
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous), highlighted: false, interactive: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.black.opacity(0.55).ignoresSafeArea()
        }
        .overlay { ChannelNumberOverlay(input: input) }
        .defaultFocus($focused, "1")
        .onAppear { focused = "1" }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let digit = ChannelNumberEntry.digit(in: press.characters) else { return .ignored }
            type(digit)
            return .handled
        }
        .onExitCommand {
            input.cancel()
            close()
        }
        // a number was taken (OK, the pause, the last digit): the pad's work is done
        .onChange(of: input.commits) { close() }
    }

    private func type(_ digit: Character) {
        input.type(digit, channels: channels)
    }

    @ViewBuilder
    private func button(_ key: String) -> some View {
        Button {
            switch key {
            case "delete": input.deleteLast()
            case "ok":
                if input.isTyping { input.commit() } else { close() }
            default: if let digit = key.first { type(digit) }
            }
        } label: {
            switch key {
            case "delete": RoundGlyph("Erase", systemImage: "delete.left")
            case "ok": RoundGlyph("OK", systemImage: "checkmark")
            default: Label { Text(verbatim: key) } icon: { Text(verbatim: key).monospacedDigit() }
            }
        }
        .buttonStyle(CircleButtonStyle(diameter: Self.key, isActive: false))
        .focused($focused, equals: key)
        .accessibilityIdentifier("numberpad.\(key)")
    }
}
