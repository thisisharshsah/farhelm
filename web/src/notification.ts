/**
 * What a wake-up should say, and which buttons it should offer.
 *
 * Pure, and separate from `sw.ts`, because this is the part with judgement in
 * it. The worker's job is plumbing — read the pairing, connect, decrypt — and
 * plumbing either works or throws. *This* is where a wrong decision is quiet and
 * expensive: offering a one-tap Approve on `rm -rf /`, or saying "an agent needs
 * you" when the app is already open in front of the user.
 */

import type { ApprovalView, FleetView } from "@relayforge/client-core";

/** `NotificationOptions` plus the fields only a service worker may use. */
export interface WorkerNotificationOptions extends NotificationOptions {
  actions?: { action: string; title: string; icon?: string }[];
  renotify?: boolean;
}

export interface Notification {
  title: string;
  options: WorkerNotificationOptions;
}

/** What the worker managed to find out before composing the notification. */
export type WakeUpContext =
  /** A window is open and in front of the user. */
  | { kind: "focused" }
  /** No pairing, or a stored key that will not load. */
  | { kind: "unpaired" }
  /** The relay or runner could not be reached in time. */
  | { kind: "unreachable" }
  /** A snapshot came back. */
  | { kind: "fleet"; fleet: FleetView };

const ICONS = { icon: "/icon.svg", badge: "/icon.svg" } as const;

/**
 * One tag for every wake-up, so ten of them replace each other rather than
 * stacking into a wall of near-identical rows. The refusal notice gets its own,
 * because it must not be replaced by the next wake-up before it is read.
 */
const TAG = "relayforge";
export const REFUSAL_TAG = "relayforge-refused";

/**
 * Whether an approval may be cleared with one tap from a notification.
 *
 * Destructive commands may not. This is the same reasoning as D3 refusing them
 * from a watch: convenience must not become catastrophe, and a notification
 * action is *less* deliberate than a wrist tap, not more — it can be hit from a
 * lock screen without the app ever coming to the front.
 *
 * The runner enforces its own rule server-side regardless of what any client
 * offers. This is the client declining to offer a button it should not.
 */
export function allowsOneTap(approval: ApprovalView): boolean {
  return approval.risk !== "destructive";
}

export function wakeUpNotification(context: WakeUpContext): Notification {
  switch (context.kind) {
    case "focused":
      // The page has the WebSocket and the real screen. Interrupting someone
      // about something they are looking at is noise — but a push with no
      // notification at all is a "silent push", and browsers revoke the
      // permission for those. So: quiet, not absent.
      return {
        title: "RelayForge",
        options: { body: "Updated.", tag: TAG, silent: true },
      };

    case "unpaired":
    case "unreachable":
      // Nothing was decrypted, so nothing specific can be said truthfully.
      return {
        title: "RelayForge",
        options: { ...ICONS, body: "An agent needs you.", tag: TAG },
      };

    case "fleet":
      return fromFleet(context.fleet);
  }
}

function fromFleet(fleet: FleetView): Notification {
  const approval = fleet.pending_approvals[0];
  if (!approval) {
    // No approval, but possibly a change set. A task is *not* more urgent than
    // an approval — an approval is blocking a live process, a task has already
    // finished and is waiting — so it is checked second, not first.
    const task = fleet.tasks_awaiting_review[0];
    if (task) return fromTask(task, fleet.tasks_awaiting_review.length - 1);

    // Something happened — a budget alert, most likely, or an approval that was
    // decided between the push and this connection.
    return {
      title: "RelayForge",
      options: { ...ICONS, body: "Something needs a look.", tag: TAG },
    };
  }

  const oneTap = allowsOneTap(approval);
  const others = fleet.pending_approvals.length - 1;

  return {
    title: oneTap ? "Approve?" : "Needs your phone",
    options: {
      ...ICONS,
      // This is the payoff for decrypting on the device: the relay never
      // learned any of this, and the notification still names it.
      body: [
        `${approval.repo_name} · ${approval.payload}`,
        others > 0 ? `(+${others} more waiting)` : null,
        oneTap ? null : "Destructive — open the app to review it.",
      ]
        .filter(Boolean)
        .join("\n"),
      tag: TAG,
      renotify: true,
      // A one-tap decision should not vanish on its own; a "go and look" can.
      requireInteraction: oneTap,
      data: { approvalId: approval.id },
      actions: oneTap
        ? [
            { action: "approve", title: "Approve" },
            { action: "deny", title: "Deny" },
          ]
        : [],
    },
  };
}

/**
 * A change set waiting on a review.
 *
 * **Never one-tap.** The whole value of a diff is that somebody read it, and a
 * notification action is the least deliberate surface there is — it can be hit
 * from a lock screen without the app ever coming to the front. "Approve" on a
 * diff nobody has opened is worse than no notification at all, because it looks
 * like review and is not. The runner refuses it server-side too; this is the
 * client declining to offer the button.
 */
function fromTask(
  task: FleetView["tasks_awaiting_review"][number],
  others: number,
): Notification {
  return {
    title: "A change set is waiting",
    options: {
      ...ICONS,
      body: [
        `${task.repo_name} · ${task.change_summary}`,
        task.prompt,
        others > 0 ? `(+${others} more waiting)` : null,
      ]
        .filter(Boolean)
        .join("\n"),
      tag: TAG,
      renotify: true,
      // It is not urgent in the way a blocked agent is — the work is done and
      // will keep. Let it dismiss itself rather than nagging.
      requireInteraction: false,
      data: { taskId: task.id },
      actions: [],
    },
  };
}

/** What to show when the runner refused the decision after the tap. */
export function refusalNotification(message: string): Notification {
  return {
    title: "Not done",
    options: {
      ...ICONS,
      body: message,
      tag: REFUSAL_TAG,
      // The notification that prompted the tap is already gone, so this is the
      // only surface left. It must not disappear before it is read.
      requireInteraction: true,
    },
  };
}

/** What to show when the tap could not reach the runner at all. */
export function unreachableNotification(): Notification {
  return {
    title: "Could not reach the runner",
    options: {
      ...ICONS,
      body: "Nothing was decided. Open the app to try again.",
      tag: REFUSAL_TAG,
      requireInteraction: true,
    },
  };
}

/** Quiet confirmation that a tap landed. */
export function decidedNotification(action: "approve" | "deny"): Notification {
  return {
    title: action === "approve" ? "Approved" : "Denied",
    options: { body: "Sent to the runner.", tag: TAG, silent: true },
  };
}
