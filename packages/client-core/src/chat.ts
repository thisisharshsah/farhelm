/** Project conversation contract, mirrored from farhelm-proto/src/chat.rs. */
export interface ProjectChat {
  id: string;
  project_id: string;
  repo_id: string;
  title: string;
  created_at: number;
  updated_at: number;
}

export interface ChatMessage {
  id: string;
  conversation_id: string;
  role: "user" | "assistant";
  content: string;
  created_at: number;
  model?: string;
}

export interface ChatTurn {
  request_id: string;
  status: "pending" | "completed" | "failed" | "interrupted";
  error?: string;
  created_at: number;
  updated_at: number;
}

export interface ChatDetail {
  conversation: ProjectChat;
  messages: ChatMessage[];
  latest_turn?: ChatTurn;
}

export interface ChatReply {
  detail: ChatDetail;
  turn: ChatTurn;
}

export interface ProjectChatPage {
  conversations: ProjectChat[];
  next_cursor: string | null;
}

export interface CreateProjectChatRequest {
  repo_id: string;
  title: string;
  budget_usd?: number;
}

export interface SendChatMessageRequest {
  content: string;
  request_id: string;
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function bytes(value: string): number { return new TextEncoder().encode(value).length; }

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && bytes(value) <= 128 && !/\p{Cc}/u.test(value);
}

function timestamp(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function boundedText(value: unknown, maxBytes: number): value is string {
  return typeof value === "string" && value.length <= maxBytes && bytes(value) <= maxBytes;
}

export function parseProjectChat(value: unknown): ProjectChat {
  if (!object(value) || !identifier(value.id) || !identifier(value.project_id) || !identifier(value.repo_id)
    || !boundedText(value.title, 480) || !value.title.trim() || Array.from(value.title).length > 120
    || /\p{Cc}/u.test(value.title) || !timestamp(value.created_at) || !timestamp(value.updated_at)) {
    throw new Error("The runner returned an invalid project conversation.");
  }
  return value as unknown as ProjectChat;
}

export function parseProjectChatPage(value: unknown): ProjectChatPage {
  if (!object(value) || !Array.isArray(value.conversations) || value.conversations.length > 100) {
    throw new Error("The runner returned an invalid conversation list.");
  }
  const conversations = value.conversations.map(parseProjectChat);
  if (!(value.next_cursor === null || identifier(value.next_cursor))
    || (value.next_cursor !== null && value.next_cursor !== conversations.at(-1)?.id)
    || new Set(conversations.map((chat) => chat.id)).size !== conversations.length
    || conversations.some((chat) => chat.project_id !== conversations[0]?.project_id)) {
    throw new Error("The runner returned an invalid conversation list.");
  }
  return { conversations, next_cursor: value.next_cursor };
}

export function parseChatTurn(value: unknown): ChatTurn {
  if (!object(value) || !identifier(value.request_id)
    || !["pending", "completed", "failed", "interrupted"].includes(String(value.status))
    || (value.error !== undefined && !boundedText(value.error, 16_384))
    || !timestamp(value.created_at) || !timestamp(value.updated_at)) {
    throw new Error("The runner returned an invalid conversation turn.");
  }
  return value as unknown as ChatTurn;
}

export function parseChatDetail(value: unknown): ChatDetail {
  if (!object(value) || !Array.isArray(value.messages) || value.messages.length > 100) {
    throw new Error("The runner returned an invalid conversation history.");
  }
  const conversation = parseProjectChat(value.conversation);
  const seen = new Set<string>();
  let totalBytes = 0;
  for (const message of value.messages as unknown[]) {
    if (!object(message) || !identifier(message.id) || seen.has(message.id)
      || message.conversation_id !== conversation.id || !["user", "assistant"].includes(String(message.role))
      || !boundedText(message.content, message.role === "user" ? 16_384 : 65_536)
      || !timestamp(message.created_at)
      || (message.model !== undefined && (!boundedText(message.model, 4_096) || !message.model))) {
      throw new Error("The runner returned an invalid conversation history.");
    }
    seen.add(message.id);
    totalBytes += bytes(message.content);
  }
  if (totalBytes > 262_144) throw new Error("The conversation history is too large to display.");
  return { conversation, messages: value.messages as ChatMessage[],
    ...(value.latest_turn !== undefined ? { latest_turn: parseChatTurn(value.latest_turn) } : {}) };
}

export function parseChatReply(value: unknown): ChatReply {
  if (!object(value)) throw new Error("The runner returned an invalid conversation reply.");
  return { detail: parseChatDetail(value.detail), turn: parseChatTurn(value.turn) };
}
