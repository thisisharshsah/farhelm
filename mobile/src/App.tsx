/**
 * The phone app.
 *
 * Three screens — fleet, session, pairing — over the same `Transport` the web
 * app uses, which is why there is no second implementation of anything that
 * matters here. What differs from the web is only what has to: the keystore, the
 * absence of SSE, and the watch tab.
 *
 * The cost dashboard is deliberately absent. It is a reading surface with four
 * charts on it, and the phone tier exists for the thing you do in fifteen
 * seconds while walking. The web app has it.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  ScrollView,
  Text,
  View,
  useColorScheme,
} from "react-native";
import { StatusBar } from "expo-status-bar";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import {
  RelayTransport,
  pct,
  usd,
  type ConnectionState,
  type FleetView,
  type Pairing,
  type SessionDetail,
  type TaskDetail,
  type TaskStatus,
  type Transport,
} from "@relayforge/client-core";
import { loopbackTransport, securePairingStore } from "./platform";
import { ApprovalCard, SessionRow } from "./components/pieces";
import { PairingScreen } from "./screens/Pairing";
import { SessionScreen } from "./screens/Session";
import { TaskScreen } from "./screens/Task";
import { WatchScreen } from "./screens/Watch";
import { TAP, dark, light } from "./theme";

type Route =
  | { view: "fleet" }
  | { view: "session"; id: string }
  | { view: "task"; id: string }
  | { view: "pairing" }
  | { view: "watch" };

/**
 * A change set this phone has been told about through an event.
 *
 * The fleet snapshot is the authority — it carries every task actually awaiting
 * review, and it is what a freshly woken phone reads. This is the *live* half:
 * an event arriving between refreshes, so a task that appears while you are
 * looking at the screen shows up without waiting for the next fetch.
 */
interface WaitingTask {
  id: string;
  status: TaskStatus;
  summary: string;
}

export default function App() {
  const scheme = useColorScheme();
  const palette = scheme === "dark" ? dark : light;

  const [route, setRoute] = useState<Route>({ view: "fleet" });

  /**
   * `undefined` means the keystore has not answered yet. Starting a loopback
   * transport in the meantime would flash a connection error on a paired phone
   * that is nowhere near the runner — which is the normal case for this app.
   */
  const [pairing, setPairing] = useState<Pairing | null | undefined>(undefined);
  /**
   * Where the runner is, for the loopback path and for pairing the watch.
   *
   * Loopback, because that is the only interface the runner listens on — its
   * localhost API has no authentication, so binding it to the network would put
   * an unauthenticated approval endpoint on the LAN. This therefore works on the
   * **simulator**, which shares the host's network stack, and on a real handset
   * it does not: pair that one to a relay instead.
   *
   * The previous default was a plausible-looking LAN address, which is the worst
   * of both worlds — nothing is listening there, and a TCP connect to a dead host
   * on your own subnet hangs for the better part of a minute before failing.
   */
  const [runnerUrl, setRunnerUrl] = useState("http://127.0.0.1:7842");
  const [connection, setConnection] = useState<ConnectionState>("connecting");
  const [refusal, setRefusal] = useState<string | null>(null);
  /** Set when the keystore could not be read. Shown, not swallowed. */
  const [storeError, setStoreError] = useState<string | null>(null);

  useEffect(() => {
    // A rejection here used to leave `pairing` at `undefined` forever, and the
    // body renders a spinner in that state — so one keystore hiccup became an
    // app that loads for eternity with nothing on screen to say why. An
    // unreadable pairing means "not paired", which is a working app.
    void securePairingStore
      .load()
      .then(setPairing)
      .catch((cause: unknown) => {
        setStoreError(cause instanceof Error ? cause.message : String(cause));
        setPairing(null);
      });
  }, []);

  const [revision, setRevision] = useState(0);
  const bump = useCallback(() => setRevision((value) => value + 1), []);

  const transportRef = useRef<Transport | null>(null);
  const [transportRevision, setTransportRevision] = useState(0);

  useEffect(() => {
    if (pairing === undefined) return;
    const transport: Transport = pairing
      ? new RelayTransport(pairing)
      : loopbackTransport(runnerUrl);
    transportRef.current = transport;
    setTransportRevision((value) => value + 1);

    const offState = transport.onConnectionChange(setConnection);
    const offEvent = transport.onEvent((event) => {
      if (event.type === "command_error") {
        setRefusal(event.message);
        return;
      }
      if (event.type === "task_upsert") {
        setWaitingTasks((current) => {
          const others = current.filter((task) => task.id !== event.task_id);
          // Only unfinished tasks stay on the list. A task that just landed as
          // `applied` should clear its card, not sit there having been done.
          return event.status === "awaiting_review" || event.status === "running"
            ? [
                {
                  id: event.task_id,
                  status: event.status,
                  summary: event.summary,
                },
                ...others,
              ]
            : others;
        });
      }
      setRevision((value) => value + 1);
    });

    return () => {
      offState();
      offEvent();
      transport.close();
      transportRef.current = null;
    };
  }, [pairing, runnerUrl]);

  const [fleet, setFleet] = useState<FleetView | null>(null);
  const [fleetError, setFleetError] = useState<string | null>(null);
  const [session, setSession] = useState<SessionDetail | null>(null);
  const [waitingTasks, setWaitingTasks] = useState<WaitingTask[]>([]);
  const [task, setTask] = useState<TaskDetail | null>(null);

  useEffect(() => {
    const transport = transportRef.current;
    if (!transport) return;
    let live = true;
    transport
      .fleet()
      .then((next) => {
        if (!live) return;
        setFleet(next);
        setFleetError(null);
      })
      .catch((cause: unknown) => {
        if (live) {
          setFleetError(cause instanceof Error ? cause.message : String(cause));
        }
      });
    return () => {
      live = false;
    };
  }, [revision, transportRevision]);

  const sessionId = route.view === "session" ? route.id : null;
  useEffect(() => {
    const transport = transportRef.current;
    if (!transport || !sessionId) {
      setSession(null);
      return;
    }
    let live = true;
    transport
      .session(sessionId)
      .then((next) => live && setSession(next))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [sessionId, revision, transportRevision]);

  const taskId = route.view === "task" ? route.id : null;
  useEffect(() => {
    const transport = transportRef.current;
    if (!transport || !taskId) {
      setTask(null);
      return;
    }
    let live = true;
    transport
      .task(taskId)
      .then((next) => live && setTask(next))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [taskId, revision, transportRevision]);

  /**
   * The fleet's list of waiting change sets, plus anything an event has told us
   * about since. Snapshot first so its ordering (oldest waiting first) wins, and
   * de-duplicated by id — both sources describe the same task the moment a
   * refresh lands after an event.
   */
  const mergedWaiting = useMemo<WaitingTask[]>(() => {
    const byId = new Map<string, WaitingTask>();
    for (const task of fleet?.tasks_awaiting_review ?? []) {
      byId.set(task.id, {
        id: task.id,
        status: task.status,
        summary: task.change_summary,
      });
    }
    for (const task of waitingTasks) {
      if (!byId.has(task.id)) byId.set(task.id, task);
    }
    return [...byId.values()];
  }, [fleet, waitingTasks]);

  const title = useMemo(() => {
    switch (route.view) {
      case "fleet":
        return "RelayForge";
      case "session":
        return session?.repo_name ?? "Session";
      case "task":
        return task?.repo_name ?? "Review";
      case "pairing":
        return "Pair";
      case "watch":
        return "Watch";
    }
  }, [route, session, task]);

  const transport = transportRef.current;

  return (
    <SafeAreaProvider>
      <StatusBar style={scheme === "dark" ? "light" : "dark"} />
      <SafeAreaView style={{ flex: 1, backgroundColor: palette.bg }}>
        {/* ------------------------------------------------------- topbar */}
        <View
          style={{
            flexDirection: "row",
            alignItems: "center",
            gap: 10,
            paddingHorizontal: 16,
            paddingVertical: 10,
            borderBottomWidth: 1,
            borderBottomColor: palette.border,
          }}
        >
          {route.view !== "fleet" ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Back"
              onPress={() => setRoute({ view: "fleet" })}
              hitSlop={8}
            >
              <Text style={{ color: palette.series1, fontSize: 16 }}>‹ Back</Text>
            </Pressable>
          ) : null}

          <Text
            style={{
              flex: 1,
              color: palette.textPrimary,
              fontSize: 18,
              fontWeight: "700",
            }}
            numberOfLines={1}
          >
            {title}
          </Text>

          {connection !== "open" && route.view === "fleet" ? (
            <Text style={{ color: palette.textMuted, fontSize: 12 }}>
              reconnecting…
            </Text>
          ) : null}

          {route.view === "fleet" ? (
            <>
              <TopbarButton
                label={pairing ? "Paired" : "Pair this device"}
                glyph={pairing ? "🔗" : "⛓"}
                onPress={() => setRoute({ view: "pairing" })}
              />
              <TopbarButton
                label="Watch"
                glyph="⌚"
                onPress={() => setRoute({ view: "watch" })}
              />
            </>
          ) : null}
        </View>

        {/* -------------------------------------------------------- body */}
        {route.view === "pairing" ? (
          <PairingScreen
            palette={palette}
            pairing={pairing ?? null}
            runnerUrl={runnerUrl}
            onRunnerUrl={setRunnerUrl}
            onPaired={(next) => {
              setPairing(next);
              setRoute({ view: "fleet" });
            }}
            onUnpaired={() => {
              void securePairingStore.forget().then(() => setPairing(null));
            }}
          />
        ) : route.view === "watch" ? (
          <WatchScreen palette={palette} runnerUrl={runnerUrl} />
        ) : route.view === "task" ? (
          <TaskScreen
            task={task}
            transport={transport}
            palette={palette}
            onReviewed={() => {
              bump();
              setRoute({ view: "fleet" });
            }}
          />
        ) : route.view === "session" ? (
          <SessionScreen
            session={session}
            transport={transport}
            palette={palette}
            onChanged={bump}
          />
        ) : (
          <ScrollView
            contentContainerStyle={{ padding: 16, paddingBottom: 32 }}
            refreshControl={
              <RefreshControl refreshing={false} onRefresh={bump} />
            }
          >
            {refusal ? (
              <Banner
                palette={palette}
                title="The runner refused that."
                body={refusal}
                onDismiss={() => setRefusal(null)}
              />
            ) : null}

            {/* Change sets waiting on a decision sit above the sessions. An
                approval stalls one tool call; an unreviewed diff stalls a whole
                task that is already paid for.

                The fleet snapshot is the authority; `waitingTasks` adds the ones
                that arrived by event since the last fetch. Merged by id so a
                task cannot appear twice while both sources know about it. */}
            {mergedWaiting.map((waiting) => (
              <TaskCard
                key={waiting.id}
                palette={palette}
                task={waiting}
                onOpen={() => setRoute({ view: "task", id: waiting.id })}
              />
            ))}

            {storeError ? (
              <Banner
                palette={palette}
                title="Could not read the keystore."
                body={`${storeError} — carrying on as an unpaired device. Pairing again will try to write it afresh.`}
                onDismiss={() => setStoreError(null)}
              />
            ) : null}

            {/* Every spinner here says what it is waiting for. "Loading" with
                no subject is indistinguishable from a hang, and the two have
                completely different fixes. */}
            {pairing === undefined ? (
              <Waiting palette={palette} label="Reading the keystore…" />
            ) : fleetError ? (
              <Banner
                palette={palette}
                title="Cannot reach the runner."
                body={
                  pairing
                    ? fleetError
                    : `${fleetError} — set the address under Pair, or pair this device to reach it from anywhere.`
                }
                onDismiss={bump}
                dismissLabel="Retry"
              />
            ) : !fleet ? (
              <Waiting
                palette={palette}
                label={
                  pairing
                    ? "Connecting to the relay…"
                    : `Contacting ${runnerUrl}…`
                }
              />
            ) : (
              <>
                {fleet.pending_approvals.map((approval) => (
                  <ApprovalCard
                    key={approval.id}
                    approval={approval}
                    transport={transport}
                    palette={palette}
                    onDecided={bump}
                    showRepo
                  />
                ))}

                {fleet.sessions.length === 0 ? (
                  <Text
                    style={{
                      color: palette.textMuted,
                      textAlign: "center",
                      marginTop: 40,
                    }}
                  >
                    No sessions yet. Start one on the runner.
                  </Text>
                ) : (
                  fleet.sessions.map((item) => (
                    <SessionRow
                      key={item.id}
                      session={item}
                      palette={palette}
                      onOpen={() => setRoute({ view: "session", id: item.id })}
                    />
                  ))
                )}
              </>
            )}
          </ScrollView>
        )}

        {/* --------------------------------------------------- cost strip */}
        {route.view === "fleet" && fleet ? (
          <View
            style={{
              flexDirection: "row",
              justifyContent: "space-around",
              paddingVertical: 10,
              borderTopWidth: 1,
              borderTopColor: palette.border,
              backgroundColor: palette.surface1,
            }}
          >
            <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
              Today{" "}
              <Text style={{ color: palette.textPrimary, fontWeight: "700" }}>
                {usd(fleet.today_usd)}
              </Text>
            </Text>
            <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
              Cache hit{" "}
              <Text style={{ color: palette.textPrimary, fontWeight: "700" }}>
                {pct(fleet.cache_hit_ratio)}
              </Text>
            </Text>
          </View>
        ) : null}
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

/**
 * A change set waiting on a decision, on the fleet screen.
 *
 * The headline comes from the event rather than a fetch: `3 files, +42 −17` is
 * what a person needs to decide whether to open it, and shipping the diff to
 * every device on every state change would be the wrong trade for a line of
 * text.
 */
function TaskCard({
  palette,
  task,
  onOpen,
}: {
  palette: typeof light;
  task: WaitingTask;
  onOpen: () => void;
}) {
  const working = task.status === "running";

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={
        working
          ? "A task is working. Open it."
          : `A change set is waiting: ${task.summary}. Open it to review.`
      }
      onPress={onOpen}
      style={{
        minHeight: TAP,
        padding: 14,
        marginBottom: 12,
        borderRadius: 12,
        backgroundColor: palette.surface1,
        borderWidth: 1,
        borderColor: palette.border,
        // The amber edge is the same signal an approval card carries, and the
        // words below say the same thing — colour is never alone.
        borderLeftWidth: 3,
        borderLeftColor: working ? palette.textMuted : palette.warning,
      }}
    >
      <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
        {working ? "Working…" : "A change set is waiting"}
      </Text>
      <Text style={{ color: palette.textSecondary, marginTop: 4, fontSize: 13 }}>
        {working ? "Nothing to review yet." : task.summary}
      </Text>
      <Text style={{ color: palette.series1, marginTop: 6, fontSize: 13 }}>
        {working ? "Watch it →" : "Review the diff →"}
      </Text>
    </Pressable>
  );
}

/**
 * A spinner that says what it is waiting for.
 *
 * A bare `ActivityIndicator` is the same pixels whether a request is in flight
 * or the app has wedged, and the two need opposite responses from the person
 * looking at it.
 */
function Waiting({
  palette,
  label,
}: {
  palette: typeof light;
  label: string;
}) {
  return (
    <View style={{ marginTop: 32, alignItems: "center", gap: 10 }}>
      <ActivityIndicator />
      <Text style={{ color: palette.textMuted, fontSize: 13 }}>{label}</Text>
    </View>
  );
}

function TopbarButton({
  label,
  glyph,
  onPress,
}: {
  label: string;
  glyph: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      hitSlop={8}
      style={{
        minWidth: TAP - 12,
        minHeight: TAP - 12,
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <Text style={{ fontSize: 18 }}>{glyph}</Text>
    </Pressable>
  );
}

export function Banner({
  palette,
  title,
  body,
  onDismiss,
  dismissLabel = "Dismiss",
}: {
  palette: typeof light;
  title: string;
  body: string;
  onDismiss: () => void;
  dismissLabel?: string;
}) {
  return (
    <View
      style={{
        backgroundColor: palette.surface1,
        borderRadius: 14,
        borderLeftWidth: 3,
        borderLeftColor: palette.critical,
        padding: 14,
        marginBottom: 12,
        gap: 6,
      }}
    >
      <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
        {title}
      </Text>
      <Text style={{ color: palette.textSecondary, fontSize: 13 }}>{body}</Text>
      <Pressable
        accessibilityRole="button"
        onPress={onDismiss}
        style={{ minHeight: TAP, justifyContent: "center" }}
      >
        <Text style={{ color: palette.series1 }}>{dismissLabel}</Text>
      </Pressable>
    </View>
  );
}

