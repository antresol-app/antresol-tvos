import AntresolKit
import SwiftUI

/// «Family» opened from a title's page: everyone else's place in it, newest first, and where they
/// have one to continue from, a row that takes their position as this profile's own and plays
/// from it. Menu closes it.
struct FamilySheetView: View {
    let title: String
    let line: FamilyLine
    /// Takes the member's position as this profile's own and starts playing there. Throws when
    /// the server refuses: the sheet stays and says so.
    let jump: (FamilyMember) async throws -> Void

    @Environment(AppState.self) private var appState
    @State private var busy: Int?
    @State private var failure: String?
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: title)
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(2)
                Text("Family")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
            }
            rows
            if let failure {
                Text(verbatim: failure)
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.red)
                    .padding(.horizontal, Theme.Layout.listRowInset)
                    .accessibilityIdentifier("family.failure")
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background.ignoresSafeArea())
    }

    private var rows: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(line.members) { member in
                    row(member)
                }
            }
            .padding(.horizontal, Theme.Layout.listRowInset)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .listRowOutdent()
        .disabled(busy != nil)
        .overlay {
            if busy != nil {
                ProgressView()
                    .padding(36)
                    .glassSurface(in: Circle(), highlighted: false, interactive: false)
            }
        }
        // the newest profile with something to continue from starts focused
        .defaultFocus($focused, line.members.first { $0.jump(line.kind) != .none }?.userId)
    }

    @ViewBuilder
    private func row(_ member: FamilyMember) -> some View {
        let jump = member.jump(line.kind)
        if jump == .none {
            // finished (or not started with nothing to take): there is nothing to continue, so it is not a button
            FamilyRowLabel(member: member, kind: line.kind, jump: jump)
                .padding(.horizontal, Theme.Layout.listRowInset)
                .frame(minHeight: 84)
                .accessibilityIdentifier("family.row.\(member.userId)")
        } else {
            Button {
                start(member)
            } label: {
                FamilyRowLabel(member: member, kind: line.kind, jump: jump)
            }
            .buttonStyle(ListRowButtonStyle())
            .focused($focused, equals: member.userId)
            .accessibilityIdentifier("family.row.\(member.userId)")
        }
    }

    private func start(_ member: FamilyMember) {
        guard busy == nil else { return }
        busy = member.userId
        failure = nil
        Task {
            do {
                try await jump(member)
            } catch {
                failure = appState.message(for: error) ?? String(localized: "Something went wrong. Try again.", bundle: .localized)
            }
            busy = nil
        }
    }
}

/// One profile: its avatar in the ring, name, where it is and when, and what continuing says.
private struct FamilyRowLabel: View {
    let member: FamilyMember
    let kind: FamilyKind
    let jump: FamilyJump

    var body: some View {
        HStack(spacing: 28) {
            FamilyAvatar(member: member, size: 72)
            // Names and places wrap instead of being cut; the button keeps its natural width.
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: member.listName)
                    .font(Theme.Typography.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: FamilyText.placeAndWhen(member, kind: kind))
                    .font(Theme.Typography.cardMeta)
                    .opacity(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 40)
            if jump != .none {
                Label(FamilyText.jump(jump), systemImage: "play.fill")
                    .font(Theme.Typography.meta)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
