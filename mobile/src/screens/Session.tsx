/**
 * One session: plan, output tail, instruction box.
 *
 * The output tail is capped and scrolls, and auto-scroll only engages when the
 * reader is already at the bottom — yanking the view while someone scrolls back
 * through a failure is hostile, and it is exactly when they most need to read.
 */

import { useRef, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  Text,
  TextInput,
  View,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from "react-native";
import {
  statusLabel,
  type PlanStepView,
  type SessionDetail,
  type Transport,
} from "@relayforge/client-core";
import { ApprovalCard, BudgetMeter } from "../components/pieces";
import { Button, Card } from "./Pairing";
import { TAP, statusColor, type Palette } from "../theme";

const STEP_MARK: Record<PlanStepView["status"], string> = {
  todo: "○",
  active: "▶",
  done: "✓",
  skipped: "–",
  failed: "✕",
};

export function SessionScreen({
  session,
  transport,
  palette,
  onChanged,
}: {
  session: SessionDetail | null;
  transport: Transport | null;
  palette: Palette;
  onChanged: () => void;
}) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const outputRef = useRef<ScrollView | null>(null);
  const pinned = useRef(true);

  if (!session) {
    return <ActivityIndicator style={{ marginTop: 40 }} />;
  }

  const act = async (run: () => Promise<unknown>) => {
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await run();
      onChanged();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  const send = async () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    setSending(true);
    await act(async () => {
      await transport!.instruct(session.id, trimmed);
      setText("");
    });
    setSending(false);
  };

  const onScroll = (event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const { contentOffset, contentSize, layoutMeasurement } = event.nativeEvent;
    pinned.current =
      contentSize.height - contentOffset.y - layoutMeasurement.height < 32;
  };

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      {session.pending_approval ? (
        <ApprovalCard
          approval={session.pending_approval}
          transport={transport}
          palette={palette}
          onDecided={onChanged}
        />
      ) : null}

      <Card palette={palette}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <View
            style={{
              width: 8,
              height: 8,
              borderRadius: 4,
              backgroundColor: statusColor(palette, session.status),
            }}
          />
          <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
            {statusLabel(session.status)}
          </Text>
          <Text style={{ color: palette.textMuted, fontSize: 12, flex: 1 }}>
            {session.machine_name}
          </Text>
        </View>
        <BudgetMeter budget={session.budget} palette={palette} />
      </Card>

      {session.steps.length > 0 ? (
        <Card palette={palette}>
          <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
            Plan
          </Text>
          {session.steps.map((step) => (
            <View
              key={step.ordinal}
              style={{ flexDirection: "row", gap: 8, alignItems: "flex-start" }}
            >
              <Text style={{ color: palette.textMuted, width: 16 }}>
                {STEP_MARK[step.status]}
              </Text>
              <Text
                style={{
                  color:
                    step.status === "active"
                      ? palette.textPrimary
                      : palette.textSecondary,
                  fontWeight: step.status === "active" ? "600" : "400",
                  flex: 1,
                  fontSize: 13,
                  // Settled steps recede; the one that matters is the active one.
                  textDecorationLine:
                    step.status === "skipped" ? "line-through" : "none",
                }}
              >
                {step.ordinal}. {step.title}
              </Text>
              {/* Status is written out, never carried by the glyph alone. */}
              <Text style={{ color: palette.textMuted, fontSize: 11 }}>
                {step.status}
              </Text>
            </View>
          ))}

          <View style={{ flexDirection: "row", gap: 8 }}>
            <View style={{ flex: 1 }}>
              <Button
                palette={palette}
                tone="quiet"
                label={session.status === "paused" ? "Resume" : "Pause"}
                onPress={() =>
                  void act(() =>
                    transport!.planControl(
                      session.id,
                      session.status === "paused" ? "resume" : "pause",
                    ),
                  )
                }
              />
            </View>
            <View style={{ flex: 1 }}>
              <Button
                palette={palette}
                tone="quiet"
                label="Skip step"
                onPress={() =>
                  void act(() => transport!.planControl(session.id, "skip"))
                }
              />
            </View>
          </View>
        </Card>
      ) : null}

      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          Output
        </Text>
        {session.output.length === 0 ? (
          <Text style={{ color: palette.textMuted, fontSize: 13 }}>
            No output yet.
          </Text>
        ) : (
          <ScrollView
            ref={outputRef}
            onScroll={onScroll}
            scrollEventThrottle={64}
            onContentSizeChange={() => {
              if (pinned.current) outputRef.current?.scrollToEnd({ animated: false });
            }}
            style={{
              maxHeight: 260,
              backgroundColor: palette.surface2,
              borderRadius: 8,
              padding: 8,
            }}
          >
            {session.output.map((line) => (
              <Text
                key={line.seq}
                style={{
                  color: line.text.startsWith("›")
                    ? palette.series1
                    : palette.textSecondary,
                  fontFamily: "Menlo",
                  fontSize: 11,
                  lineHeight: 16,
                }}
              >
                {line.text || " "}
              </Text>
            ))}
          </ScrollView>
        )}
      </Card>

      {error ? (
        <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
      ) : null}

      <View style={{ flexDirection: "row", gap: 8, alignItems: "flex-end" }}>
        <TextInput
          value={text}
          onChangeText={setText}
          placeholder="Send an instruction…"
          placeholderTextColor={palette.textMuted}
          onSubmitEditing={() => void send()}
          returnKeyType="send"
          style={{
            flex: 1,
            minHeight: TAP,
            color: palette.textPrimary,
            backgroundColor: palette.surface1,
            borderWidth: 1,
            borderColor: palette.border,
            borderRadius: 10,
            paddingHorizontal: 12,
          }}
        />
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Send instruction"
          disabled={sending || text.trim().length === 0}
          onPress={() => void send()}
          style={({ pressed }) => ({
            minHeight: TAP,
            paddingHorizontal: 18,
            alignItems: "center",
            justifyContent: "center",
            borderRadius: 10,
            backgroundColor: palette.series1,
            opacity: sending || !text.trim() ? 0.5 : pressed ? 0.8 : 1,
          })}
        >
          <Text style={{ color: "#ffffff", fontWeight: "600" }}>Send</Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}
