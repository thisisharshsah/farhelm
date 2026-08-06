/**
 * Pairing the phone (D2).
 *
 * Same exchange as the web app: generate a keypair, redeem the one-time code
 * against the runner over your own network, remember what it said. The secret
 * goes to the platform keystore rather than `localStorage`, which is the one
 * place this client is meaningfully safer than the PWA.
 *
 * No camera here either, for a different reason than the web's. A QR scanner
 * would work on a phone — but the runner prints the payload as text beside the
 * QR, one paste covers both clients, and a camera permission prompt on first run
 * is a worse trade than a paste for an app whose entire job is approving things.
 * `expo-camera` is a two-line addition if that turns out to be wrong.
 */

import { useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, Text, View } from "react-native";
import {
  Identity,
  claimPairing,
  parseOffer,
  type Pairing,
} from "@relayforge/client-core";
import { securePairingStore } from "../platform";
import { Field } from "../components/pieces";
import { TAP, type Palette } from "../theme";

export function PairingScreen({
  palette,
  pairing,
  runnerUrl,
  onRunnerUrl,
  onPaired,
  onUnpaired,
}: {
  palette: Palette;
  pairing: Pairing | null;
  runnerUrl: string;
  onRunnerUrl: (next: string) => void;
  onPaired: (pairing: Pairing) => void;
  onUnpaired: () => void;
}) {
  const [payload, setPayload] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const offer = parseOffer(payload);
      // Generated here and now; the runner only ever learns the public half.
      const identity = Identity.generate();
      const claimed = await claimPairing(
        runnerUrl,
        offer,
        "phone",
        identity.publicKey,
      );
      const next: Pairing = { ...claimed, secret: identity.toSecret() };
      await securePairingStore.save(next);
      onPaired(next);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  if (pairing) {
    return (
      <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
        <Card palette={palette}>
          <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
            Paired
          </Text>
          <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
            This phone talks to the runner through {pairing.relayUrl},
            end-to-end encrypted. The relay forwards ciphertext and keeps
            nothing.
          </Text>
          <Text style={{ color: palette.textMuted, fontSize: 12 }}>
            device {pairing.deviceId}
          </Text>
          <Button
            palette={palette}
            label="Unpair"
            tone="danger"
            onPress={onUnpaired}
          />
        </Card>
      </ScrollView>
    );
  }

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          Pair this phone
        </Text>
        <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
          Run <Text style={{ fontFamily: "Menlo" }}>forge-runner pair</Text> and
          paste what it prints. The code works once and expires in ten minutes.
        </Text>

        <Field
          palette={palette}
          label="Pairing code"
          value={payload}
          onChangeText={setPayload}
          placeholder='{"relay_url":"wss://…","channel":"forge-…",…}'
          multiline
        />

        <Field
          palette={palette}
          label="Runner address"
          value={runnerUrl}
          onChangeText={onRunnerUrl}
          placeholder="http://192.168.1.10:7842"
        />
        <Text style={{ color: palette.textMuted, fontSize: 12 }}>
          Reachable right now — pairing happens on your own network, before the
          relay takes over. It is also what the watch needs to pair through.
        </Text>

        {error ? (
          <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
        ) : null}

        <Button
          palette={palette}
          label={busy ? "Pairing…" : "Pair"}
          busy={busy}
          disabled={busy || payload.trim().length === 0}
          onPress={() => void submit()}
        />
      </Card>
    </ScrollView>
  );
}

/* --------------------------------------------------------------- furniture */

export function Card({
  palette,
  children,
}: {
  palette: Palette;
  children: React.ReactNode;
}) {
  return (
    <View
      style={{
        backgroundColor: palette.surface1,
        borderRadius: 14,
        borderWidth: 1,
        borderColor: palette.border,
        padding: 14,
        gap: 10,
      }}
    >
      {children}
    </View>
  );
}

export function Button({
  palette,
  label,
  onPress,
  busy = false,
  disabled = false,
  tone = "primary",
}: {
  palette: Palette;
  label: string;
  onPress: () => void;
  busy?: boolean;
  disabled?: boolean;
  tone?: "primary" | "danger" | "quiet";
}) {
  const background =
    tone === "danger"
      ? palette.critical
      : tone === "quiet"
        ? palette.surface2
        : palette.series1;
  const foreground = tone === "quiet" ? palette.textPrimary : "#ffffff";

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => ({
        minHeight: TAP,
        alignItems: "center",
        justifyContent: "center",
        borderRadius: 10,
        backgroundColor: background,
        opacity: disabled ? 0.5 : pressed ? 0.8 : 1,
      })}
    >
      {busy ? (
        <ActivityIndicator color={foreground} />
      ) : (
        <Text style={{ color: foreground, fontWeight: "600" }}>{label}</Text>
      )}
    </Pressable>
  );
}
