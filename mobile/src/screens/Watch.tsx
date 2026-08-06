/**
 * The watch tab: pair the wrist, and explain what it can and cannot do.
 *
 * The phone's only role in the watch's life is claiming a pairing code on its
 * behalf — see `src/watch/bridge.ts` for why the watch is a device in its own
 * right rather than a remote control for this app.
 */

import { useEffect, useState } from "react";
import { ScrollView, Text, View } from "react-native";
import { createRunnerApi } from "@relayforge/client-core";
import {
  loadWatchSession,
  servePairing,
  type WatchSession,
} from "../watch/bridge";
import { Button, Card } from "./Pairing";
import type { Palette } from "../theme";

export function WatchScreen({
  palette,
  runnerUrl,
}: {
  palette: Palette;
  runnerUrl: string;
}) {
  const [session, setSession] = useState<WatchSession | null | undefined>(
    undefined,
  );
  const [reachable, setReachable] = useState<boolean | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    void loadWatchSession().then((next) => {
      if (!live) return;
      setSession(next);
      if (next) void next.getReachability().then(setReachable);
    });
    return () => {
      live = false;
    };
  }, []);

  // Listen the whole time this screen is up: the watch initiates, because only
  // it can generate its own key.
  useEffect(() => {
    if (!session) return;
    return servePairing(
      session,
      () => createRunnerApi(runnerUrl),
      (result) => {
        setStatus(
          result.kind === "pair-response"
            ? `Paired — the watch is device ${result.device_id}. It talks to the relay on its own from here.`
            : `Could not pair the watch: ${result.message}`,
        );
      },
    );
  }, [session, runnerUrl]);

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          Apple Watch
        </Text>

        {session === undefined ? (
          <Text style={{ color: palette.textMuted, fontSize: 13 }}>
            Looking for a watch…
          </Text>
        ) : session === null ? (
          <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
            No watch is reachable from this device. WatchConnectivity is iOS
            only, and needs a watch paired to this phone with the RelayForge
            watch app installed.
          </Text>
        ) : (
          <>
            <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
              {reachable === null
                ? "Checking…"
                : reachable
                  ? "Watch is reachable."
                  : "Watch is paired but not reachable right now — open the RelayForge app on it."}
            </Text>
            <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
              On the watch, open RelayForge and tap <Text style={{ fontWeight: "600" }}>Pair</Text>. It
              generates its own key and asks this phone to redeem a code for it —
              the key itself never leaves your wrist.
            </Text>
            <Text style={{ color: palette.textMuted, fontSize: 12 }}>
              This phone must be able to reach {runnerUrl} while that happens.
              Set the address under Pair if it is wrong.
            </Text>
          </>
        )}

        {status ? (
          <Text style={{ color: palette.textPrimary, fontSize: 13 }}>
            {status}
          </Text>
        ) : null}

        {session ? (
          <Button
            palette={palette}
            tone="quiet"
            label="Check again"
            onPress={() => void session.getReachability().then(setReachable)}
          />
        ) : null}
      </Card>

      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          What the watch can do
        </Text>
        <Bullet palette={palette}>
          Approve or deny an ordinary tool call, in one tap.
        </Bullet>
        <Bullet palette={palette}>
          Show plan progress — step 3 of 7, and what step 3 is.
        </Bullet>
        <Bullet palette={palette}>Show the budget as it fills.</Bullet>

        <Text
          style={{ color: palette.textPrimary, fontWeight: "600", marginTop: 6 }}
        >
          What it deliberately cannot
        </Text>
        <Bullet palette={palette}>
          Approve a destructive command. Those need the phone — the rule is
          enforced by the runner against the watch's registered device kind, so
          it holds even if the watch app is modified.
        </Bullet>
        <Bullet palette={palette}>
          Show a diff, or any code. A diff on a wrist is not a review.
        </Bullet>
      </Card>
    </ScrollView>
  );
}

function Bullet({
  palette,
  children,
}: {
  palette: Palette;
  children: React.ReactNode;
}) {
  return (
    <View style={{ flexDirection: "row", gap: 8 }}>
      <Text style={{ color: palette.textMuted }}>·</Text>
      <Text style={{ color: palette.textSecondary, fontSize: 13, flex: 1 }}>
        {children}
      </Text>
    </View>
  );
}
