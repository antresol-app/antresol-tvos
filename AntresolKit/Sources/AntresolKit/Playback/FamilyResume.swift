import Foundation

/// What a start may offer of the other profiles.
public enum FamilyOffer: Equatable, Sendable {
    /// No prompt for other profiles: where to start was chosen already (a family jump from the title
    /// page, «from the beginning», the next episode that follows by itself, a kid's profile).
    case none
    /// Profiles with a place in the very film or episode that starts: the viewer picked it (an
    /// episode from the list, a film).
    case sameItem
    /// Also the profiles in other episodes of the series: the app picked the episode (the series'
    /// Play / Continue), so where the others are is worth offering.
    case series
}

/// «Дарья · 1:12:40» on the resume prompt: when a film or an episode starts and another profile has
/// a place in it (or, for a series, in another episode), the prompt offers that place beside this
/// profile's own. This says who is offered and when the prompt is shown at all; the words and the
/// adopt call are the app's.
public enum FamilyResume {
    /// A place counts as another one when it is further than this from this profile's own.
    public static let differsMs = 2 * 60_000
    /// Rows of other profiles on the prompt.
    public static let maxRows = 3
    /// An own position shorter than this is no progress (the start of the file).
    public static let ownMinimumSec: Double = 5

    /// Whether `member`'s place is worth offering when `itemId` is about to play and this profile is
    /// at `ownMs` in it (0 for no progress): started, not finished, not a «next episode» entry, and
    /// either in another episode or more than two minutes from this profile's place.
    public static func qualifies(_ member: FamilyMember, playing itemId: Int, ownMs: Int) -> Bool {
        guard !member.finished, !member.next, member.positionMs > 0 else { return false }
        if member.itemId != itemId { return true }
        return abs(member.positionMs - max(0, ownMs)) > differsMs
    }

    /// The places to offer: those that qualify (and, for `.sameItem`, are in this very item), the most
    /// recently watched first (a profile whose time is unknown goes last), at most `maxRows`.
    public static func offers(_ members: [FamilyMember], playing itemId: Int, ownMs: Int, scope: FamilyOffer = .series) -> [FamilyMember] {
        guard scope != .none else { return [] }
        let found = members.enumerated().filter {
            qualifies($0.element, playing: itemId, ownMs: ownMs) && (scope == .series || $0.element.itemId == itemId)
        }
        let sorted = found.sorted { lhs, rhs in
            switch (lhs.element.updatedAt, rhs.element.updatedAt) {
            case let (a?, b?) where a != b: return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }
        return Array(sorted.prefix(maxRows).map(\.element))
    }

    /// What a start may offer. `requested` is what the caller says (a family jump or the episode that
    /// follows by itself: `.none`; the series' Play / Continue: `.series`; anything else `.sameItem`).
    /// Never for a kid, never for a start from the beginning (the viewer chose the place), and a series'
    /// or season's card is resolved to an episode by the app, so it offers the whole series.
    public static func scope(requested: FamilyOffer, fromBeginning: Bool, cardIsSeries: Bool, kid: Bool) -> FamilyOffer {
        guard !kid, !fromBeginning, requested != .none else { return .none }
        return requested == .series || cardIsSeries ? .series : .sameItem
    }

    /// Whether this profile has a place of its own to resume from (`ownSec` is the start the saved
    /// progress gives: 0 for none or a finished one).
    public static func hasOwnPlace(_ ownSec: Double) -> Bool { ownSec >= ownMinimumSec }

    /// Whether the prompt is shown: «Continue watching» (`asksForOwn`) with a place of its own, as
    /// before, or whenever somebody else's place is offered. Nothing else changes: with no offers a
    /// start that does not ask goes straight on.
    public static func showsPrompt(asksForOwn: Bool, ownSec: Double, offers: [FamilyMember]) -> Bool {
        (asksForOwn && hasOwnPlace(ownSec)) || !offers.isEmpty
    }

    /// The item to ask `GET /api/items/{id}/family` about when `itemId` (of `kind`, in the series
    /// `seriesId`) is about to play: for `.series` an episode asks about the series, which also places the
    /// profiles in its other episodes; otherwise the item itself (an episode's own list names everyone
    /// who has progress in it).
    public static func askedItem(itemId: Int, kind: ItemKind, seriesId: Int?, scope: FamilyOffer = .series) -> Int {
        kind == .episode && scope == .series ? (seriesId ?? itemId) : itemId
    }
}
