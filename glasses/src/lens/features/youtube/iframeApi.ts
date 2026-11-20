/**
 * Loads YouTube's documented IFrame Player API once, on first use.
 * https://developers.google.com/youtube/iframe_api_reference
 *
 * Only the members this app calls are typed.
 */
export interface YTPlayer {
  playVideo(): void;
  pauseVideo(): void;
  seekTo(seconds: number, allowSeekAhead: boolean): void;
  getCurrentTime(): number;
  getDuration(): number;
  getPlayerState(): number;
  setPlaybackRate(rate: number): void;
  getPlaybackRate(): number;
  getIframe(): HTMLIFrameElement;
  destroy(): void;
}

export interface YTPlayerOptions {
  videoId: string;
  host?: string;
  width?: string | number;
  height?: string | number;
  playerVars?: Record<string, string | number>;
  events?: {
    onReady?: (e: { target: YTPlayer }) => void;
    onStateChange?: (e: { data: number; target: YTPlayer }) => void;
    onError?: (e: { data: number; target: YTPlayer }) => void;
  };
}

export interface YTNamespace {
  Player: new (element: HTMLElement, options: YTPlayerOptions) => YTPlayer;
  PlayerState: { ENDED: 0; PLAYING: 1; PAUSED: 2; BUFFERING: 3; CUED: 5 };
}

declare global {
  interface Window {
    YT?: YTNamespace;
    onYouTubeIframeAPIReady?: () => void;
  }
}

const SCRIPT = "https://www.youtube.com/iframe_api";
const LOAD_TIMEOUT_MS = 15_000;

let loading: Promise<YTNamespace> | null = null;

export function loadIframeApi(): Promise<YTNamespace> {
  if (window.YT?.Player) return Promise.resolve(window.YT);
  if (loading) return loading;
  loading = new Promise<YTNamespace>((resolve, reject) => {
    const fail = (message: string) => {
      loading = null; // let a later attempt try again
      reject(new Error(message));
    };
    const timer = setTimeout(() => fail("The player took too long to load."), LOAD_TIMEOUT_MS);
    const previous = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => {
      previous?.();
      clearTimeout(timer);
      if (window.YT?.Player) resolve(window.YT);
      else fail("The player did not load.");
    };
    const script = document.createElement("script");
    script.src = SCRIPT;
    script.async = true;
    script.onerror = () => {
      clearTimeout(timer);
      script.remove();
      fail("Could not reach YouTube.");
    };
    document.head.append(script);
  });
  return loading;
}

/** The player's error codes, in words. */
export function playerErrorMessage(code: number): string {
  switch (code) {
    case 2:
    case 100:
      return "This video is unavailable.";
    case 5:
      return "This video cannot play on the glasses.";
    case 101:
    case 150:
      return "The owner does not allow this video to play here.";
    case 153:
      return "YouTube refused the player. The page must send its address.";
    default:
      return `The video could not play (error ${code}).`;
  }
}
