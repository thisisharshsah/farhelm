/**
 * The shared visual pieces: budget meter, approval card, session row.
 *
 * Deliberately plain `View`s and `Text`s — no chart library. The one graphic
 * that earns its place on a phone is the budget meter, and a meter is a rounded
 * rectangle inside another rounded rectangle. The cost dashboard's real charts
 * stay on the web tier, where there is room to read them.
 */

import { useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  Text,
  TextInput,
  View,
} from "react-native";
import {
  pct,
  since,
  statusLabel,
  usd,
  type ApprovalView,
  type BudgetView,
  type Decision,
  type SessionView,
  type Transport,
} from "@relayforge/client-core";
import { TAP, statusColor, type Palette } from "../theme";

/* ------------------------------------------------------------ budget meter */

export function BudgetMeter({
  budget,
  palette,
}: {
  budget: BudgetView;
  palette: Palette;
}) {
  const fill =
    budget.state === "stop"
      ? palette.critical
      : budget.state === "warn"
        ? palette.warning
        : palette.good;

  return (
    <View>
      <View
        style={{
          height: 8,
          borderRadius: 4,
          backgroundColor: palette.surface2,
          overflow: "hidden",
        }}
      >
        <View
          style={{
            height: "100%",
            width: `${Math.min(100, (budget.pct ?? 0) * 100)}%`,
            backgroundColor: fill,
          }}
        />
      </View>
      {/* The number is always written out. A bar alone is not a reading, and
          colour alone is not a signal. */}
      <Text style={{ color: palette.textMuted, fontSize: 12, marginTop: 4 }}>
        {usd(budget.spent_usd)}
        {budget.cap_usd != null
          ? ` of ${usd(budget.cap_usd)} · ${pct(budget.pct)}`
          : " spent · no cap"}
      </Text>
    </View>
  );
}

/* ----------------------------------------------------------- approval card */

export function ApprovalCard({
  approval,
  transport,
  palette,
  onDecided,
  showRepo = false,
}: {
  approval: ApprovalView;
  transport: Transport | null;
  palette: Palette;
  onDecided: () => void;
  showRepo?: boolean;
}) {
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);

  const decide = async (decision: Decision) => {
    setBusy(decision);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.decide(approval.id, decision);
      onDecided();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(null);
    }
  };

  return (
    <View
      style={{
        backgroundColor: palette.surface1,
        borderRadius: 14,
        borderWidth: 1,
        borderColor:
          approval.risk === "destructive" ? palette.critical : palette.border,
        padding: 14,
        marginBottom: 12,
        gap: 8,
      }}
    >
      <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
        {showRepo ? approval.repo_name : "Needs approval"}
        <Text style={{ color: palette.textMuted, fontWeight: "400" }}>
          {"  "}
          {since(approval.requested_at)}
        </Text>
      </Text>

      <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
        wants to run {approval.tool}
      </Text>
      <Text
        style={{
          color: palette.textPrimary,
          fontFamily: "Menlo",
          fontSize: 13,
          backgroundColor: palette.surface2,
          borderRadius: 8,
          padding: 8,
        }}
      >
        {approval.payload}
      </Text>

      {/* The moment of approval is the moment of spend, so the bar lives here. */}
      <BudgetMeter budget={approval.budget} palette={palette} />

      {!approval.allows_watch_decision ? (
        <Text style={{ color: palette.serious, fontSize: 12 }}>
          ■ Destructive — deliberate friction. This one cannot be cleared from
          the watch.
        </Text>
      ) : null}

      {error ? (
        <Text style={{ color: palette.critical, fontSize: 12 }}>{error}</Text>
      ) : null}

      <View style={{ flexDirection: "row", gap: 8 }}>
        <DecisionButton
          label="Approve"
          busy={busy === "approved"}
          disabled={busy !== null}
          color={palette.good}
          palette={palette}
          onPress={() => void decide("approved")}
        />
        <DecisionButton
          label="Deny"
          busy={busy === "denied"}
          disabled={busy !== null}
          color={palette.critical}
          palette={palette}
          onPress={() => void decide("denied")}
        />
      </View>
    </View>
  );
}

function DecisionButton({
  label,
  busy,
  disabled,
  color,
  palette,
  onPress,
}: {
  label: string;
  busy: boolean;
  disabled: boolean;
  color: string;
  palette: Palette;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => ({
        flex: 1,
        minHeight: TAP,
        alignItems: "center",
        justifyContent: "center",
        borderRadius: 10,
        backgroundColor: color,
        opacity: disabled ? 0.5 : pressed ? 0.8 : 1,
      })}
    >
      {busy ? (
        <ActivityIndicator color={palette.surface1} />
      ) : (
        <Text style={{ color: "#ffffff", fontWeight: "600" }}>{label}</Text>
      )}
    </Pressable>
  );
}

/* ------------------------------------------------------------- session row */

export function SessionRow({
  session,
  palette,
  onOpen,
}: {
  session: SessionView;
  palette: Palette;
  onOpen: () => void;
}) {
  const plan = session.plan;
  return (
    <Pressable
      accessibilityRole="button"
      onPress={onOpen}
      style={({ pressed }) => ({
        backgroundColor: palette.surface1,
        borderRadius: 14,
        borderWidth: 1,
        borderColor: palette.border,
        padding: 14,
        marginBottom: 10,
        gap: 6,
        opacity: pressed ? 0.7 : 1,
      })}
    >
      <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
        <View
          style={{
            width: 8,
            height: 8,
            borderRadius: 4,
            backgroundColor: statusColor(palette, session.status),
          }}
        />
        <Text style={{ color: palette.textPrimary, fontWeight: "600", flex: 1 }}>
          {session.repo_name}
        </Text>
        <Text style={{ color: palette.textMuted, fontSize: 12 }}>
          {session.machine_name}
        </Text>
      </View>

      <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
        {statusLabel(session.status)}
        {plan && plan.total > 0
          ? ` · Step ${plan.current_ordinal ?? plan.settled}/${plan.total}${
              plan.current_title ? ` · ${plan.current_title}` : ""
            }`
          : ""}
        {!session.is_live && session.ended_at
          ? ` · ${since(session.ended_at)}`
          : ""}
      </Text>

      <BudgetMeter budget={session.budget} palette={palette} />
    </Pressable>
  );
}

/**
 * The one text field the pairing and watch screens share.
 *
 * Lived in `App.tsx` and was imported back out of it by `screens/Pairing.tsx`,
 * which made the app's entry point and one of its screens a cycle. Nothing broke
 * — a bundler resolves it — but it meant the screen could not be understood, or
 * tested, without dragging the whole app in.
 */
export function Field({
  palette,
  label,
  value,
  onChangeText,
  placeholder,
  multiline = false,
}: {
  palette: Palette;
  label: string;
  value: string;
  onChangeText: (next: string) => void;
  placeholder?: string;
  multiline?: boolean;
}) {
  return (
    <View style={{ gap: 6 }}>
      <Text style={{ color: palette.textMuted, fontSize: 12 }}>{label}</Text>
      <TextInput
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={palette.textMuted}
        multiline={multiline}
        autoCapitalize="none"
        autoCorrect={false}
        spellCheck={false}
        style={{
          minHeight: multiline ? TAP * 2 : TAP,
          color: palette.textPrimary,
          backgroundColor: palette.surface1,
          borderWidth: 1,
          borderColor: palette.border,
          borderRadius: 10,
          paddingHorizontal: 12,
          paddingVertical: 10,
          // A key blob has no words in it: `l1I` and `O0` need to be
          // distinguishable when a paste goes wrong.
          fontFamily: "Menlo",
          fontSize: 13,
        }}
      />
    </View>
  );
}
