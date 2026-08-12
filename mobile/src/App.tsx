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
  CloudClient,
  RelayTransport,
  pct,
  usd,
  type CloudSession,
  type ConnectionState,
  type FleetView,
  type Pairing,
  type SessionDetail,
  type TaskDetail,
  type TaskStatus,
  type Transport,
  type Workspace,
} from "@relayforge/client-core";
import { loopbackTransport, phoneIdentity, securePairingStore } from "./platform";
import {
  DEFAULT_CLOUD_URL,
  cloudClient,
  deviceName,
  secureCloudSessionStore,
} from "./cloud";
import { ApprovalCard, SessionRow } from "./components/pieces";
import {
  MachinePickerScreen,
  SignInScreen,
  WorkspaceScreen,
} from "./screens/Account";
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
  | { view: "workspace" }
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

  /**
   * The signed-in workspace, when there is one.
   *
   * `undefined` here means the same thing as it does for `pairing`: the
   * keystore has not answered yet. Three states rather than two, because
   * "signed out" and "not read yet" want completely different screens.
   */
  const [cloudSession, setCloudSession] = useState<CloudSession | null | undefined>(
    undefined,
  );
  const [cloudUrl, setCloudUrl] = useState(DEFAULT_CLOUD_URL);
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [activeRunnerId, setActiveRunnerId] = useState<string | null>(null);
  const [authBusy, setAuthBusy] = useState(false);
  const [authError, setAuthError] = useState<string | null>(null);
  /** Set once the user has chosen the local runner instead of an account. */
  const [localOnly, setLocalOnly] = useState(false);
  /** Bumped to re-read the workspace after a change made on the workspace tab. */
  const [workspaceRevision, setWorkspaceRevision] = useState(0);
  const cloudRef = useRef<CloudClient | null>(null);

  useEffect(() => {
    // A rejection here used to leave `pairing` at `undefined` forever, and the
    // body renders a spinner in that state — so one keystore hiccup became an
    // app that loads for eternity with nothing on screen to say why. An
    // unreadable pairing means "not paired", which is a working app.
    void Promise.all([
      secureCloudSessionStore.load().catch(() => null),
      securePairingStore.load().catch((cause: unknown) => {
        setStoreError(cause instanceof Error ? cause.message : String(cause));
        return null;
      }),
    ]).then(([session, stored]) => {
      setCloudSession(session);
      setPairing(stored);
      if (session) cloudRef.current = cloudClient(session);
    });
  }, []);

  /** Read the workspace whenever there is a session to read it with. */
  useEffect(() => {
    if (!cloudSession || !cloudRef.current) return;
    let live = true;

    cloudRef.current
      .workspace()
      .then((next) => {
        if (!live) return;
        setWorkspace(next);
        // One machine is not a choice worth making anyone make.
        setActiveRunnerId((current) => {
          if (current && next.runners.some((runner) => runner.id === current)) {
            return current;
          }
          return next.runners.length === 1 ? next.runners[0]!.id : null;
        });
      })
      .catch((cause: unknown) => {
        if (!live) return;
        const message = cause instanceof Error ? cause.message : String(cause);
        // A dead session is a sign-in problem, not an error over an empty
        // fleet. Drop it and show the front door.
        if (/sign in|expired/i.test(message)) {
          void secureCloudSessionStore.clear();
          cloudRef.current = null;
          setCloudSession(null);
          setWorkspace(null);
        } else {
          setAuthError(message);
        }
      });

    return () => {
      live = false;
    };
  }, [cloudSession, workspaceRevision]);

  const [revision, setRevision] = useState(0);
  const bump = useCallback(() => setRevision((value) => value + 1), []);

  const transportRef = useRef<Transport | null>(null);
  const [transportRevision, setTransportRevision] = useState(0);

  const activeRunner =
    workspace?.runners.find((runner) => runner.id === activeRunnerId) ?? null;

  useEffect(() => {
    if (pairing === undefined || cloudSession === undefined) return;

    let transport: Transport;
    // `deviceId` empty means this phone holds no seat — there is no key a
    // runner would seal to, so it falls through to the signed-in-idle branch
    // instead of dialling a link that can only fail.
    if (cloudSession?.deviceId && activeRunner && workspace && cloudRef.current) {
      const cloud = cloudRef.current;
      const session = cloudSession;
      const runner = activeRunner;
      // A relay seat lives fifteen minutes and this phone reconnects for days,
      // so the transport is handed a function rather than a token and asks for
      // a fresh one every time it dials.
      transport = new RelayTransport(
        {
          relayUrl: workspace.relay_url,
          channel: runner.channel,
          runnerPublicKey: runner.public_key,
          deviceId: session.deviceId,
          secret: session.deviceSecret,
        },
        async () => {
          const seat = await cloud.channelToken(runner.id, session.deviceId);
          return seat.token;
        },
      );
    } else if (cloudSession) {
      // Signed in with no machine chosen: nothing to dial, and the body shows
      // the picker instead of a fleet that cannot load.
      return;
    } else if (pairing) {
      transport = new RelayTransport(pairing);
    } else {
      transport = loopbackTransport(runnerUrl);
    }

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
    // `workspace` is a dependency because the machine's channel and pinned key
    // come from it — a key rotation confirmed elsewhere must rebuild the link.
  }, [pairing, runnerUrl, cloudSession, activeRunner, workspace]);

  /* ------------------------------------------------------------ sign in */

  const signIn = useCallback(
    (input: {
      mode: "sign-in" | "sign-up";
      email: string;
      password: string;
      name: string;
    }) => {
      setAuthBusy(true);
      setAuthError(null);

      // A fresh client with no stored token: signing in as somebody else must
      // not inherit the previous session's refresh token.
      let latestRefresh = "";
      const cloud = new CloudClient(cloudUrl, null, (token) => {
        latestRefresh = token;
      });

      void (async () => {
        const next =
          input.mode === "sign-up"
            ? await cloud.signUp({
                email: input.email,
                password: input.password,
                name: input.name,
                deviceLabel: deviceName(),
              })
            : await cloud.signIn({
                email: input.email,
                password: input.password,
                deviceLabel: deviceName(),
              });

        // This phone's key, created once and reused. Only its public half is
        // ever sent, so the control plane still cannot read anything.
        const identity = await phoneIdentity();

        // A refused registration must not fail the sign-in. Being over the
        // device limit is exactly when someone needs to get in and free a seat,
        // and failing here locks every surface at once.
        let deviceId = "";
        try {
          deviceId = (
            await cloud.registerDevice({
              kind: "phone",
              name: deviceName(),
              publicKey: identity.publicKey,
            })
          ).id;
        } catch {
          // Surfaced by the fleet screen, which shows the link as unavailable
          // rather than retrying against a key no runner would seal to.
        }

        const session: CloudSession = {
          baseUrl: cloudUrl,
          refreshToken: latestRefresh,
          accountId: next.account.id,
          orgId: next.org.id,
          deviceId,
          deviceSecret: identity.toSecret(),
        };
        await secureCloudSessionStore.save(session);

        // Re-created so its rotation callback writes to the session that now
        // exists; the one above only had a local variable to write to.
        cloudRef.current = cloudClient(session);
        setCloudSession(session);
        setWorkspace(next);
        setActiveRunnerId(next.runners.length === 1 ? next.runners[0]!.id : null);
        setRoute({ view: "fleet" });
      })()
        .catch((cause: unknown) =>
          setAuthError(cause instanceof Error ? cause.message : String(cause)),
        )
        .finally(() => setAuthBusy(false));
    },
    [cloudUrl],
  );

  const signOut = useCallback(() => {
    void cloudRef.current?.signOut().finally(async () => {
      await secureCloudSessionStore.clear();
      cloudRef.current = null;
      setCloudSession(null);
      setWorkspace(null);
      setActiveRunnerId(null);
      setLocalOnly(false);
      setRoute({ view: "fleet" });
    });
  }, []);

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
      case "workspace":
        return workspace?.org.name ?? "Workspace";
      case "watch":
        return "Watch";
    }
  }, [route, session, task, workspace]);

  const transport = transportRef.current;

  /* --------------------------------------------------------- front door */

  // Nothing decided yet: signed out, never paired, and not told to stay local.
  const atFrontDoor =
    cloudSession === null && pairing === null && !localOnly;

  if (cloudSession === undefined || pairing === undefined) {
    return (
      <SafeAreaProvider>
        <StatusBar style={scheme === "dark" ? "light" : "dark"} />
        <SafeAreaView
          style={{
            flex: 1,
            backgroundColor: palette.bg,
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <ActivityIndicator color={palette.series1} />
          <Text style={{ color: palette.textMuted, fontSize: 13, marginTop: 12 }}>
            Reading the keystore…
          </Text>
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

  if (atFrontDoor) {
    return (
      <SafeAreaProvider>
        <StatusBar style={scheme === "dark" ? "light" : "dark"} />
        <SafeAreaView style={{ flex: 1, backgroundColor: palette.bg }}>
          <SignInScreen
            palette={palette}
            cloudUrl={cloudUrl}
            onCloudUrl={setCloudUrl}
            onSubmit={signIn}
            busy={authBusy}
            error={authError}
            onUseLocal={() => setLocalOnly(true)}
          />
        </SafeAreaView>
      </SafeAreaProvider>
    );
  }

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
              {cloudSession ? (
                <TopbarButton
                  label={workspace?.org.name ?? "Workspace"}
                  glyph="◈"
                  onPress={() => setRoute({ view: "workspace" })}
                />
              ) : (
                <TopbarButton
                  label={pairing ? "Paired" : "Pair this device"}
                  glyph={pairing ? "🔗" : "⛓"}
                  onPress={() => setRoute({ view: "pairing" })}
                />
              )}
              <TopbarButton
                label="Watch"
                glyph="⌚"
                onPress={() => setRoute({ view: "watch" })}
              />
            </>
          ) : null}
        </View>

        {/* -------------------------------------------------------- body */}
        {route.view === "workspace" && workspace && cloudRef.current ? (
          <WorkspaceScreen
            palette={palette}
            workspace={workspace}
            cloud={cloudRef.current}
            activeRunnerId={activeRunnerId}
            onPickRunner={(id) => {
              setActiveRunnerId(id);
              setRoute({ view: "fleet" });
            }}
            onChanged={() => setWorkspaceRevision((value) => value + 1)}
            onSignOut={signOut}
          />
        ) : /* Signed in with no machine chosen: the picker replaces the fleet,
              because there is genuinely nothing to show until one is. */
        cloudSession && !activeRunner && route.view === "fleet" ? (
          <MachinePickerScreen
            palette={palette}
            runners={workspace?.runners ?? []}
            onPick={setActiveRunnerId}
            onAddMachine={() => setRoute({ view: "workspace" })}
          />
        ) : route.view === "pairing" ? (
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

