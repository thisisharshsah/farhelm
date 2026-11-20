import { useState, type FormEvent } from "react";
import { api } from "../../client/http.ts";
import { DeviceLookup } from "../../shared/api.ts";
import { formatUserCode, normalizeUserCode } from "../../shared/deviceCode.ts";
import type { PageProps } from "../App.tsx";
import { timeAgo } from "../format.ts";
import { navigate } from "../router.tsx";
import { Button, Card, ErrorNote, Icon, PageHeader, useAction } from "../ui.tsx";

type Step =
  | { kind: "enter" }
  | { kind: "confirm"; code: string; device: DeviceLookup }
  | { kind: "done"; approved: boolean; name: string };

/** As the person types: uppercase, consonants only, a dash after four. */
function tidy(raw: string): string {
  const letters = raw.toUpperCase().replace(/[^A-Z]/g, "").slice(0, 8);
  return letters.length > 4 ? `${letters.slice(0, 4)}-${letters.slice(4)}` : letters;
}

export function LinkGlasses(_: PageProps) {
  const [step, setStep] = useState<Step>({ kind: "enter" });
  const [code, setCode] = useState("");

  const lookup = useAction(async () => {
    const normalized = normalizeUserCode(code);
    if (!normalized) throw new Error("Enter the 8-letter code your glasses show, like BCDF-GHJK.");
    const device = await api("/api/device/lookup", { method: "POST", body: { userCode: normalized }, schema: DeviceLookup });
    setStep({ kind: "confirm", code: normalized, device });
  });

  const decide = useAction(async (approve: boolean) => {
    if (step.kind !== "confirm") return;
    await api("/api/device/decide", {
      method: "POST",
      body: { userCode: step.code, decision: approve ? "approve" : "deny" },
    });
    setStep({ kind: "done", approved: approve, name: step.device.clientName });
  });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    void lookup.run();
  };

  return (
    <>
      <PageHeader title="Link glasses" description="Sign your glasses in to this account, without typing on them." back={{ to: "/account", label: "Account" }} />
      <div className="stack-lg">
        {step.kind === "enter" ? (
          <Card>
            <form className="stack" onSubmit={submit}>
              <label className="field" htmlFor="code">
                <span className="field-label">Code shown on your glasses</span>
                <input
                  id="code"
                  className="code-input"
                  value={code}
                  onChange={(e) => setCode(tidy(e.target.value))}
                  placeholder="BCDF-GHJK"
                  autoComplete="one-time-code"
                  autoCapitalize="characters"
                  spellCheck={false}
                  inputMode="text"
                  autoFocus
                  required
                />
                <span className="field-hint">Open Lens on your glasses to see it. Codes last ten minutes.</span>
              </label>
              <Button type="submit" variant="primary" size="lg" busy={lookup.busy} className="wide" icon="arrow">
                Continue
              </Button>
            </form>
            <ErrorNote message={lookup.error} />
          </Card>
        ) : step.kind === "confirm" ? (
          <Card>
            <div className="confirm">
              <span className="confirm-icon">
                <Icon name="glasses" size={28} />
              </span>
              <h2>Link {step.device.clientName}?</h2>
              <p>
                Code <strong className="mono">{formatUserCode(step.code)}</strong>, requested {timeAgo(step.device.createdAt)}.
              </p>
              <p className="warning">
                <Icon name="alert" />
                Only continue if this code is on your own glasses right now. Linking gives them access to your notes and apps.
              </p>
              <div className="button-row">
                <Button variant="secondary" size="lg" onClick={() => void decide.run(false)} disabled={decide.busy}>
                  Decline
                </Button>
                <Button variant="primary" size="lg" icon="check" busy={decide.busy} onClick={() => void decide.run(true)}>
                  Link glasses
                </Button>
              </div>
              <ErrorNote message={decide.error} />
            </div>
          </Card>
        ) : (
          <Card>
            <div className="confirm">
              <span className={`confirm-icon ${step.approved ? "ok" : ""}`}>
                <Icon name={step.approved ? "check" : "alert"} size={28} />
              </span>
              <h2>{step.approved ? "Linked" : "Declined"}</h2>
              <p>
                {step.approved
                  ? `${step.name} will open Lens in a few seconds.`
                  : `${step.name} was not linked. The code no longer works.`}
              </p>
              <div className="button-row">
                <Button
                  variant="secondary"
                  onClick={() => {
                    setCode("");
                    setStep({ kind: "enter" });
                  }}
                >
                  Link another
                </Button>
                <Button variant="primary" onClick={() => navigate("/devices")}>
                  See devices
                </Button>
              </div>
            </div>
          </Card>
        )}
      </div>
    </>
  );
}
