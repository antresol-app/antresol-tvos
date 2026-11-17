import Foundation

/// A list asked one of its rows to take focus, and repeats the request after a pause in
/// case it was lost. Whether a repeat may still be made:
public enum FocusFallback {
    /// - Parameters:
    ///   - rowHasFocus: a row of the list has focus (the asked one, or the viewer is on
    ///     another already).
    ///   - placeAtRequest: where focus was when the row was asked to take it.
    ///   - placeNow: where focus is now.
    /// Only while focus is still where it was: anywhere else, the viewer moved it there
    /// (the page's header, the sidebar), and it is not pulled back.
    public static func mayAssign<Place: Equatable>(rowHasFocus: Bool, placeAtRequest: Place?, placeNow: Place?) -> Bool {
        !rowHasFocus && placeAtRequest == placeNow
    }
}
