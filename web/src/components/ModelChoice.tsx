/**
 * Choosing how a request is answered: its mode (Ask, Plan, Agent, Review)
 * and, when the default is not wanted, the model.
 *
 * The runner's registry says which model answers each mode (`/v1/modes`);
 * the pickers only offer what it lists. A reply or task then shows the mode
 * and the model it was asked for, so what ran is never a guess.
 */

import { useEffect, useState } from "react";
import type { ModesView, Transport, WorkMode } from "@farhelm/client-core";

/** What the runner offers, once per transport. `null` until it answers. */
export function useModes(transport: Transport | null): ModesView | null {
  const [modes, setModes] = useState<ModesView | null>(null);
  useEffect(() => {
    setModes(null);
    if (!transport || typeof transport.modes !== "function") return;
    let cancelled = false;
    transport.modes()
      .then((view) => { if (!cancelled) setModes(view); })
      .catch(() => { /* Without the list, requests use the mode's default. */ });
    return () => { cancelled = true; };
  }, [transport]);
  return modes;
}

/** The mode's default model name, when the runner has said. */
export function defaultModel(modes: ModesView | null, mode: WorkMode): string | null {
  return modes?.modes.find((item) => item.mode === mode)?.model ?? null;
}

export function modeLabel(mode: WorkMode): string {
  return { ask: "Ask", plan: "Plan", agent: "Agent", review: "Review" }[mode];
}

/** A segmented control over the modes a place offers. */
export function ModePicker({ value, options, modes, onChange, disabled }: {
  value: WorkMode;
  options: readonly WorkMode[];
  modes: ModesView | null;
  onChange: (mode: WorkMode) => void;
  disabled?: boolean;
}) {
  return (
    <div className="mode-picker" role="radiogroup" aria-label="Mode">
      {options.map((mode) => {
        const model = defaultModel(modes, mode);
        return (
          <button
            key={mode}
            type="button"
            role="radio"
            aria-checked={mode === value}
            title={model ? `${modeLabel(mode)} answers with ${model}` : modeLabel(mode)}
            disabled={disabled}
            onClick={() => onChange(mode)}
          >
            {modeLabel(mode)}
          </button>
        );
      })}
    </div>
  );
}

/**
 * The model for one request. Empty means the mode's default, which the first
 * option names so "default" is never a mystery.
 */
export function ModelPicker({ value, mode, modes, onChange, disabled, id }: {
  value: string;
  mode: WorkMode;
  modes: ModesView | null;
  onChange: (model: string) => void;
  disabled?: boolean;
  id?: string;
}) {
  if (!modes || modes.models.length === 0) return null;
  const fallback = defaultModel(modes, mode);
  const aliases = modes.models.filter((choice) => choice.alias);
  const own = modes.models.filter((choice) => !choice.alias);
  return (
    <select
      id={id}
      className="composer-field model-picker"
      aria-label="Model"
      value={value}
      onChange={(event) => onChange(event.target.value)}
      disabled={disabled}
    >
      <option value="">{fallback ? `Default (${fallback})` : "Default model"}</option>
      {aliases.length > 0 ? (
        <optgroup label="By purpose">
          {aliases.map((choice) => (
            <option key={choice.name} value={choice.name}>{choice.name} · {choice.deployment}</option>
          ))}
        </optgroup>
      ) : null}
      {own.length > 0 ? (
        <optgroup label="Models">
          {own.map((choice) => <option key={choice.name} value={choice.name}>{choice.name}</option>)}
        </optgroup>
      ) : null}
    </select>
  );
}

/** "Plan · gpt-oss-20b": how a reply or task was made. */
export function ModeTag({ mode, model }: { mode?: WorkMode | null; model?: string | null }) {
  if (!mode && !model) return null;
  return (
    <span className="mode-tag">
      {mode ? modeLabel(mode) : null}
      {mode && model ? " · " : null}
      {model ? <span className="mode-tag-model">{model}</span> : null}
    </span>
  );
}
