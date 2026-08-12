/**
 * Signing in, choosing a machine, and the workspace.
 *
 * The phone's version of what the web app shows, cut to what a phone is for.
 * There is no billing here and no member management: those are decisions made
 * sitting down, and putting a Stripe checkout behind a 44-pixel tap on a train
 * is how somebody buys the wrong plan. The phone can see the plan and say where
 * to change it.
 *
 * What *is* here is everything that unblocks work: sign in, pick a machine,
 * confirm a machine whose identity changed, sign out.
 */

import { useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  Text,
  TextInput,
  View,
} from "react-native";
import {
  describeLimit,
  subscriptionNotice,
  type CloudClient,
  type RunnerView,
  type Workspace,
} from "@relayforge/client-core";
import { Button, Card } from "./Pairing";
import { TAP, type Palette } from "../theme";

/* ------------------------------------------------------------------ sign in */

export function SignInScreen({
  palette,
  cloudUrl,
  onCloudUrl,
  onSubmit,
  busy,
  error,
  onUseLocal,
}: {
  palette: Palette;
  cloudUrl: string;
  onCloudUrl: (next: string) => void;
  onSubmit: (input: {
    mode: "sign-in" | "sign-up";
    email: string;
    password: string;
    name: string;
  }) => void;
  busy: boolean;
  error: string | null;
  onUseLocal: () => void;
}) {
  const [mode, setMode] = useState<"sign-in" | "sign-up">("sign-in");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [advanced, setAdvanced] = useState(false);

  const signingUp = mode === "sign-up";
  // Mirrors `forge_cloud::secret::MIN_PASSWORD_LEN`, so the rule is visible
  // while typing rather than as a rejection after pressing the button.
  const tooShort = signingUp && password.length > 0 && password.length < 10;
  const ready =
    email.trim().length > 0 &&
    password.length > 0 &&
    !tooShort &&
    (!signingUp || name.trim().length > 0);

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      <View style={{ alignItems: "center", paddingVertical: 24 }}>
        <Text style={{ color: palette.series1, fontSize: 36 }}>◈</Text>
        <Text
          style={{
            color: palette.textPrimary,
            fontSize: 20,
            fontWeight: "700",
            marginTop: 12,
            textAlign: "center",
            letterSpacing: -0.3,
          }}
        >
          Supervise your agents
        </Text>
        <Text
          style={{
            color: palette.textSecondary,
            fontSize: 14,
            marginTop: 6,
            textAlign: "center",
            lineHeight: 20,
          }}
        >
          Approve a command, review a diff, see what it cost — while the work
          keeps running on your own machine.
        </Text>
      </View>

      <Card palette={palette}>
        <Segmented
          palette={palette}
          options={[
            { key: "sign-in", label: "Sign in" },
            { key: "sign-up", label: "Create account" },
          ]}
          value={mode}
          onChange={(next) => setMode(next as "sign-in" | "sign-up")}
        />

        {signingUp ? (
          <Labelled palette={palette} label="Your name">
            <Input
              palette={palette}
              value={name}
              onChangeText={setName}
              placeholder="Harsh"
              autoComplete="name"
            />
          </Labelled>
        ) : null}

        <Labelled palette={palette} label="Email">
          <Input
            palette={palette}
            value={email}
            onChangeText={setEmail}
            placeholder="you@example.com"
            keyboardType="email-address"
            autoComplete="email"
          />
        </Labelled>

        <Labelled palette={palette} label="Password">
          <Input
            palette={palette}
            value={password}
            onChangeText={setPassword}
            placeholder={signingUp ? "At least 10 characters" : ""}
            secureTextEntry
            autoComplete={signingUp ? "new-password" : "current-password"}
          />
        </Labelled>

        {tooShort ? (
          <Text style={{ color: palette.textMuted, fontSize: 12 }}>
            {10 - password.length} more character
            {10 - password.length === 1 ? "" : "s"} — length is what actually
            makes a password hard to guess.
          </Text>
        ) : null}

        {error ? (
          <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
        ) : null}

        <Button
          palette={palette}
          label={signingUp ? "Create account" : "Sign in"}
          busy={busy}
          disabled={!ready || busy}
          onPress={() =>
            onSubmit({
              mode,
              email: email.trim(),
              password,
              name: name.trim(),
            })
          }
        />
      </Card>

      <Pressable
        onPress={() => setAdvanced((open) => !open)}
        style={{ minHeight: TAP, justifyContent: "center" }}
      >
        <Text style={{ color: palette.textMuted, fontSize: 13 }}>
          {advanced ? "− " : "+ "}Self-hosted? Change the server
        </Text>
      </Pressable>

      {advanced ? (
        <Card palette={palette}>
          <Labelled palette={palette} label="Server">
            <Input
              palette={palette}
              value={cloudUrl}
              onChangeText={onCloudUrl}
              placeholder="https://farhelm.aurovie.com"
              keyboardType="url"
            />
          </Labelled>
          <Text style={{ color: palette.textMuted, fontSize: 12 }}>
            Where your accounts live. Your code never goes there — this phone and
            your machine exchange keys directly and the server carries ciphertext
            it cannot read.
          </Text>
          <Button
            palette={palette}
            label="Use a runner on this network instead"
            tone="quiet"
            onPress={onUseLocal}
          />
        </Card>
      ) : null}
    </ScrollView>
  );
}

/* ------------------------------------------------------------ machine picker */

export function MachinePickerScreen({
  palette,
  runners,
  onPick,
  onAddMachine,
}: {
  palette: Palette;
  runners: RunnerView[];
  onPick: (runnerId: string) => void;
  onAddMachine: () => void;
}) {
  if (runners.length === 0) {
    return (
      <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
        <Card palette={palette}>
          <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
            No machines yet
          </Text>
          <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
            A machine joins your workspace by running the daemon with an
            enrolment key. Create one in the web app — it takes one command on
            the machine and nothing on this phone.
          </Text>
          <Button palette={palette} label="How" onPress={onAddMachine} tone="quiet" />
        </Card>
      </ScrollView>
    );
  }

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          Which machine?
        </Text>
        {runners.map((runner) => (
          <Pressable
            key={runner.id}
            accessibilityRole="button"
            disabled={runner.needs_key_approval}
            onPress={() => onPick(runner.id)}
            style={({ pressed }) => ({
              minHeight: TAP,
              flexDirection: "row",
              alignItems: "center",
              gap: 10,
              paddingHorizontal: 12,
              borderRadius: 10,
              borderWidth: 1,
              borderColor: palette.border,
              backgroundColor: pressed ? palette.surface2 : palette.surface1,
              opacity: runner.needs_key_approval ? 0.5 : 1,
            })}
          >
            <View
              style={{
                width: 8,
                height: 8,
                borderRadius: 4,
                backgroundColor: runner.online ? palette.good : palette.textMuted,
              }}
            />
            <Text style={{ color: palette.textPrimary, fontWeight: "600", flex: 1 }}>
              {runner.name}
            </Text>
            <Text style={{ color: palette.textMuted, fontSize: 12 }}>
              {runner.needs_key_approval
                ? "needs confirming"
                : runner.online
                  ? "online"
                  : "offline"}
            </Text>
          </Pressable>
        ))}
      </Card>
    </ScrollView>
  );
}

/* ---------------------------------------------------------------- workspace */

export function WorkspaceScreen({
  palette,
  workspace,
  cloud,
  activeRunnerId,
  onPickRunner,
  onChanged,
  onSignOut,
}: {
  palette: Palette;
  workspace: Workspace;
  cloud: CloudClient;
  activeRunnerId: string | null;
  onPickRunner: (runnerId: string) => void;
  onChanged: () => void;
  onSignOut: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const notice = subscriptionNotice(workspace.subscription);

  const approveKey = (runnerId: string) => {
    setBusy(runnerId);
    setError(null);
    cloud
      .approveRunnerKey(runnerId)
      .then(onChanged)
      .catch((cause: unknown) =>
        setError(cause instanceof Error ? cause.message : String(cause)),
      )
      .finally(() => setBusy(null));
  };

  return (
    <ScrollView contentContainerStyle={{ padding: 16, gap: 12 }}>
      {notice ? (
        <Card palette={palette}>
          <Text style={{ color: palette.textSecondary, fontSize: 13 }}>{notice}</Text>
        </Card>
      ) : null}

      {error ? (
        <Card palette={palette}>
          <Text style={{ color: palette.critical, fontSize: 13 }}>{error}</Text>
        </Card>
      ) : null}

      <Card palette={palette}>
        <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <Text style={{ color: palette.textPrimary, fontWeight: "600", flex: 1 }}>
            {workspace.org.name}
          </Text>
          <Text
            style={{
              color: palette.textSecondary,
              fontSize: 11,
              fontWeight: "700",
              letterSpacing: 0.6,
              paddingHorizontal: 8,
              paddingVertical: 3,
              borderRadius: 999,
              borderWidth: 1,
              borderColor: palette.border,
              backgroundColor: palette.surface2,
              overflow: "hidden",
            }}
          >
            {workspace.subscription.plan.toUpperCase()}
          </Text>
        </View>
        <Text style={{ color: palette.textMuted, fontSize: 12 }}>
          {workspace.account.email} · {workspace.role}
        </Text>

        <View style={{ flexDirection: "row", gap: 8 }}>
          <Stat
            palette={palette}
            label="Machines"
            value={`${workspace.usage.runners}/${describeLimit(workspace.limits.runners)}`}
          />
          <Stat
            palette={palette}
            label="Devices"
            value={`${workspace.usage.devices}/${describeLimit(workspace.limits.devices)}`}
          />
          <Stat
            palette={palette}
            label="People"
            value={`${workspace.usage.members}/${describeLimit(workspace.limits.members)}`}
          />
        </View>

        <Text style={{ color: palette.textMuted, fontSize: 12 }}>
          Plans and people are managed in the web app — those are decisions worth
          making sitting down.
        </Text>
      </Card>

      <Card palette={palette}>
        <Text style={{ color: palette.textPrimary, fontWeight: "600" }}>
          Machines
        </Text>
        {workspace.runners.map((runner) => (
          <View key={runner.id} style={{ gap: 6 }}>
            <View style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
              <View
                style={{
                  width: 8,
                  height: 8,
                  borderRadius: 4,
                  backgroundColor: runner.online ? palette.good : palette.textMuted,
                }}
              />
              <Text
                style={{ color: palette.textPrimary, fontWeight: "600", flex: 1 }}
              >
                {runner.name}
              </Text>
              {activeRunnerId === runner.id ? (
                <Text style={{ color: palette.series1, fontSize: 12 }}>
                  watching
                </Text>
              ) : (
                <Pressable
                  onPress={() => onPickRunner(runner.id)}
                  disabled={runner.needs_key_approval}
                  style={{ minHeight: 32, justifyContent: "center" }}
                >
                  <Text
                    style={{
                      color: runner.needs_key_approval
                        ? palette.textMuted
                        : palette.series1,
                      fontSize: 13,
                    }}
                  >
                    Watch
                  </Text>
                </Pressable>
              )}
            </View>

            {runner.needs_key_approval ? (
              <View
                style={{
                  padding: 10,
                  borderRadius: 10,
                  backgroundColor: palette.surface2,
                  gap: 8,
                }}
              >
                <Text style={{ color: palette.textPrimary, fontSize: 13 }}>
                  This machine&rsquo;s identity changed.
                </Text>
                <Text style={{ color: palette.textSecondary, fontSize: 12 }}>
                  It is offering a different key from the one on file. That is
                  what a reinstall looks like — and also what somebody standing
                  in front of it looks like.
                </Text>
                {workspace.role === "admin" || workspace.role === "owner" ? (
                  <Button
                    palette={palette}
                    label="That was me — accept it"
                    busy={busy === runner.id}
                    disabled={busy !== null}
                    onPress={() => approveKey(runner.id)}
                  />
                ) : (
                  <Text style={{ color: palette.textMuted, fontSize: 12 }}>
                    An admin has to confirm it.
                  </Text>
                )}
              </View>
            ) : null}
          </View>
        ))}
      </Card>

      <Card palette={palette}>
        <Text style={{ color: palette.textSecondary, fontSize: 13 }}>
          Signed in on {workspace.devices.length} device
          {workspace.devices.length === 1 ? "" : "s"}. Removing this one in the
          web app stops it decrypting anything new within fifteen minutes.
        </Text>
        <Button palette={palette} label="Sign out" tone="danger" onPress={onSignOut} />
      </Card>
    </ScrollView>
  );
}

/* ---------------------------------------------------------------- furniture */

function Stat({
  palette,
  label,
  value,
}: {
  palette: Palette;
  label: string;
  value: string;
}) {
  return (
    <View
      style={{
        flex: 1,
        padding: 10,
        borderRadius: 10,
        backgroundColor: palette.surface2,
      }}
    >
      <Text style={{ color: palette.textMuted, fontSize: 11 }}>{label}</Text>
      <Text
        style={{
          color: palette.textPrimary,
          fontSize: 16,
          fontWeight: "700",
          fontVariant: ["tabular-nums"],
        }}
      >
        {value}
      </Text>
    </View>
  );
}

function Labelled({
  palette,
  label,
  children,
}: {
  palette: Palette;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <View style={{ gap: 4 }}>
      <Text style={{ color: palette.textSecondary, fontSize: 12 }}>{label}</Text>
      {children}
    </View>
  );
}

/**
 * A text field for words rather than keys.
 *
 * `Field` in `components/pieces` is monospace, which is right for a pasted key
 * and wrong for an email address — proportional type is what makes a name look
 * like a name.
 */
function Input({
  palette,
  ...props
}: {
  palette: Palette;
} & React.ComponentProps<typeof TextInput>) {
  return (
    <TextInput
      {...props}
      placeholderTextColor={palette.textMuted}
      autoCapitalize="none"
      autoCorrect={false}
      style={{
        minHeight: TAP,
        paddingHorizontal: 12,
        borderRadius: 10,
        borderWidth: 1,
        borderColor: palette.border,
        backgroundColor: palette.surface2,
        color: palette.textPrimary,
        fontSize: 15,
      }}
    />
  );
}

function Segmented({
  palette,
  options,
  value,
  onChange,
}: {
  palette: Palette;
  options: Array<{ key: string; label: string }>;
  value: string;
  onChange: (next: string) => void;
}) {
  return (
    <View
      style={{
        flexDirection: "row",
        gap: 4,
        padding: 4,
        borderRadius: 10,
        backgroundColor: palette.surface2,
      }}
    >
      {options.map((option) => {
        const active = option.key === value;
        return (
          <Pressable
            key={option.key}
            accessibilityRole="tab"
            accessibilityState={{ selected: active }}
            onPress={() => onChange(option.key)}
            style={{
              flex: 1,
              minHeight: 36,
              alignItems: "center",
              justifyContent: "center",
              borderRadius: 8,
              backgroundColor: active ? palette.surface1 : "transparent",
            }}
          >
            <Text
              style={{
                color: active ? palette.textPrimary : palette.textSecondary,
                fontWeight: active ? "600" : "500",
                fontSize: 14,
              }}
            >
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

/** Kept so a caller can show a spinner without importing React Native here. */
export function Spinner({ palette }: { palette: Palette }) {
  return <ActivityIndicator color={palette.series1} />;
}
