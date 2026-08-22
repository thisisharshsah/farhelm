//! Identifiers.
//!
//! Everything is keyed by a TEXT uuid so two runners' databases can be merged
//! for the team tier without renumbering. v7 is time-ordered, which keeps the
//! b-tree append-friendly and makes ids sort by creation.

use uuid::Uuid;

/// A fresh time-ordered id.
pub fn new_id() -> String {
    Uuid::now_v7().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique() {
        let a = new_id();
        let b = new_id();
        assert_ne!(a, b);
    }

    #[test]
    fn ids_sort_by_creation_order() {
        let mut ids: Vec<String> = (0..64).map(|_| new_id()).collect();
        let generated = ids.clone();
        ids.sort();
        assert_eq!(ids, generated);
    }
}
