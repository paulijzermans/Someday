import SwiftUI

/// Central catalogue of the animations Someday uses for tile transitions,
/// active-state toggles, and quick taps. Naming the springs by purpose
/// (rather than burying the magic numbers at call sites) means we can
/// retune the feel of the whole app from one place.
enum SomedayAnimations {

    // MARK: - Tile-level

    /// Standard "tile appears / dismisses" spring. Used by every floating
    /// glass tile in the map (Lists, Activity, Add, Feedback, …) and the
    /// matching fade of the search button + profile avatar.
    static let tile: Animation = SomedayAnimations.tile

    /// Slightly snappier spring for navigation within a tile (back chevron
    /// in Activity, expand chevron toggling in event rows, etc.).
    static let inTileNav: Animation = SomedayAnimations.inTileNav

    // MARK: - Tab bar / chip toggles

    /// Active-state pulse on the bottom tab bar buttons and similar small
    /// chip toggles — a bit faster so the button feels responsive.
    static let chipToggle: Animation = SomedayAnimations.chipToggle

    /// Press-feedback scale on tap. Very quick so it feels like a haptic.
    static let pressFeedback: Animation = SomedayAnimations.pressFeedback

    // MARK: - Misc

    /// Small spring used for the friend-filter banner and category chip
    /// toggles inside the Feedback tile.
    static let chipPick: Animation = SomedayAnimations.chipPick

    /// Longer spring used for the followers/follow CTA in the Activity feed.
    static let followCTA: Animation = .spring(response: 0.3)
}
