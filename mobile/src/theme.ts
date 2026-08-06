/**
 * Tokens, mirroring `web/src/styles.css`.
 *
 * Duplicated rather than shared because there is nothing to share: CSS custom
 * properties and React Native's style objects have no common representation, and
 * a generator for eleven colours would be more machinery than the colours. What
 * matters is that the *values* match, so a session that is `awaiting_approval`
 * is the same amber on both — the status ramp is checked against the palette
 * validator once and used verbatim in both places.
 */

export interface Palette {
  bg: string;
  surface1: string;
  surface2: string;
  border: string;
  gridline: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
  series1: string;
  good: string;
  warning: string;
  serious: string;
  critical: string;
}

export const light: Palette = {
  bg: "#f7f7f8",
  surface1: "#ffffff",
  surface2: "#eeeef1",
  border: "#dcdce1",
  gridline: "#e8e8ec",
  textPrimary: "#16161a",
  textSecondary: "#4a4a55",
  textMuted: "#75757f",
  series1: "#2f6fd0",
  good: "#1f7a4d",
  warning: "#8a6100",
  serious: "#a2480d",
  critical: "#b3261e",
};

export const dark: Palette = {
  bg: "#131316",
  surface1: "#1c1c20",
  surface2: "#26262c",
  border: "#33333b",
  gridline: "#2b2b32",
  textPrimary: "#f2f2f5",
  textSecondary: "#c0c0cb",
  textMuted: "#8e8e9b",
  series1: "#7fa9ec",
  good: "#5fc492",
  warning: "#e0b356",
  serious: "#ef9a5f",
  critical: "#f08279",
};

/** The dot beside a session, and the meter fill. Never the only signal. */
export function statusColor(
  palette: Palette,
  status: string,
): string {
  switch (status) {
    case "running":
      return palette.good;
    case "awaiting_approval":
      return palette.warning;
    case "paused":
      return palette.textMuted;
    case "dead":
      return palette.critical;
    default:
      return palette.textSecondary;
  }
}

/** Apple's minimum tap target, which is also the right one on Android. */
export const TAP = 44;
