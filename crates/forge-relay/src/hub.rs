//! Channel fan-out.
//!
//! The relay's entire job: everything one member of a channel sends goes to
//! every *other* member of that channel, and to nobody else. It never inspects
//! an envelope's ciphertext because it cannot — see `forge_crypto`.
//!
//! Deliberately stateless beyond live connections. There is no message store, so
//! there is nothing to subpoena, nothing to leak in a backup, and nothing to
//! migrate. A device that was offline re-fetches from the runner on reconnect,
//! which it has to do anyway.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use forge_crypto::Envelope;
use tokio::sync::broadcast;

/// Envelopes a slow connection may fall behind before it is dropped and told to
/// reconnect. Bounded so one wedged phone cannot pin the relay's memory.
const CHANNEL_BUFFER: usize = 128;

/// An envelope plus who sent it, so the hub can avoid echoing to the sender.
#[derive(Debug, Clone)]
pub struct Delivery {
    /// Connection that published it. Not the cryptographic sender — this is a
    /// per-connection id, used only to skip the echo.
    pub from_connection: u64,
    pub envelope: Arc<Envelope>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ChannelStats {
    pub members: usize,
    pub delivered: u64,
    pub bytes: u64,
}

struct Channel {
    sender: broadcast::Sender<Delivery>,
    members: usize,
    delivered: u64,
    bytes: u64,
}

/// Every live channel.
#[derive(Default)]
pub struct Hub {
    channels: Mutex<HashMap<String, Channel>>,
    next_connection: Mutex<u64>,
}

impl Hub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Join a channel, creating it if this is the first member.
    pub fn join(&self, channel: &str) -> Membership {
        let mut channels = self.channels.lock().expect("hub poisoned");
        let entry = channels
            .entry(channel.to_owned())
            .or_insert_with(|| Channel {
                sender: broadcast::channel(CHANNEL_BUFFER).0,
                members: 0,
                delivered: 0,
                bytes: 0,
            });
        entry.members += 1;
        let receiver = entry.sender.subscribe();

        let mut next = self.next_connection.lock().expect("hub poisoned");
        *next += 1;

        Membership {
            connection_id: *next,
            receiver,
        }
    }

    /// Publish to a channel. Returns how many connections it reached.
    ///
    /// The sender does not receive its own envelope — a runner that echoed its
    /// own `session_upsert` back to itself would loop.
    pub fn publish(&self, from_connection: u64, envelope: Envelope) -> usize {
        let mut channels = self.channels.lock().expect("hub poisoned");
        let Some(entry) = channels.get_mut(&envelope.channel) else {
            return 0;
        };

        let bytes = envelope.size_hint() as u64;
        let delivery = Delivery {
            from_connection,
            envelope: Arc::new(envelope),
        };

        // `send` counts subscribers including the sender's own receiver, which
        // filters itself out on the way past. Reporting the raw count would
        // overstate delivery by exactly one.
        let reached = entry.sender.send(delivery).unwrap_or(0).saturating_sub(1);
        entry.delivered += reached as u64;
        entry.bytes += bytes;
        reached
    }

    /// Leave a channel, dropping it once empty.
    pub fn leave(&self, channel: &str) {
        let mut channels = self.channels.lock().expect("hub poisoned");
        let Some(entry) = channels.get_mut(channel) else {
            return;
        };
        entry.members = entry.members.saturating_sub(1);
        if entry.members == 0 {
            // An empty channel keeps nothing: no buffered messages, no stats, no
            // record that it ever existed.
            channels.remove(channel);
        }
    }

    pub fn stats(&self, channel: &str) -> Option<ChannelStats> {
        let channels = self.channels.lock().expect("hub poisoned");
        channels.get(channel).map(|entry| ChannelStats {
            members: entry.members,
            delivered: entry.delivered,
            bytes: entry.bytes,
        })
    }

    pub fn channel_count(&self) -> usize {
        self.channels.lock().expect("hub poisoned").len()
    }
}

/// One connection's handle on a channel.
pub struct Membership {
    pub connection_id: u64,
    receiver: broadcast::Receiver<Delivery>,
}

impl Membership {
    /// The next envelope meant for this connection.
    ///
    /// Returns `None` when the channel closed. A lagged receiver skips ahead
    /// rather than disconnecting: the client re-fetches state from the runner on
    /// reconnect anyway, so dropping it would be a worse outcome than a gap.
    pub async fn next(&mut self) -> Option<Arc<Envelope>> {
        loop {
            match self.receiver.recv().await {
                Ok(delivery) if delivery.from_connection == self.connection_id => continue,
                Ok(delivery) => return Some(delivery.envelope),
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn envelope(channel: &str, ciphertext: &str) -> Envelope {
        Envelope {
            channel: channel.to_owned(),
            sender_id: "runner".to_owned(),
            nonce: "bm9uY2U".to_owned(),
            ciphertext: ciphertext.to_owned(),
        }
    }

    #[tokio::test]
    async fn an_envelope_reaches_the_other_member() {
        let hub = Hub::new();
        let runner = hub.join("chan");
        let mut phone = hub.join("chan");

        assert_eq!(
            hub.publish(runner.connection_id, envelope("chan", "abc")),
            1
        );
        assert_eq!(phone.next().await.unwrap().ciphertext, "abc");
    }

    #[tokio::test]
    async fn a_sender_does_not_receive_its_own_envelope() {
        let hub = Hub::new();
        let mut runner = hub.join("chan");
        let mut phone = hub.join("chan");

        hub.publish(runner.connection_id, envelope("chan", "from-runner"));
        assert_eq!(phone.next().await.unwrap().ciphertext, "from-runner");

        // The runner must not see it come back. Its next envelope is the phone's.
        hub.publish(phone.connection_id, envelope("chan", "from-phone"));
        assert_eq!(runner.next().await.unwrap().ciphertext, "from-phone");
    }

    #[tokio::test]
    async fn every_other_member_gets_a_copy() {
        let hub = Hub::new();
        let runner = hub.join("chan");
        let mut phone = hub.join("chan");
        let mut laptop = hub.join("chan");

        assert_eq!(hub.publish(runner.connection_id, envelope("chan", "x")), 2);
        assert_eq!(phone.next().await.unwrap().ciphertext, "x");
        assert_eq!(laptop.next().await.unwrap().ciphertext, "x");
    }

    #[tokio::test]
    async fn channels_are_isolated() {
        let hub = Hub::new();
        let mine = hub.join("mine");
        let mut theirs = hub.join("theirs");

        hub.publish(mine.connection_id, envelope("mine", "private"));

        // Nothing crossed over. A different channel's traffic is not merely
        // unreadable — it never arrives.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), theirs.next())
                .await
                .is_err(),
            "an envelope leaked into another channel"
        );
    }

    #[tokio::test]
    async fn publishing_to_an_empty_channel_reaches_nobody() {
        let hub = Hub::new();
        assert_eq!(hub.publish(1, envelope("nobody-here", "x")), 0);
    }

    #[test]
    fn a_channel_disappears_when_its_last_member_leaves() {
        let hub = Hub::new();
        hub.join("chan");
        hub.join("chan");
        assert_eq!(hub.stats("chan").unwrap().members, 2);

        hub.leave("chan");
        assert_eq!(hub.stats("chan").unwrap().members, 1);

        hub.leave("chan");
        assert_eq!(hub.stats("chan"), None, "the channel outlived its members");
        assert_eq!(hub.channel_count(), 0);
    }

    #[test]
    fn leaving_a_channel_that_is_not_there_is_harmless() {
        Hub::new().leave("never-existed");
    }

    #[tokio::test]
    async fn stats_count_deliveries_not_publishes() {
        let hub = Hub::new();
        let runner = hub.join("chan");
        let _phone = hub.join("chan");
        let _laptop = hub.join("chan");

        hub.publish(runner.connection_id, envelope("chan", "0123456789"));

        let stats = hub.stats("chan").unwrap();
        assert_eq!(stats.delivered, 2, "one publish, two recipients");
        assert_eq!(stats.bytes, 10);
    }

    #[tokio::test]
    async fn connection_ids_are_unique_across_channels() {
        let hub = Hub::new();
        let a = hub.join("one");
        let b = hub.join("two");
        let c = hub.join("one");
        assert_ne!(a.connection_id, b.connection_id);
        assert_ne!(a.connection_id, c.connection_id);
    }
}
