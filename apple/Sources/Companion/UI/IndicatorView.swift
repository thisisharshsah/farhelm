import SwiftUI

/// The small glass circle that sits below the camera. Pulses while listening,
/// shows a dot when a suggestion is waiting and the panel is hidden.
/// Click to expand or collapse the main panel, drag to move it.
struct IndicatorView: View {
    @EnvironmentObject var app: AppState

    private var working: Bool { app.isReplying || app.isAnsweringScreen }

    var body: some View {
        ZStack {
            if app.isListening {
                PulseRing(color: Theme.accent)
            }
            VisualEffectView(material: .hudWindow)
                .clipShape(Circle())
                .overlay(
                    // Inner light so the glass reads as a lens.
                    Circle().fill(
                        RadialGradient(colors: [.white.opacity(0.16), .clear],
                                       center: .topLeading, startRadius: 0, endRadius: 40)
                    )
                )
                .overlay(ring)
                .overlay(
                    Image(systemName: Theme.iconSymbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(app.isListening
                                         ? AnyShapeStyle(Theme.accentGradient)
                                         : AnyShapeStyle(Color.white.opacity(0.88)))
                        .symbolEffect(.pulse, isActive: working)
                )
                .frame(width: 52, height: 52)

            if !app.panelVisible && app.hasUnseen {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: 19, y: -19)
            }
        }
        .frame(width: 72, height: 72)
        // The window handles clicks (toggle panel) and drags (move); SwiftUI
        // must not intercept the mouse.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var ring: some View {
        if app.isListening {
            Circle().strokeBorder(
                AngularGradient(colors: [Theme.accent, Theme.violet, Theme.mint, Theme.accent],
                                center: .center),
                lineWidth: 1.5
            )
        } else {
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
    }
}
