# Companion design

This folder keeps Companion's design: the design system every screen takes its look from (tokens, glass surfaces and size rules), and the orbit mark.

## The design system

The code is in `Sources/Companion/UI/Design/`:

- `Tokens.swift`: spacing, corners, type, colors, control and icon sizes, motion and the accessibility settings. Plain SwiftUI that extends the shared `Design` enum, so it can move into `Shared/CompanionDesign` unchanged when the iPhone, iPad and Watch apps want it.
- `GlassSurfaces.swift`: the glass modifiers (floating panel, toolbar group, section header, buttons, morph).
- `SizeRules.swift`: width classes, densities, the adaptive stack and the readable column.
- `DesignGallery.swift`: the Design Gallery.
- `Theme.swift`: the look's own colors (`Theme.accent`, `Theme.ink` and the rest) and the older components, which later tasks move onto the tokens screen by screen.

The shared package (`Shared/CompanionDesign`) keeps the palette, `liquidGlass`, `GlassGroup` and the base corner values; the tokens point at those rather than copying them.

### Design Gallery

Every token and component, in light and dark at the three widths, with Reduce Transparency, Increase Contrast and Reduce Motion to preview (the system's own settings apply as well), and a pill that morphs into a panel.

- Debug > Design Gallery, in the app's menus (shown with Settings > Look > "Show in menu bar").
- Or launch it alone, without the panel: `dist/Companion.app/Contents/MacOS/Companion --design-gallery`.

### Tokens

| Token | Values |
| --- | --- |
| Spacing, `Design.Space` | `xxs` 4, `xs` 8, `s` 12, `m` 16, `l` 20, `xl` 24, `xxl` 32 |
| Corners, `Design.Radius` | `chip` 6, `control` 8, `tile` 12, `card` 14, `panel` 20, continuous curve; a shape inside another takes `Radius.concentric(outer, inset:)` |
| Type, `Design.TextRole` with `.textRole(_:_:)` | large title, title, heading, body, label, caption (the system text styles), code (monospaced), number (monospaced digits) |
| Text levels, `Design.TextLevel` | primary, secondary, tertiary (hierarchical styles; Increase Contrast moves each up one) |
| Colors, `Design.Tone` | accent (the look's main color), neutral, positive, caution, critical, info (system colors) |
| Fills, `Design.Fill` | content, raised, line (system backgrounds, for the content layer) |
| Controls, `Design.Control` | small 22, regular 28, large 36 points high, each with its SwiftUI `ControlSize` |
| Icons, `Design.Icon` with `.iconWidth(_:)` | small 14, regular 18, large 24 points wide, so labels after them line up |
| Motion, `Design.Motion` with `.designAnimation(_:value:)` | quick, standard, gentle, morph springs; a 0.2 second fade under Reduce Motion |

### Width classes and density

| Class | Width | Layout |
| --- | --- | --- |
| Compact | under 600 points | one column; an `AdaptiveStack` is always a column |
| Regular | 600 to 999 points | rows where they fit |
| Wide | 1000 points and more | rows; running text stays in a `ReadableColumn` (680 points) |

A window's content calls `.readsWidthClass()` once; everything inside reads `@Environment(\.widthClass)`. `@Environment(\.density)` is compact (dense lists, side panels) or regular, and gives row height, gap, inset, control and icon size. `AdaptiveStack` also turns into a column at any width where its row does not fit.

### Glass

- Glass belongs to the navigation and control layer: sidebars, toolbars, floating panels, menus and buttons. Never put it behind messages, code or documents; those sit on `Design.Fill`.
- No glass on glass. A glass surface inside another draws flat by itself (`insideGlass`); do not stack them by hand.
- Prefer native containers: `NavigationSplitView`, `toolbar`, `inspector`, `Form`, `Menu`, `Picker`. They take on Liquid Glass by themselves; custom chrome is for what they cannot do.
- Use the modifiers: `.glassPanel()`, `.glassToolbarGroup()`, `GlassSectionHeader`, `.glassButton(.glass)` and `.glassButton(.prominent)` (one prominent button per group), and `.glassMorph(_:in:)` inside a `GlassGroup`. On macOS 26 and later they are Liquid Glass (`glassEffect`, `GlassEffectContainer`, `glassEffectID`, `buttonStyle(.glass)`, `.glassProminent`); on macOS 14 and 15 they are system materials.
- Text on glass is primary or secondary (`.textRole(_:_:)`), never a fixed color.
- Accessibility: Reduce Transparency turns every surface solid with an edge, Increase Contrast gives it a firm edge and stronger text, Reduce Motion turns morphs and springs into fades.
- No literal colors, font sizes or spacing outside the design system: use the tokens, or add one here first.

## The orbit mark

The mark is a ball of orbit lines around a soft source of light.

## Files

- `orbit-preview.html`: the live design reference. Open it in a browser. It draws the mark moving, the three states of the floating circle, the orbit shown while the agent works (click, type, open), and the app icon at three sizes. The shade swatches show it in other looks.
- `AppIcon-1024.png`: the app icon as exported from the preview (an 824 px tile centered on a 1024 px canvas, as macOS expects).
- `../Resources/AppIcon.icns`: the same icon in every size, bundled into the app by `build.sh`.

## Where it lives in the app

- `Sources/Companion/UI/Orbit.swift`: `OrbitMark` draws the mark in SwiftUI (the same geometry as the preview). `AgentOrbit` is the small window that shows it where the agent acts.
- `Sources/Companion/UI/IndicatorView.swift`: the floating circle.
- Settings > Agent > "Show the orbit while it works" turns the agent's orbit off.

## The design, in numbers

- Lines: full circles around the centre, each at its own tilt and facing. 13 in the large mark, 9 in the icon, 7 in the floating circle, 8 for a click or an open, 5 while typing.
- The ball turns slowly and leans a little; the near half of each line is bright and thick, the far half faint and thin. On dark glass, crossing lines brighten each other.
- Moving circles: each picks a line, a direction and a speed at random, and picks again every 2.5 to 7 seconds. 3 when idle, 4 while listening, 7 while working.
- The source: a soft glow in the look's own colors with a slightly lighter heart, beating gently. It feeds every moving circle through a thin beam with two pulses of light travelling out along it, and sends a faint wave out to the lines.
- Colors: the look's main and partner colors (Settings > Look), plus mint on every third line.
- The agent's orbit: about a second on a click or an open; while typing it is small and rides the caret until the last letter is in.
- Background: the app icon is the only place the mark has one. There it sits on a deep glass tile lit from above, with the look's colors glowing behind the ball, a fine bezel around it and a light rim on the top edge (corner radius 22.5% of the tile). Everywhere inside the app (the floating circle, the empty chat, the agent's orbit) the mark is drawn bare, with nothing behind it.

## Changing it

1. Edit `orbit-preview.html` until it looks right (everything is in the one file; `mark()` draws the ball, `tile()` the icon).
2. Carry the change into `OrbitMark` in `Orbit.swift`, which mirrors `mark()`.
3. For the icon, export the `#icon` canvas at 824 px, center it on a 1024 px transparent canvas, and rebuild `AppIcon.icns` from it.
