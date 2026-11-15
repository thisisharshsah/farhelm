# Companion design: the orbit mark

The mark is a ball of orbit lines around a soft source of light. This folder keeps the design so it can be looked at, changed and re-exported later.

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
