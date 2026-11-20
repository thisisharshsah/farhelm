/**
 * The HTTP contract between the Lens API (worker/) and its two clients, the
 * glasses app and the console. One schema per body and response: the server
 * validates what it receives with them, the clients validate what they get
 * back, and the TypeScript types are inferred from the same source.
 */
import { z } from "zod";
import { isAllowedCompanionLink } from "./companion.ts";
import { MAX_NOTE_LENGTH } from "./intents.ts";

// ---------- common ----------

export const ErrorBody = z.object({ error: z.object({ code: z.string(), message: z.string() }) });
export type ErrorBody = z.infer<typeof ErrorBody>;

const id = z.string().min(1).max(200);
const time = z.number().int().nonnegative();

export const Role = z.enum(["owner", "member"]);
export const SessionKind = z.enum(["console", "glasses"]);

export const User = z.object({ id, name: z.string(), role: Role });
export type User = z.infer<typeof User>;

export const Me = z.object({
  user: User,
  session: z.object({ id, kind: SessionKind }),
});
export type Me = z.infer<typeof Me>;

// ---------- passkeys (WebAuthn JSON is checked by the WebAuthn library) ----------

const displayName = z.string().trim().min(1, "Enter your name.").max(60);

export const RegisterOptionsInput = z.object({
  name: displayName,
  inviteCode: z.string().trim().min(4, "Enter your invite code.").max(100),
});

/** The browser's credential response: shape-checked here, verified cryptographically by SimpleWebAuthn. */
export const CredentialResponse = z.looseObject({ id: z.string().min(1).max(1024), type: z.literal("public-key") });

export const CeremonyStart = z.object({ challengeId: id, options: z.record(z.string(), z.unknown()) });
export type CeremonyStart = z.infer<typeof CeremonyStart>;

export const CeremonyFinish = z.object({ challengeId: id, response: CredentialResponse });

export const Passkey = z.object({
  id,
  name: z.string(),
  backedUp: z.boolean(),
  createdAt: time,
  lastUsedAt: time.nullable(),
});
export type Passkey = z.infer<typeof Passkey>;

// ---------- sessions, activity, invites ----------

export const SessionInfo = z.object({
  id,
  kind: SessionKind,
  name: z.string(),
  createdAt: time,
  lastSeenAt: time,
  current: z.boolean(),
});
export type SessionInfo = z.infer<typeof SessionInfo>;

export const ActivityItem = z.object({
  id,
  type: z.string(),
  detail: z.record(z.string(), z.unknown()),
  ip: z.string(),
  createdAt: time,
});
export type ActivityItem = z.infer<typeof ActivityItem>;

export const Invite = z.object({
  id,
  createdAt: time,
  expiresAt: time,
  usedBy: z.string().nullable(),
  usedAt: time.nullable(),
  revokedAt: time.nullable(),
});
export type Invite = z.infer<typeof Invite>;

export const NewInvite = z.object({ invite: Invite, code: z.string() });

// ---------- glasses pairing (RFC 8628 shaped) ----------

export const DeviceStartInput = z.object({ clientName: z.string().trim().min(1).max(60).optional() });

export const DeviceStart = z.object({
  deviceCode: z.string(),
  userCode: z.string(),
  verificationUri: z.string(),
  expiresIn: z.number().int().positive(),
  interval: z.number().int().positive(),
});
export type DeviceStart = z.infer<typeof DeviceStart>;

export const DevicePollInput = z.object({ deviceCode: z.string().min(20).max(200) });

export const DevicePoll = z.discriminatedUnion("status", [
  z.object({ status: z.literal("pending") }),
  z.object({ status: z.literal("slow_down") }),
  z.object({ status: z.literal("denied") }),
  z.object({ status: z.literal("expired") }),
  z.object({ status: z.literal("approved"), user: User }),
]);
export type DevicePoll = z.infer<typeof DevicePoll>;

export const UserCodeInput = z.object({ userCode: z.string().min(8).max(20) });

export const DeviceLookup = z.object({ clientName: z.string(), createdAt: time, expiresAt: time });
export type DeviceLookup = z.infer<typeof DeviceLookup>;

export const DeviceDecisionInput = UserCodeInput.extend({ decision: z.enum(["approve", "deny"]) });

// ---------- data synced to the glasses ----------

export const Note = z.object({ id, text: z.string(), createdAt: time });
export type Note = z.infer<typeof Note>;
export const NoteInput = z.object({ text: z.string().trim().min(1, "Write something first.").max(MAX_NOTE_LENGTH) });

export const WebApp = z.object({ id, name: z.string(), url: z.string(), position: z.number().int() });
export type WebApp = z.infer<typeof WebApp>;
export const WebAppInput = z.object({
  url: z.string().trim().min(1).max(2048),
  name: z.string().trim().min(1).max(40).optional(),
});

export const MAX_RECENT_SEARCHES = 8;

export const Preferences = z.object({
  recentSearches: z.array(z.string().max(100)).max(MAX_RECENT_SEARCHES),
  companionLink: z
    .string()
    .max(2048)
    .refine(isAllowedCompanionLink, "Use https, or http on your own network.")
    .nullable(),
});
export type Preferences = z.infer<typeof Preferences>;
export const DEFAULT_PREFERENCES: Preferences = { recentSearches: [], companionLink: null };
export const PreferencesPatch = Preferences.partial();

// ---------- Lens chat: one conversation per account, on every device ----------

/** A YouTube video as Lens shows it (the runtime form of `Video` in youtube.ts). */
export const VideoItem = z.object({
  id: z.string().regex(/^[A-Za-z0-9_-]{11}$/, "Not a YouTube video."),
  title: z.string().max(300),
  channel: z.string().max(200),
  thumbnail: z.string().max(2048),
  seconds: z.number().int().nonnegative().nullable(),
  // Details for a card and the video's page; older answers have none.
  views: z.number().int().nonnegative().nullable().optional(),
  likes: z.number().int().nonnegative().nullable().optional(),
  published: z.number().int().nonnegative().nullable().optional(),
  description: z.string().max(400).optional(),
});
export type VideoItem = z.infer<typeof VideoItem>;

/** A search answer (GET /api/youtube/search): its first page, and where the next starts. */
export const VideoList = z.object({ query: z.string(), videos: z.array(VideoItem), next: z.string().max(64).nullable().optional() });
export type VideoList = z.infer<typeof VideoList>;

/** One page of a row of videos (GET /api/youtube/row?key=&page=); `next` is null at the end. */
export const RowPage = z.object({ videos: z.array(VideoItem), next: z.string().max(64).nullable() });
export type RowPage = z.infer<typeof RowPage>;
/** A row as YouTube on a TV shows one: what it is (`key`, see `rowKey`) and what it is about. */
export const VideoRow = RowPage.extend({
  key: z.string().max(200),
  kind: z.enum(["search", "related", "channel", "popular"]),
  /** The query, the artist or topic followed, the channel, or the category. */
  subject: z.string().max(300),
});
export type VideoRow = z.infer<typeof VideoRow>;
/** The rows that follow a video (GET /api/youtube/rows?seed=): more like it, from its channel, popular in its category. */
export const VideoRows = z.object({ rows: z.array(VideoRow) });
export type VideoRows = z.infer<typeof VideoRows>;

/** Videos asked for at once by id (GET /api/youtube/details?ids=a,b,c): one YouTube call answers 50. */
export const MAX_DETAILS_IDS = 50;
/** What Lens knows of a video beyond its title and channel. */
export const VideoDetailsItem = VideoItem.pick({ id: true, seconds: true, views: true, likes: true, published: true, description: true });
export type VideoDetailsItem = z.infer<typeof VideoDetailsItem>;
/** The ids YouTube knows, in the order asked; a private or removed video is left out. */
export const VideoDetailsList = z.object({ videos: z.array(VideoDetailsItem) });
export type VideoDetailsList = z.infer<typeof VideoDetailsList>;

/** A video in the account's watch history, with where it was left. */
export const HistoryItem = VideoItem.extend({
  /** Seconds watched, to resume from. */
  position: z.number().int().nonnegative(),
  watchedAt: time,
});
export type HistoryItem = z.infer<typeof HistoryItem>;

/** Recording a video as watched; the thumbnail comes from the id, never from the request. */
export const HistoryInput = z.object({
  video: VideoItem.omit({ thumbnail: true }),
  position: z.number().int().nonnegative().max(7 * 86_400),
});
export type HistoryInput = z.infer<typeof HistoryInput>;

/** Screens of the glasses app a reply can open. */
export const OpenView = z.enum(["home", "youtube", "notes", "timer", "companion", "apps"]);
export type OpenView = z.infer<typeof OpenView>;

/** What Lens did with a message. Clients render each kind; the glasses also act on it. */
export const ChatReply = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("videos"), query: z.string(), videos: z.array(VideoItem), autoplay: z.boolean() }),
  z.object({ kind: z.literal("play"), video: VideoItem }),
  z.object({ kind: z.literal("note"), note: Note }),
  z.object({ kind: z.literal("timer"), durationMs: z.number().int().positive() }),
  z.object({ kind: z.literal("open"), name: z.string(), view: OpenView.optional(), url: z.string().optional() }),
  z.object({ kind: z.literal("help") }),
  z.object({ kind: z.literal("error"), message: z.string() }),
]);
export type ChatReply = z.infer<typeof ChatReply>;

export const ChatMessage = z.object({
  id,
  /** Increases with every message; clients sync by asking for what comes after the last one they have. */
  seq: z.number().int().positive(),
  source: SessionKind,
  text: z.string(),
  reply: ChatReply,
  createdAt: time,
});
export type ChatMessage = z.infer<typeof ChatMessage>;

export const ChatPage = z.object({
  items: z.array(ChatMessage),
  /** Messages at or below this seq were cleared: drop them. */
  clearedThrough: z.number().int().nonnegative(),
});
export type ChatPage = z.infer<typeof ChatPage>;

export const ChatInput = z.object({
  text: z.string().trim().min(1, "Say or type something first.").max(MAX_NOTE_LENGTH),
  /** "videos" from the YouTube screen: everything is a search or a play there. */
  scope: z.enum(["auto", "videos"]).default("auto"),
});

/** Plays a video on the glasses, picked from results on another device. */
export const PlayInput = z.object({ video: VideoItem.omit({ thumbnail: true }) });

export const ChatCleared = z.object({ clearedThrough: z.number().int().nonnegative() });

export const list = <T extends z.ZodType>(item: T) => z.object({ items: z.array(item) });
