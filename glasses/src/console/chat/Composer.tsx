import { useLayoutEffect, useRef, useState, type KeyboardEvent } from "react";
import { EXAMPLES, MAX_NOTE_LENGTH } from "../../shared/intents.ts";
import { useDictation } from "../dictation.ts";
import { Icon } from "../ui.tsx";
import { useLensChat } from "./ChatContext.tsx";

const MAX_HEIGHT = 5 * 24 + 22;

/**
 * Type or dictate, then send: the answer appears here and on the glasses.
 * Unlike the glasses, the phone can edit freely before sending.
 */
export function Composer({ placeholder = "Message your glasses" }: { placeholder?: string }) {
  const chat = useLensChat();
  const [text, setText] = useState("");
  const area = useRef<HTMLTextAreaElement>(null);
  // What was typed before dictation started; what is heard is added after it.
  const before = useRef("");
  const dictation = useDictation((heard) => setText(before.current ? `${before.current} ${heard}` : heard));

  // Grow with the text, up to five lines.
  useLayoutEffect(() => {
    const el = area.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, MAX_HEIGHT)}px`;
  }, [text]);

  const send = () => {
    const value = text.trim();
    if (!value) return;
    if (dictation.listening) dictation.stop();
    setText("");
    void chat.send(value);
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      send();
    }
  };

  const toggleMic = () => {
    if (dictation.listening) {
      dictation.stop();
      area.current?.focus();
      return;
    }
    before.current = text.trim();
    dictation.start();
  };

  return (
    <div className="composer-wrap">
      <form
        className={`composer glass${dictation.listening ? " listening" : ""}`}
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        <textarea
          ref={area}
          rows={1}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder={dictation.listening ? "Listening…" : placeholder}
          aria-label={placeholder}
          enterKeyHint="send"
          maxLength={MAX_NOTE_LENGTH}
        />
        <div className="composer-actions">
          {dictation.supported ? (
            <button
              type="button"
              className={`mic${dictation.listening ? " on" : ""}`}
              aria-label={dictation.listening ? "Stop dictation" : "Dictate"}
              aria-pressed={dictation.listening}
              onClick={toggleMic}
            >
              <Icon name={dictation.listening ? "stop" : "mic"} size={19} fill={dictation.listening ? "currentColor" : undefined} />
            </button>
          ) : null}
          <button type="submit" className="send" aria-label="Send" disabled={!text.trim()}>
            <Icon name="send" size={20} />
          </button>
        </div>
      </form>
      {dictation.error ? (
        <p className="composer-note" role="status">
          {dictation.error}
        </p>
      ) : null}
      <div className="suggestions">
        {EXAMPLES.map((e) => (
          <button
            key={e.text}
            type="button"
            className="suggestion"
            title={e.hint}
            onClick={() => {
              setText(e.text);
              area.current?.focus();
            }}
          >
            {e.text}
          </button>
        ))}
      </div>
    </div>
  );
}
