import { PauseIcon, PlayIcon, RotateCcwIcon } from "lucide-react";
import { useNow } from "../../lib/useNow.ts";
import { spokenDuration } from "../../../shared/time.ts";
import { PRESET_MINUTES, formatClock, isDone, isRunning, remaining, reset, toggle, type TimerState } from "./timer.ts";

interface TimerProps {
  timer: TimerState;
  setTimer: (next: TimerState) => void;
}

const RADIUS = 104;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

export function Timer({ timer, setTimer }: TimerProps) {
  const now = useNow(250);
  const done = isDone(timer, now);
  const running = isRunning(timer, now);
  const left = remaining(timer, now);
  const progress = timer.durationMs > 0 ? left / timer.durationMs : 0;

  return (
    <section className="app-page fixed timer" aria-label="Timer">
      <div className={`ring${done ? " done" : ""}`} role="timer" aria-label={`${formatClock(left)} left`}>
        <svg viewBox="0 0 240 240" aria-hidden="true">
          <circle className="ring-track" cx="120" cy="120" r={RADIUS} />
          <circle
            className="ring-fill"
            cx="120"
            cy="120"
            r={RADIUS}
            strokeDasharray={CIRCUMFERENCE}
            strokeDashoffset={CIRCUMFERENCE * (1 - progress)}
          />
        </svg>
        <span className="ring-time">{formatClock(left)}</span>
        <span className="ring-sub">{done ? "Time's up" : running ? `of ${spokenDuration(timer.durationMs)}` : "Ready"}</span>
      </div>
      <div className="row presets">
        {PRESET_MINUTES.map((m) => (
          <button key={m} className="btn" aria-pressed={timer.durationMs === m * 60_000} onClick={() => setTimer(reset(timer, m * 60_000))}>
            {m} min
          </button>
        ))}
      </div>
      <div className="row">
        <button className="btn primary" data-primary onClick={() => setTimer(toggle(timer, Date.now()))}>
          {running ? <PauseIcon size={26} /> : done ? <RotateCcwIcon size={26} /> : <PlayIcon size={26} />}
          {running ? "Pause" : done ? "Again" : "Start"}
        </button>
        <button className="btn" onClick={() => setTimer(reset(timer))}>
          <RotateCcwIcon size={26} />
          Reset
        </button>
      </div>
    </section>
  );
}
