/**
 * Dictation in the browser (Web Speech API), for the chat composer. Where the
 * browser has none, the keyboard's own microphone still works, so the button
 * is simply not shown.
 */
import { useCallback, useEffect, useRef, useState } from "react";

interface Alternative {
  transcript: string;
}
interface Result {
  readonly isFinal: boolean;
  readonly length: number;
  [index: number]: Alternative;
}
interface ResultEvent {
  readonly resultIndex: number;
  readonly results: { readonly length: number; [index: number]: Result };
}
interface Recognition {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  onresult: ((e: ResultEvent) => void) | null;
  onerror: ((e: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
  abort(): void;
}
type RecognitionCtor = new () => Recognition;

function recognitionCtor(): RecognitionCtor | null {
  const w = globalThis as { SpeechRecognition?: RecognitionCtor; webkitSpeechRecognition?: RecognitionCtor };
  return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null;
}

const MESSAGES: Record<string, string> = {
  "not-allowed": "Allow the microphone for lens.aurovie.com, or use the mic on your keyboard.",
  "service-not-allowed": "Dictation is not available here. Use the mic on your keyboard.",
  "no-speech": "Didn't catch that. Try again.",
  network: "Dictation needs a connection.",
};

/** Calls `onText` with everything heard so far in this session, live. */
export function useDictation(onText: (text: string) => void) {
  const [supported] = useState(() => recognitionCtor() !== null);
  const [listening, setListening] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const rec = useRef<Recognition | null>(null);
  const handler = useRef(onText);
  handler.current = onText;

  useEffect(() => () => rec.current?.abort(), []);

  const start = useCallback(() => {
    const Ctor = recognitionCtor();
    if (!Ctor) return;
    rec.current?.abort();
    const r = new Ctor();
    r.lang = navigator.language || "en-US";
    r.interimResults = true;
    r.continuous = false;
    r.onresult = (e) => {
      let text = "";
      for (let i = 0; i < e.results.length; i++) text += e.results[i]?.[0]?.transcript ?? "";
      handler.current(text.trim());
    };
    r.onerror = (e) => {
      if (e.error !== "aborted") setError(MESSAGES[e.error] ?? "Dictation stopped. Try again.");
    };
    r.onend = () => setListening(false);
    rec.current = r;
    setError(null);
    try {
      r.start();
      setListening(true);
    } catch {
      setError("Dictation could not start. Use the mic on your keyboard.");
    }
  }, []);

  const stop = useCallback(() => rec.current?.stop(), []);

  return { supported, listening, error, start, stop };
}
