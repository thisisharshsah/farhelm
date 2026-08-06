//! Unified diffs, computed here rather than shelled out to `git diff`.
//!
//! The review screen is the product: a task's whole output is a patch a human
//! reads on a phone and says yes or no to. That makes the diff a *structured
//! type*, not a string a subprocess printed — the clients need per-file counts
//! and per-line tags to render it, and a phone should not be parsing `@@`
//! headers. The types themselves live in [`forge_proto::diff`], because three
//! client implementations mirror them; what is left here is the computation.
//!
//! It also means a proposed change can be shown before anything touches the
//! working tree. `git diff` can only describe edits that have already happened;
//! the whole point of the staging overlay is that they have not.
//!
//! ## The algorithm, and where it gives up
//!
//! Common prefix and suffix are trimmed first — the usual case is a few changed
//! lines in an otherwise identical file, and trimming turns that into a tiny
//! problem. What is left goes through an LCS table, which is `O(n·m)` in the
//! *remaining* lines.
//!
//! Above [`MAX_LCS_CELLS`] the table is abandoned and the differing middle is
//! emitted as one delete-then-insert block. That is a worse-looking diff, never
//! a wrong one: the reconstructed "after" text is identical either way. The
//! alternative — quadratic memory on a machine-generated 200k-line file — is a
//! runner that gets OOM-killed while its user waits for a review card.

/// The shapes a diff is *described* in live in `forge-proto`, because three
/// client implementations mirror them. This module computes them.
pub use forge_proto::diff::{ChangeKind, ChangeSet, DiffLine, FileDiff, Hunk, Tag};

/// Lines of unchanged context on each side of a change.
pub const DEFAULT_CONTEXT: usize = 3;

/// Ceiling on the LCS table. ~4M cells is a 2000×2000 differing region, which
/// no hand-written source file reaches after prefix/suffix trimming.
const MAX_LCS_CELLS: usize = 4_000_000;

/// Split into lines without inventing a trailing empty one.
///
/// `"a\n"` is one line, not two. Getting this wrong shows up as a phantom `+`
/// on every file that ends the way every file ends.
fn split_lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    text.strip_suffix('\n')
        .unwrap_or(text)
        .split('\n')
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Op {
    Equal,
    Remove,
    Add,
}

/// Longest-common-subsequence alignment of two line slices.
///
/// Returns operations in order, referring to `a` for `Equal`/`Remove` and to `b`
/// for `Equal`/`Add`.
fn align(a: &[&str], b: &[&str]) -> Vec<Op> {
    if a.is_empty() {
        return vec![Op::Add; b.len()];
    }
    if b.is_empty() {
        return vec![Op::Remove; a.len()];
    }

    // Over the ceiling: one delete block then one insert block. Correct output,
    // coarser presentation. See the module docs.
    if a.len().saturating_mul(b.len()) > MAX_LCS_CELLS {
        let mut ops = vec![Op::Remove; a.len()];
        ops.extend(std::iter::repeat_n(Op::Add, b.len()));
        return ops;
    }

    // table[i][j] = LCS length of a[i..] and b[j..]. Filled backwards so the
    // walk that follows moves forwards, which keeps deletions ahead of
    // insertions at the same position — the order a reviewer expects.
    let mut table = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            table[i][j] = if a[i] == b[j] {
                table[i + 1][j + 1] + 1
            } else {
                table[i + 1][j].max(table[i][j + 1])
            };
        }
    }

    let mut ops = Vec::with_capacity(a.len() + b.len());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i] == b[j] {
            ops.push(Op::Equal);
            i += 1;
            j += 1;
        } else if table[i + 1][j] >= table[i][j + 1] {
            ops.push(Op::Remove);
            i += 1;
        } else {
            ops.push(Op::Add);
            j += 1;
        }
    }
    ops.extend(std::iter::repeat_n(Op::Remove, a.len() - i));
    ops.extend(std::iter::repeat_n(Op::Add, b.len() - j));
    ops
}

/// Tag every line of both sides, trimming the identical head and tail first.
fn tagged_lines(before: &str, after: &str) -> Vec<DiffLine> {
    let old = split_lines(before);
    let new = split_lines(after);

    let prefix = old
        .iter()
        .zip(new.iter())
        .take_while(|(left, right)| left == right)
        .count();

    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(left, right)| left == right)
        .count();

    let mut lines = Vec::new();
    let line = |tag: Tag, text: &str| DiffLine {
        tag,
        text: text.to_owned(),
    };

    for text in &old[..prefix] {
        lines.push(line(Tag::Context, text));
    }

    let middle_old = &old[prefix..old.len() - suffix];
    let middle_new = &new[prefix..new.len() - suffix];
    let (mut i, mut j) = (0, 0);
    for op in align(middle_old, middle_new) {
        match op {
            Op::Equal => {
                lines.push(line(Tag::Context, middle_old[i]));
                i += 1;
                j += 1;
            }
            Op::Remove => {
                lines.push(line(Tag::Remove, middle_old[i]));
                i += 1;
            }
            Op::Add => {
                lines.push(line(Tag::Add, middle_new[j]));
                j += 1;
            }
        }
    }

    for text in &old[old.len() - suffix..] {
        lines.push(line(Tag::Context, text));
    }
    lines
}

/// Group tagged lines into hunks, keeping `context` unchanged lines around each
/// change and merging runs that would otherwise overlap.
fn hunks(lines: &[DiffLine], context: usize) -> Vec<Hunk> {
    let changed: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| line.tag != Tag::Context)
        .map(|(index, _)| index)
        .collect();

    if changed.is_empty() {
        return Vec::new();
    }

    let mut ranges: Vec<(usize, usize)> = Vec::new();
    for &index in &changed {
        let low = index.saturating_sub(context);
        let high = (index + context).min(lines.len() - 1);
        match ranges.last_mut() {
            // `+ 1` merges two hunks separated by a single context line, which
            // is what every diff tool does — a lone ` ` line between two `@@`
            // headers is noise, not structure.
            Some(last) if low <= last.1 + 1 => last.1 = last.1.max(high),
            _ => ranges.push((low, high)),
        }
    }

    // Line numbers before each index, so a hunk header does not need a rescan.
    let mut old_before = Vec::with_capacity(lines.len() + 1);
    let mut new_before = Vec::with_capacity(lines.len() + 1);
    let (mut old_count, mut new_count) = (0usize, 0usize);
    for line in lines {
        old_before.push(old_count);
        new_before.push(new_count);
        match line.tag {
            Tag::Context => {
                old_count += 1;
                new_count += 1;
            }
            Tag::Remove => old_count += 1,
            Tag::Add => new_count += 1,
        }
    }
    old_before.push(old_count);
    new_before.push(new_count);

    ranges
        .into_iter()
        .map(|(low, high)| {
            let slice = &lines[low..=high];
            let old_len = slice.iter().filter(|line| line.tag != Tag::Add).count();
            let new_len = slice.iter().filter(|line| line.tag != Tag::Remove).count();

            Hunk {
                // An empty range points at the line *before* it, which is the
                // unified-diff convention for "inserted at the very top".
                old_start: if old_len == 0 {
                    old_before[low]
                } else {
                    old_before[low] + 1
                },
                old_len,
                new_start: if new_len == 0 {
                    new_before[low]
                } else {
                    new_before[low] + 1
                },
                new_len,
                lines: slice.to_vec(),
            }
        })
        .collect()
}

/// Diff one file. `None` when nothing changed — an unchanged file must not
/// appear on a review card at all.
pub fn file_diff(path: &str, before: Option<&str>, after: Option<&str>) -> Option<FileDiff> {
    let kind = match (before, after) {
        (None, Some(_)) => ChangeKind::Added,
        (Some(_), None) => ChangeKind::Deleted,
        (Some(old), Some(new)) if old == new => return None,
        (Some(_), Some(_)) => ChangeKind::Modified,
        (None, None) => return None,
    };

    let lines = tagged_lines(before.unwrap_or_default(), after.unwrap_or_default());
    let hunks = hunks(&lines, DEFAULT_CONTEXT);
    if hunks.is_empty() {
        return None;
    }

    Some(FileDiff {
        path: path.to_owned(),
        kind,
        added: lines.iter().filter(|line| line.tag == Tag::Add).count(),
        removed: lines.iter().filter(|line| line.tag == Tag::Remove).count(),
        hunks,
        binary: false,
    })
}

/// A file that is not text. Recorded so the review card can say so.
pub fn binary_diff(path: &str, kind: ChangeKind) -> FileDiff {
    FileDiff {
        path: path.to_owned(),
        kind,
        added: 0,
        removed: 0,
        hunks: Vec::new(),
        binary: true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn diff(before: &str, after: &str) -> FileDiff {
        file_diff("src/x.rs", Some(before), Some(after)).expect("a change")
    }

    #[test]
    fn an_identical_file_produces_no_diff_at_all() {
        assert!(file_diff("a.txt", Some("same\n"), Some("same\n")).is_none());
    }

    #[test]
    fn a_one_line_change_counts_one_added_and_one_removed() {
        let diff = diff("one\ntwo\nthree\n", "one\nTWO\nthree\n");
        assert_eq!((diff.added, diff.removed), (1, 1));
        assert_eq!(diff.kind, ChangeKind::Modified);
    }

    #[test]
    fn a_trailing_newline_is_not_a_phantom_line() {
        // "a\n" is one line. Splitting naively yields ["a", ""] and every file
        // in the repo shows a spurious change at the bottom.
        let lines = tagged_lines("a\n", "a\n");
        assert_eq!(lines.len(), 1);
        assert!(file_diff("a.txt", Some("a\n"), Some("a\n")).is_none());
    }

    #[test]
    fn a_new_file_is_all_additions_against_dev_null() {
        let diff = file_diff("new.rs", None, Some("fn main() {}\n")).unwrap();
        assert_eq!(diff.kind, ChangeKind::Added);
        assert_eq!((diff.added, diff.removed), (1, 0));
        assert!(diff.render().contains("--- /dev/null"));
        assert!(diff.render().contains("+++ b/new.rs"));
    }

    #[test]
    fn a_deleted_file_is_all_removals_towards_dev_null() {
        let diff = file_diff("gone.rs", Some("fn main() {}\n"), None).unwrap();
        assert_eq!(diff.kind, ChangeKind::Deleted);
        assert_eq!((diff.added, diff.removed), (0, 1));
        assert!(diff.render().contains("+++ /dev/null"));
    }

    #[test]
    fn context_is_bounded_so_a_big_file_yields_a_small_hunk() {
        let before: String = (0..500).map(|i| format!("line {i}\n")).collect();
        let after = before.replace("line 250\n", "line 250 CHANGED\n");

        let diff = diff(&before, &after);
        assert_eq!(diff.hunks.len(), 1);
        // 3 context + 1 removed + 1 added + 3 context.
        assert_eq!(diff.hunks[0].lines.len(), 8);
        assert_eq!(diff.hunks[0].old_start, 248);
    }

    #[test]
    fn distant_changes_get_their_own_hunks() {
        let before: String = (0..100).map(|i| format!("line {i}\n")).collect();
        let after = before
            .replace("line 10\n", "line 10 X\n")
            .replace("line 80\n", "line 80 Y\n");

        assert_eq!(diff(&before, &after).hunks.len(), 2);
    }

    #[test]
    fn nearby_changes_merge_into_one_hunk() {
        let before: String = (0..100).map(|i| format!("line {i}\n")).collect();
        let after = before
            .replace("line 40\n", "line 40 X\n")
            .replace("line 42\n", "line 42 Y\n");

        assert_eq!(diff(&before, &after).hunks.len(), 1);
    }

    #[test]
    fn hunk_headers_report_the_lengths_they_actually_contain() {
        let diff = diff("a\nb\nc\n", "a\nB\nc\n");
        let hunk = &diff.hunks[0];
        assert_eq!(hunk.old_len, 3);
        assert_eq!(hunk.new_len, 3);
        assert_eq!(hunk.header(), "@@ -1,3 +1,3 @@");
    }

    #[test]
    fn an_insertion_at_the_top_starts_the_old_range_at_zero() {
        let diff = file_diff("a.txt", Some(""), Some("first\n")).unwrap();
        assert_eq!(diff.hunks[0].old_start, 0);
        assert_eq!(diff.hunks[0].old_len, 0);
        assert_eq!(diff.hunks[0].new_start, 1);
    }

    /// The property that matters: whatever the alignment chose, applying the
    /// hunks to the old text has to reproduce the new text exactly.
    #[test]
    fn the_tagged_lines_reconstruct_both_sides() {
        let before = "alpha\nbeta\ngamma\ndelta\n";
        let after = "alpha\ngamma\ndelta\nepsilon\n";
        let lines = tagged_lines(before, after);

        let rebuild = |keep: fn(Tag) -> bool| {
            lines
                .iter()
                .filter(|line| keep(line.tag))
                .map(|line| line.text.clone())
                .collect::<Vec<_>>()
                .join("\n")
                + "\n"
        };

        assert_eq!(rebuild(|tag| tag != Tag::Add), before);
        assert_eq!(rebuild(|tag| tag != Tag::Remove), after);
    }

    #[test]
    fn the_lcs_ceiling_degrades_to_a_block_replacement_not_a_wrong_answer() {
        // Two files with no shared lines, far past the cell ceiling.
        let before: Vec<&str> = Vec::new();
        assert_eq!(align(&before, &["x"]), vec![Op::Add]);

        let big_a: Vec<String> = (0..2_500).map(|i| format!("a{i}")).collect();
        let big_b: Vec<String> = (0..2_500).map(|i| format!("b{i}")).collect();
        let refs_a: Vec<&str> = big_a.iter().map(String::as_str).collect();
        let refs_b: Vec<&str> = big_b.iter().map(String::as_str).collect();

        let ops = align(&refs_a, &refs_b);
        assert_eq!(ops.len(), 5_000);
        assert!(ops[..2_500].iter().all(|op| *op == Op::Remove));
        assert!(ops[2_500..].iter().all(|op| *op == Op::Add));
    }

    #[test]
    fn a_change_set_summarises_in_one_line() {
        let set = ChangeSet {
            files: vec![
                file_diff("a.rs", Some("x\n"), Some("y\n")).unwrap(),
                file_diff("b.rs", None, Some("new\nfile\n")).unwrap(),
            ],
        };
        assert_eq!(set.added(), 3);
        assert_eq!(set.removed(), 1);
        assert_eq!(set.summary(), "2 files, +3 −1");
    }

    #[test]
    fn one_file_is_not_pluralised() {
        let set = ChangeSet {
            files: vec![file_diff("a.rs", Some("x\n"), Some("y\n")).unwrap()],
        };
        assert_eq!(set.summary(), "1 file, +1 −1");
    }

    #[test]
    fn a_binary_file_is_reported_rather_than_rendered() {
        let diff = binary_diff("logo.png", ChangeKind::Modified);
        assert!(diff.binary);
        assert!(diff.hunks.is_empty());
        assert_eq!(diff.render().trim(), "Binary file logo.png differs");
    }

    #[test]
    fn a_file_with_no_trailing_newline_still_diffs() {
        let diff = diff("a\nb", "a\nc");
        assert_eq!((diff.added, diff.removed), (1, 1));
    }
}
