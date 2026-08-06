/**
 * Reviewing a change set on a phone.
 *
 * This is the screen the product was aiming at. Everything else on the phone
 * answers a yes/no about a *command*; this one shows you what actually changed
 * and asks whether it should land. It is the only screen here that renders code.
 *
 * # What a phone changes about reading a diff
 *
 * **Monospace and no wrapping.** A soft-wrapped diff line reads as two changed
 * lines. So the code scrolls sideways inside each file, and only there — the
 * page itself never does.
 *
 * **Files start collapsed past the first.** A five-file change set otherwise
 * opens as a wall of code, and the first decision a reviewer makes is about
 * shape, not about line 41.
 *
 * **The verdict is reachable without reading to the end.** Approve and Reject
 * sit above the diff as well as below it.
 */

import { useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, Text, TextInput, View } from "react-native";
import {
  canRevert,
  changeMark,
  hunkHeader,
  numberedLines,
  since,
  usd,
  type FileDiff,
  type TaskDetail,
  type TaskStatus,
  type Transport,
} from "@relayforge/client-core";
import { TAP, type Palette } from "../theme";

const STATUS_LABEL: Record<TaskStatus, string> = {
  running: "working",
  awaiting_review: "needs review",
  applied: "applied",
  rejected: "rejected",
  no_changes: "no changes",
  failed: "failed",
  reverted: "undone",
};

function statusColour(palette: Palette, status: TaskStatus): string {
  switch (status) {
    case "awaiting_review":
      return palette.warning;
    case "applied":
      return palette.good;
    case "failed":
      return palette.critical;
    default:
      return palette.textMuted;
  }
}

/* ------------------------------------------------------------------- diff */

function FileDiffView({
  file,
  palette,
  startOpen,
}: {
  file: FileDiff;
  palette: Palette;
  startOpen: boolean;
}) {
  const [open, setOpen] = useState(startOpen);

  return (
    <View
      style={{
        borderWidth: 1,
        borderColor: palette.border,
        borderRadius: 10,
        overflow: "hidden",
        marginBottom: 8,
      }}
    >
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ expanded: open }}
        accessibilityLabel={`${file.path}, ${file.added} added, ${file.removed} removed`}
        onPress={() => setOpen((value) => !value)}
        style={{
          flexDirection: "row",
          alignItems: "center",
          gap: 8,
          minHeight: TAP,
          paddingHorizontal: 10,
          backgroundColor: palette.surface2,
        }}
      >
        <Text style={{ color: palette.textMuted, fontFamily: "Menlo", fontSize: 13 }}>
          {changeMark(file.kind)}
        </Text>
        <Text
          style={{
            flex: 1,
            color: palette.textPrimary,
            fontFamily: "Menlo",
            fontSize: 12,
          }}
          numberOfLines={1}
          // The end of a path is the useful half.
          ellipsizeMode="head"
        >
          {file.path}
        </Text>
        <Text style={{ color: palette.good, fontSize: 12 }}>+{file.added}</Text>
        <Text style={{ color: palette.critical, fontSize: 12 }}>−{file.removed}</Text>
        <Text style={{ color: palette.textMuted, fontSize: 11 }}>
          {open ? "▾" : "▸"}
        </Text>
      </Pressable>

      {open ? (
        file.binary ? (
          <Text
            style={{ color: palette.textMuted, fontSize: 12, padding: 10 }}
          >
            Binary file — not shown. Nothing here can be reviewed on a screen.
          </Text>
        ) : (
          // The one place in the app that scrolls sideways. Code must not wrap:
          // a wrapped line looks like two changed ones.
          <ScrollView horizontal showsHorizontalScrollIndicator>
            <View style={{ backgroundColor: palette.surface1 }}>
              {file.hunks.map((hunk, hunkIndex) => (
                <View key={hunkIndex}>
                  <Text
                    style={{
                      color: palette.textMuted,
                      backgroundColor: palette.surface2,
                      fontFamily: "Menlo",
                      fontSize: 11,
                      paddingHorizontal: 8,
                      paddingVertical: 2,
                    }}
                  >
                    {hunkHeader(hunk)}
                  </Text>
                  {numberedLines(hunk).map((line, index) => (
                    <View
                      key={index}
                      style={{
                        flexDirection: "row",
                        backgroundColor:
                          line.tag === "add"
                            ? palette.good + "22"
                            : line.tag === "remove"
                              ? palette.critical + "22"
                              : undefined,
                      }}
                    >
                      <Text style={numberStyle(palette)}>{line.oldNo ?? ""}</Text>
                      <Text style={numberStyle(palette)}>{line.newNo ?? ""}</Text>
                      {/* The glyph, not the tint, is what survives a sunlit
                          screen and a colour-blind reader. */}
                      <Text
                        style={{
                          ...codeStyle(palette),
                          width: 14,
                          textAlign: "center",
                          color:
                            line.tag === "add"
                              ? palette.good
                              : line.tag === "remove"
                                ? palette.critical
                                : palette.textMuted,
                        }}
                      >
                        {line.tag === "add" ? "+" : line.tag === "remove" ? "−" : " "}
                      </Text>
                      <Text style={{ ...codeStyle(palette), paddingRight: 12 }}>
                        {line.text || " "}
                      </Text>
                    </View>
                  ))}
                </View>
              ))}
            </View>
          </ScrollView>
        )
      ) : null}
    </View>
  );
}

const codeStyle = (palette: Palette) => ({
  color: palette.textPrimary,
  fontFamily: "Menlo" as const,
  fontSize: 12,
  lineHeight: 18,
});

const numberStyle = (palette: Palette) => ({
  ...codeStyle(palette),
  color: palette.textMuted,
  width: 36,
  paddingRight: 6,
  textAlign: "right" as const,
});

/* --------------------------------------------------------- second opinion */

/**
 * C10's read of the diff, above it.
 *
 * A task with no verdict renders nothing rather than a reassuring placeholder:
 * "not judged" and "judged and found fine" are different answers, and on a
 * phone — where somebody may well approve without scrolling — blurring them
 * would be the most expensive wrong pixel in the app.
 */
function SecondOpinion({
  task,
  palette,
}: {
  task: TaskDetail;
  palette: Palette;
}) {
  if (!task.verify_grade) return null;

  const colour =
    task.verify_grade === "pass"
      ? palette.good
      : task.verify_grade === "fail"
        ? palette.critical
        : palette.warning;

  const label =
    task.verify_grade === "pass"
      ? "No problems found"
      : task.verify_grade === "fail"
        ? "This looks wrong"
        : "Worth a closer look";

  return (
    <View
      style={{
        marginTop: 12,
        padding: 10,
        borderRadius: 10,
        backgroundColor: palette.surface2,
        borderLeftWidth: 3,
        borderLeftColor: colour,
      }}
    >
      <Text style={{ color: palette.textPrimary, fontWeight: "600", fontSize: 13 }}>
        {/* The glyph, not the tint, is what survives greyscale. */}
        {task.verify_grade === "pass" ? "✓" : task.verify_grade === "fail" ? "✗" : "!"}{" "}
        {label}
        {task.verify_model ? (
          <Text style={{ color: palette.textMuted, fontWeight: "400" }}>
            {" "}· {task.verify_model} read the diff
          </Text>
        ) : null}
      </Text>
      {task.verify_notes ? (
        <Text style={{ color: palette.textSecondary, fontSize: 12, marginTop: 4 }}>
          {task.verify_notes}
        </Text>
      ) : null}
    </View>
  );
}

/* ---------------------------------------------------------------- verdict */

function Verdict({
  task,
  transport,
  palette,
  onReviewed,
}: {
  task: TaskDetail;
  transport: Transport | null;
  palette: Palette;
  onReviewed: () => void;
}) {
  const [rejecting, setRejecting] = useState(false);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState<"approve" | "reject" | null>(null);
  const [error, setError] = useState<string | null>(null);

  if (task.status !== "awaiting_review") return null;

  const submit = async (decision: "approve" | "reject") => {
    setBusy(decision);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.reviewTask(task.id, decision, note.trim() || undefined);
      onReviewed();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  return (
    <View style={{ marginTop: 12, gap: 8 }}>
      {rejecting ? (
        <>
          <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
            What is wrong with it?
          </Text>
          <TextInput
            value={note}
            onChangeText={setNote}
            placeholder="This breaks the retry cap…"
            placeholderTextColor={palette.textMuted}
            autoFocus
            style={{
              minHeight: TAP,
              color: palette.textPrimary,
              backgroundColor: palette.surface1,
              borderWidth: 1,
              borderColor: palette.border,
              borderRadius: 10,
              paddingHorizontal: 12,
            }}
          />
          <Text style={{ color: palette.textMuted, fontSize: 12 }}>
            Handed to the next attempt verbatim — the only part of a rejection
            the agent gets to read.
          </Text>
        </>
      ) : null}

      {error ? (
        <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
      ) : null}

      <View style={{ flexDirection: "row", gap: 8 }}>
        {rejecting ? (
          <Button
            palette={palette}
            label="Back"
            onPress={() => setRejecting(false)}
            disabled={!!busy}
          />
        ) : null}
        <Button
          palette={palette}
          label={busy === "reject" ? "Rejecting…" : rejecting ? "Reject it" : "Reject"}
          tone="critical"
          disabled={!!busy}
          onPress={() => (rejecting ? void submit("reject") : setRejecting(true))}
        />
        {!rejecting ? (
          <Button
            palette={palette}
            label={busy === "approve" ? "Applying…" : "Apply to disk"}
            tone="good"
            disabled={!!busy}
            onPress={() => void submit("approve")}
          />
        ) : null}
      </View>
    </View>
  );
}

/**
 * Undo an applied change set.
 *
 * The thing that makes "Apply to disk" a comfortable button to press from a
 * phone. The runner refuses if anything has moved since, so the promise on the
 * label is one it can keep.
 */
function Undo({
  task,
  transport,
  palette,
  onUndone,
}: {
  task: TaskDetail;
  transport: Transport | null;
  palette: Palette;
  onUndone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!canRevert(task.status)) return null;

  const undo = async () => {
    setBusy(true);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.revertTask(task.id);
      onUndone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={{ marginTop: 12, gap: 8 }}>
      <Text style={{ color: palette.textMuted, fontSize: 12 }}>
        Puts back exactly what these {task.files_changed} file
        {task.files_changed === 1 ? "" : "s"} held before. If anything has been
        edited since, nothing is touched.
      </Text>
      {error ? (
        <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
      ) : null}
      <Button
        palette={palette}
        label={busy ? "Undoing…" : "Undo this change"}
        disabled={busy}
        onPress={() => void undo()}
      />
    </View>
  );
}

function Button({
  palette,
  label,
  onPress,
  tone,
  disabled,
}: {
  palette: Palette;
  label: string;
  onPress: () => void;
  tone?: "good" | "critical";
  disabled?: boolean;
}) {
  const colour =
    tone === "good"
      ? palette.good
      : tone === "critical"
        ? palette.critical
        : palette.textSecondary;

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled }}
      disabled={disabled}
      onPress={onPress}
      style={{
        flex: 1,
        minHeight: TAP,
        alignItems: "center",
        justifyContent: "center",
        borderRadius: 10,
        borderWidth: 1,
        borderColor: colour,
        opacity: disabled ? 0.5 : 1,
      }}
    >
      <Text style={{ color: colour, fontSize: 15, fontWeight: "600" }}>
        {label}
      </Text>
    </Pressable>
  );
}

/* ----------------------------------------------------------------- screen */

export function TaskScreen({
  task,
  transport,
  palette,
  onReviewed,
}: {
  task: TaskDetail | null;
  transport: Transport | null;
  palette: Palette;
  onReviewed: () => void;
}) {
  if (!task) return <ActivityIndicator style={{ marginTop: 32 }} />;

  const card = {
    backgroundColor: palette.surface1,
    borderWidth: 1,
    borderColor: palette.border,
    borderRadius: 12,
    padding: 14,
    marginBottom: 12,
  };

  return (
    <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 40 }}>
      <View style={card}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <Text
            style={{ flex: 1, color: palette.textPrimary, fontWeight: "700" }}
            numberOfLines={1}
          >
            {task.repo_name}
          </Text>
          <Text
            style={{ color: statusColour(palette, task.status), fontSize: 12 }}
          >
            {STATUS_LABEL[task.status]}
          </Text>
        </View>

        <Text style={{ color: palette.textPrimary, marginTop: 8, fontSize: 14 }}>
          {task.prompt}
        </Text>

        {task.summary ? (
          <Text
            style={{ color: palette.textSecondary, marginTop: 8, fontSize: 13 }}
          >
            {task.summary}
          </Text>
        ) : null}

        {task.error ? (
          <Text style={{ color: palette.critical, marginTop: 8, fontSize: 13 }}>
            {task.error}
          </Text>
        ) : null}

        <Text style={{ color: palette.textMuted, marginTop: 8, fontSize: 12 }}>
          {task.change_summary} · {task.steps} step{task.steps === 1 ? "" : "s"} ·{" "}
          {usd(task.cost_usd)} · {since(task.created_at)}
        </Text>

        {task.review_note ? (
          <Text style={{ color: palette.textMuted, marginTop: 8, fontSize: 12 }}>
            Rejected: “{task.review_note}”
          </Text>
        ) : null}

        <SecondOpinion task={task} palette={palette} />

        <Verdict
          task={task}
          transport={transport}
          palette={palette}
          onReviewed={onReviewed}
        />
        <Undo
          task={task}
          transport={transport}
          palette={palette}
          onUndone={onReviewed}
        />
      </View>

      {task.changes.files.length > 0 ? (
        <View style={card}>
          <Text
            style={{
              color: palette.textSecondary,
              fontSize: 13,
              fontWeight: "600",
              marginBottom: 8,
            }}
          >
            Proposed change · {task.change_summary}
          </Text>
          {task.changes.files.map((file, index) => (
            <FileDiffView
              key={file.path}
              file={file}
              palette={palette}
              // The first file opens; the rest are a tap away. A five-file
              // change set otherwise arrives as a wall of code.
              startOpen={index === 0}
            />
          ))}
          <Verdict
            task={task}
            transport={transport}
            palette={palette}
            onReviewed={onReviewed}
          />
        </View>
      ) : null}
    </ScrollView>
  );
}
