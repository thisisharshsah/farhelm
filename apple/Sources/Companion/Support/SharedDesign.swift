// Companion's design lives in the CompanionDesign package, shared with the
// iPhone, iPad and Watch apps. It is visible in every file of the Mac app,
// and its colors are the Mac's own Look.
@_exported import CompanionDesign
import SwiftUI

enum SharedDesign {
    /// The palette as last worked out from the look. Shared views ask for
    /// it for every color they draw, many times a frame, so it is built
    /// once and kept until `refresh()` (the look, the appearance or the
    /// system's light or dark changed; `Theme.refresh()` calls it).
    private static var cached: Palette?

    static func refresh() {
        cached = nil
    }

    /// The shared views draw in the look in effect here (the user's colors,
    /// light or dark).
    static func install() {
        Design.palette = {
            if let cached { return cached }
            let fresh = Palette(isLight: Theme.isLight, ink: Theme.ink, shade: Theme.shade,
                                accent: Theme.accent, lilac: Theme.lilac, violet: Theme.violet,
                                mint: Theme.mint, amber: Theme.amber, rose: Theme.rose,
                                contentDim: Theme.look.content.dim,
                                emptyDim: Theme.look.empty.dim)
            cached = fresh
            return fresh
        }
    }
}
