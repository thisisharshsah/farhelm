// Companion's design lives in the CompanionDesign package, shared with the
// iPhone, iPad and Watch apps. It is visible in every file of the Mac app,
// and its colors are the Mac's own Look.
@_exported import CompanionDesign
import SwiftUI

enum SharedDesign {
    /// The shared views draw in the look in effect here (the user's colors,
    /// light or dark), read each time they draw.
    static func install() {
        Design.palette = {
            Palette(isLight: Theme.isLight, ink: Theme.ink, shade: Theme.shade,
                    accent: Theme.accent, lilac: Theme.lilac, violet: Theme.violet,
                    mint: Theme.mint, amber: Theme.amber, rose: Theme.rose,
                    contentDim: Theme.look.content.dim,
                    emptyDim: Theme.look.empty.dim)
        }
    }
}
