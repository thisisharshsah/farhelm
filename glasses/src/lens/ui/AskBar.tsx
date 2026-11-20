import { MicIcon, PenLineIcon, SparklesIcon } from "lucide-react";
import { forwardRef, useEffect, useImperativeHandle, useRef, type FocusEventHandler, type ReactNode } from "react";

interface AskBarProps {
  placeholder: string;
  /** Accessible name; the placeholder disappears once there is text. */
  label: string;
  onSubmit: (text: string) => void;
  autoFocus?: boolean;
  /** The icon at the start; sparkles by default. */
  icon?: ReactNode;
  onFocus?: FocusEventHandler<HTMLInputElement>;
  maxLength?: number;
}

/**
 * The one way to enter text on the glasses. Selecting it opens the glasses'
 * own composer (dictation or handwriting). What comes back is sent at once
 * and the bar empties, like sending a chat message: nothing is edited in
 * place, so there is no need for backspace. A wrong entry is fixed by saying
 * it again.
 *
 * The composer commits through the native change event, not necessarily an
 * Enter press; both are handled, and emptying the field makes a second
 * event for the same entry a no-op.
 */
export const AskBar = forwardRef<HTMLInputElement, AskBarProps>(function AskBar(
  { placeholder, label, onSubmit, autoFocus, icon, onFocus, maxLength = 500 },
  ref,
) {
  const input = useRef<HTMLInputElement>(null);
  useImperativeHandle(ref, () => input.current as HTMLInputElement, []);
  const submit = useRef(onSubmit);
  submit.current = onSubmit;

  useEffect(() => {
    const el = input.current;
    if (!el) return;
    const commit = () => {
      const text = el.value.trim();
      el.value = "";
      if (text) submit.current(text);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Enter") return;
      e.preventDefault();
      commit();
    };
    el.addEventListener("change", commit);
    el.addEventListener("keydown", onKey);
    return () => {
      el.removeEventListener("change", commit);
      el.removeEventListener("keydown", onKey);
    };
  }, []);

  return (
    <label className="ask">
      <span className="ask-icon" aria-hidden="true">
        {icon ?? <SparklesIcon size={26} />}
      </span>
      <input
        ref={input}
        className="ask-input"
        type="text"
        placeholder={placeholder}
        aria-label={label}
        autoComplete="off"
        autoCapitalize="sentences"
        enterKeyHint="send"
        maxLength={maxLength}
        autoFocus={autoFocus}
        onFocus={onFocus}
      />
      <span className="ask-modes" aria-hidden="true">
        <MicIcon size={22} />
        <PenLineIcon size={22} />
      </span>
    </label>
  );
});
