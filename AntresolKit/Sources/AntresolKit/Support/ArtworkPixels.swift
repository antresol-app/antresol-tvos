import Foundation

/// How many pixels a piece of artwork is decoded to, on its longest side.
public enum ArtworkPixels {
    /// A picture as wide as the screen (1920 points) is decoded 1920 pixels wide whatever
    /// the scale: every pixel of a 1080p screen, half of a 4K screen's (a full 4K decode
    /// is 33 MB a picture, and the backdrops are dimmed or masked).
    public static let screenWidth: Double = 1920

    /// - Parameters:
    ///   - maxAt2x: the longest side in pixels of a 2x screen (Apple TV 4K): twice the
    ///     points the picture is drawn across, or less for a picture that large that it
    ///     is given fewer pixels than the 4K screen has (`screenWidth`).
    ///   - floor: the fewest pixels at any scale. A picture given less than twice its
    ///     points passes the points it is drawn across, so that a 1x screen (1080p) still
    ///     gets a pixel for each of its own.
    ///   - scale: the screen's scale (1 at 1080p, 2 at 4K).
    public static func longestSide(maxAt2x: Double, atLeast floor: Double = 0, scale: Double) -> Double {
        max((maxAt2x * scale / 2).rounded(.up), floor.rounded(.up))
    }
}
