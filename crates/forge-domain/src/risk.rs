//! The destructive-command classifier (D3).
//!
//! Its only job is to decide how much friction an approval deserves: a
//! [`Risk::Destructive`] verdict makes the approval phone-only, so a half-awake
//! wrist tap can never force-push over someone's branch.
//!
//! **This is not a sandbox.** It is a speed bump on the *approval UX*, and it
//! is trivially evadable by an adversary (`r''m -rf`, base64, a shell variable).
//! That is acceptable because the threat model is a well-meaning agent doing
//! something drastic, not a hostile one hiding from us — an agent that wanted to
//! evade this could simply write a script and run that instead. Real containment
//! is the runner's own sandboxing, which this does not replace.
//!
//! It errs toward over-classifying. A false `Destructive` costs one extra tap on
//! a phone; a false `Low` costs a force-pushed branch.

use forge_proto::types::Risk;

/// Local additions to the built-in rules.
///
/// The built-in list is broad — `rm -rf`, force pushes, `DROP TABLE`, `mkfs`,
/// `sudo`, `curl | sh`, and the common cloud verbs including `terraform destroy`
/// and `kubectl delete`. It still cannot know about *your* stack: the deploy
/// tool your team uses, the one make target that drops the staging database.
/// This is where those go.
///
/// # It is additive, and the escape hatch is deliberately narrow
///
/// The built-ins always apply unless a pattern is *individually* named in
/// [`Policy::allow`]. There is no blanket off switch, because a single
/// `enabled = false` is the setting somebody reaches for while debugging at
/// 2am and never puts back — and D3 is the only thing standing between a
/// half-awake wrist tap and a force-push.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Policy {
    /// Extra patterns, matched case-insensitively against the squeezed command —
    /// the same treatment the built-ins get.
    pub destructive: Vec<String>,
    /// Extra patterns matched with case preserved, for flags where case *is* the
    /// meaning: `git branch -D` force-deletes, `-d` refuses to.
    pub destructive_exact: Vec<String>,
    /// Built-in patterns to stop treating as destructive.
    ///
    /// Matched against the built-in pattern text, so `allow = ["sudo"]` stops
    /// `sudo` alone earning the friction. Anything not on this list still
    /// applies.
    pub allow: Vec<String>,
}

/// What a policy file looks like when nobody has written one.
pub const EXAMPLE_POLICY: &str = r#"# What counts as destructive on this machine.
#
# A destructive command can only be approved from a phone — never from a watch,
# and never from a notification action. That is the whole effect of this file.
#
# The built-in rules already cover a lot: rm -rf, git push --force,
# git reset --hard, git clean -fd, git filter-branch, DROP TABLE / TRUNCATE /
# DELETE FROM, FLUSHALL, mkfs, dd if=, shred, chmod -R 777, chown -R, sudo,
# curl | sh, npm publish, terraform destroy, kubectl delete, docker system
# prune, and aws s3 rb. Check before adding — you may not need to.
#
# What they cannot know is your stack: the deploy script your team wrote, the
# make target that drops the staging database.

# Matched case-insensitively, anywhere in the command.
destructive = [
  # "flyctl apps destroy",
  # "pulumi destroy",
  # "make reset-staging",
  # "./deploy.sh --prod",
]

# Matched with case preserved. Use this when the case is the meaning.
destructive_exact = [
  # "helm uninstall",
]

# Built-in patterns to stop treating as destructive.
#
# Narrow on purpose: there is no way to switch the classifier off, only to
# retire individual rules. If `sudo` is routine on this box, name it here —
# do not reach for a blanket disable that never gets put back.
allow = [
  # "sudo",
]
"#;

#[derive(Debug)]
pub enum PolicyError {
    Parse(String),
}

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // The parse error carries the line and column, which is the only
            // thing that makes a hand-edited TOML file fixable.
            PolicyError::Parse(detail) => write!(f, "policy file: {detail}"),
        }
    }
}

impl std::error::Error for PolicyError {}

impl Policy {
    /// Parse a policy from the text of a policy file.
    ///
    /// Takes the text rather than a path: reading the file is I/O and belongs to
    /// whoever has a filesystem — see `forge_runner`'s `load_policy`. This half
    /// is the part with a decision in it, and it is testable without one.
    ///
    /// A malformed policy is an error, never a silent fallback to the built-ins:
    /// somebody wrote `terraform destroy` in there expecting it to be gated, and
    /// quietly ignoring the file would be the worst outcome.
    pub fn parse(text: &str) -> Result<Self, PolicyError> {
        toml::from_str(text).map_err(|err| PolicyError::Parse(err.to_string()))
    }

    fn allows(&self, pattern: &str) -> bool {
        self.allow
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(pattern))
    }

    /// How many rules this policy adds or retires — for the startup banner.
    pub fn rule_count(&self) -> (usize, usize) {
        (
            self.destructive.len() + self.destructive_exact.len(),
            self.allow.len(),
        )
    }
}

/// Substrings that mark an action as destructive. Matched against a normalised
/// form of the command, so spacing and quoting noise does not hide them.
const DESTRUCTIVE_PATTERNS: &[&str] = &[
    // Recursive deletion, in the orderings people actually type.
    "rm -rf",
    "rm -fr",
    "rm -r -f",
    "rm -f -r",
    "rm --recursive --force",
    // History rewriting and branch clobbering.
    "git push --force",
    "git push -f ",
    "git push --delete",
    "git reset --hard",
    "git clean -fd",
    "git clean -xfd",
    "git filter-branch",
    "git filter-repo",
    "git update-ref -d",
    // Databases.
    "drop table",
    "drop database",
    "drop schema",
    "truncate table",
    "delete from",
    "flushall",
    "flushdb",
    // Filesystem and device level.
    "mkfs",
    "dd if=",
    "> /dev/sd",
    "shred ",
    "chmod -r 777",
    "chown -r",
    // Infrastructure teardown.
    "terraform destroy",
    "kubectl delete",
    "docker system prune",
    "docker volume rm",
    "aws s3 rb",
    "aws s3 rm",
    "gcloud projects delete",
    // Publishing — outward-facing and effectively irreversible.
    "npm publish",
    "cargo publish",
    "pypi upload",
    "twine upload",
    "gh release create",
    // Piping the internet into a shell.
    "curl | sh",
    "curl | bash",
    "wget | sh",
    "wget | bash",
    // Package-manager global removals.
    "apt-get remove",
    "apt remove",
    "brew uninstall",
    "pip uninstall",
];

/// Patterns where **flag case carries the meaning**, so they cannot go through
/// the lowercasing pass.
///
/// `git branch -d` refuses to delete an unmerged branch; `-D` deletes it anyway.
/// Folding case would either miss the dangerous form or flag the safe one.
const CASE_SENSITIVE_PATTERNS: &[&str] = &["git branch -D", "git push -D"];

/// Tools that mutate the working tree but are ordinary agent work.
const MUTATING_TOOLS: &[&str] = &[
    "bash",
    "write",
    "edit",
    "multiedit",
    "notebookedit",
    "str_replace_based_edit_tool",
];

/// Tools that only observe. Cheap to approve, and the bulk of the volume.
const READ_ONLY_TOOLS: &[&str] = &[
    "read",
    "glob",
    "grep",
    "ls",
    "websearch",
    "webfetch",
    "todowrite",
    "task",
];

/// Collapse the shell noise that would otherwise hide a pattern: repeated
/// whitespace and quotes used as separators. Case is preserved.
fn squeeze(command: &str) -> String {
    let mut out = String::with_capacity(command.len());
    let mut last_was_space = false;

    for ch in command.chars() {
        // Quotes and backslashes are dropped rather than turned into spaces, so
        // `rm -r"f"` and `rm\ -rf` still read as `rm -rf`.
        if matches!(ch, '\'' | '"' | '\\') {
            continue;
        }
        if ch.is_whitespace() {
            if !last_was_space {
                out.push(' ');
            }
            last_was_space = true;
        } else {
            out.push(ch);
            last_was_space = false;
        }
    }
    out
}

/// True when a command matches any destructive pattern.
pub fn is_destructive_command(command: &str) -> bool {
    is_destructive_command_with(&Policy::default(), command)
}

/// [`is_destructive_command`] with local rules layered on.
pub fn is_destructive_command_with(policy: &Policy, command: &str) -> bool {
    let squeezed = squeeze(command);
    let normalised = squeezed.to_lowercase();

    // Local additions first: they are the ones somebody wrote down deliberately
    // for this machine, and checking them first makes them cheap to reason about.
    if policy
        .destructive
        .iter()
        .any(|pattern| normalised.contains(&pattern.to_lowercase()))
    {
        return true;
    }
    if policy
        .destructive_exact
        .iter()
        .any(|pattern| squeezed.contains(pattern.as_str()))
    {
        return true;
    }

    if DESTRUCTIVE_PATTERNS
        .iter()
        .any(|pattern| !policy.allows(pattern) && normalised.contains(pattern))
    {
        return true;
    }

    if CASE_SENSITIVE_PATTERNS
        .iter()
        .any(|pattern| !policy.allows(pattern) && squeezed.contains(pattern))
    {
        return true;
    }

    // A pipe into a shell is destructive regardless of what fetched it, so it is
    // checked structurally rather than as a fixed substring.
    let piped_to_shell = normalised.contains("| sh")
        || normalised.contains("| bash")
        || normalised.contains("|sh ")
        || normalised.contains("|bash");
    let fetches = normalised.contains("curl ")
        || normalised.contains("wget ")
        || normalised.contains("fetch ");
    if piped_to_shell && fetches && !policy.allows("curl | sh") {
        return true;
    }

    // `sudo` is not itself destructive, but nothing an agent does unattended
    // should need it, so it earns the friction.
    if !policy.allows("sudo") && (normalised.starts_with("sudo ") || normalised.contains(" sudo "))
    {
        return true;
    }

    // The classic fork bomb, after quote stripping.
    normalised.replace(' ', "").contains(":(){:|:&};:")
}

/// Classify a tool call.
///
/// `tool` is the agent's tool name (`Bash`, `Write`, …); `payload` is the text
/// the human will see on the approval card — for Bash that is the command, for
/// an edit the file path and a summary.
pub fn classify(tool: &str, payload: &str) -> Risk {
    classify_with(&Policy::default(), tool, payload)
}

/// [`classify`] with local rules layered on.
pub fn classify_with(policy: &Policy, tool: &str, payload: &str) -> Risk {
    let tool_lower = tool.to_lowercase();

    // An MCP tool is opaque to us: we cannot know what `mcp__deploy__ship` does,
    // so it gets the middle tier rather than a guess in either direction.
    let is_mcp = tool_lower.starts_with("mcp__");

    if is_destructive_command_with(policy, payload) {
        return Risk::Destructive;
    }

    if READ_ONLY_TOOLS.contains(&tool_lower.as_str()) {
        return Risk::Low;
    }

    if is_mcp || MUTATING_TOOLS.contains(&tool_lower.as_str()) {
        return Risk::Medium;
    }

    // An unrecognised tool is treated as mutating. New tools appear faster than
    // this list is updated, and the safe default is the one that asks.
    Risk::Medium
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recursive_deletion_is_destructive_in_any_flag_order() {
        for command in [
            "rm -rf /tmp/build",
            "rm -fr node_modules",
            "rm -r -f dist",
            "rm -f -r dist",
            "rm --recursive --force dist",
        ] {
            assert_eq!(
                classify("Bash", command),
                Risk::Destructive,
                "{command:?} should be destructive"
            );
        }
    }

    #[test]
    fn quoting_and_spacing_do_not_hide_a_pattern() {
        for command in [
            r#"rm -r"f" /important"#,
            "rm    -rf   /important",
            "RM -RF /important",
            r"rm\ -rf /important",
        ] {
            assert!(
                is_destructive_command(command),
                "{command:?} slipped past the classifier"
            );
        }
    }

    #[test]
    fn history_rewriting_is_destructive() {
        for command in [
            "git push --force origin main",
            "git push -f origin main",
            "git reset --hard HEAD~3",
            "git clean -fdx",
            "git branch -D feature/x",
        ] {
            assert_eq!(classify("Bash", command), Risk::Destructive, "{command:?}");
        }
    }

    #[test]
    fn an_ordinary_push_is_not_destructive() {
        assert_eq!(classify("Bash", "git push origin main"), Risk::Medium);
    }

    #[test]
    fn git_branch_delete_distinguishes_the_forcing_flag() {
        // -d refuses to drop an unmerged branch; -D does it anyway. Case is the
        // only difference, which is why one pass cannot be case-folded.
        assert_eq!(
            classify("Bash", "git branch -D feature/x"),
            Risk::Destructive
        );
        assert_eq!(classify("Bash", "git branch -d feature/x"), Risk::Medium);
    }

    #[test]
    fn database_destruction_is_caught_case_insensitively() {
        for command in [
            "psql -c 'DROP TABLE users'",
            "mysql -e \"drop database prod\"",
            "psql -c 'TRUNCATE TABLE events'",
            "redis-cli FLUSHALL",
        ] {
            assert_eq!(classify("Bash", command), Risk::Destructive, "{command:?}");
        }
    }

    #[test]
    fn piping_the_internet_into_a_shell_is_destructive() {
        for command in [
            "curl https://example.com/install.sh | sh",
            "wget -qO- https://example.com/i.sh | bash",
            "curl -fsSL https://get.example.com |bash",
        ] {
            assert!(is_destructive_command(command), "{command:?}");
        }
    }

    #[test]
    fn a_harmless_pipe_is_not_destructive() {
        assert!(!is_destructive_command("cat log.txt | grep ERROR"));
        assert!(!is_destructive_command("ls -la | head -20"));
    }

    #[test]
    fn sudo_always_earns_the_friction() {
        assert_eq!(
            classify("Bash", "sudo systemctl restart nginx"),
            Risk::Destructive
        );
        assert_eq!(
            classify("Bash", "echo hi && sudo reboot"),
            Risk::Destructive
        );
    }

    #[test]
    fn publishing_is_destructive_because_it_cannot_be_taken_back() {
        for command in [
            "npm publish",
            "cargo publish -p forge-core",
            "twine upload dist/*",
        ] {
            assert_eq!(classify("Bash", command), Risk::Destructive, "{command:?}");
        }
    }

    #[test]
    fn a_fork_bomb_is_caught() {
        assert!(is_destructive_command(":(){ :|:& };:"));
    }

    #[test]
    fn read_only_tools_are_low_risk() {
        for tool in ["Read", "Glob", "Grep", "WebSearch"] {
            assert_eq!(classify(tool, "src/main.rs"), Risk::Low, "{tool}");
        }
    }

    #[test]
    fn ordinary_edits_and_commands_are_medium() {
        assert_eq!(
            classify("Edit", "src/retry.rs — 3 lines changed"),
            Risk::Medium
        );
        assert_eq!(classify("Write", "docs/README.md"), Risk::Medium);
        assert_eq!(classify("Bash", "pytest tests/billing -x"), Risk::Medium);
    }

    #[test]
    fn an_unknown_tool_defaults_to_asking_not_to_allowing() {
        assert_eq!(
            classify("SomeToolShippedNextMonth", "whatever"),
            Risk::Medium
        );
    }

    #[test]
    fn an_mcp_tool_is_medium_because_we_cannot_see_inside_it() {
        assert_eq!(classify("mcp__deploy__ship", "{}"), Risk::Medium);
    }

    #[test]
    fn a_destructive_payload_beats_a_read_only_tool_name() {
        // A tool claiming to be read-only while carrying `rm -rf` is exactly the
        // case where the payload must win.
        assert_eq!(classify("Read", "rm -rf /"), Risk::Destructive);
    }

    #[test]
    fn a_destructive_verdict_forces_the_approval_off_the_watch() {
        use crate::budget::ApprovalRules as _;
        use forge_proto::types::Approval;

        let approval = Approval {
            id: "a".into(),
            session_id: "s".into(),
            tool: "Bash".into(),
            payload: "git push --force origin main".into(),
            risk: classify("Bash", "git push --force origin main"),
            decision: None,
            decided_via: None,
            requested_at: 0,
            decided_at: None,
        };
        assert!(!approval.allows_watch_decision());
    }
}

#[cfg(test)]
mod policy_tests {
    use super::*;

    fn policy(toml_text: &str) -> Policy {
        toml::from_str(toml_text).expect("valid policy")
    }

    #[test]
    fn the_example_policy_parses() {
        // It ships as the file people are told to copy. If it did not parse,
        // the first thing anyone did with this feature would fail.
        let parsed = policy(EXAMPLE_POLICY);
        assert_eq!(parsed, Policy::default(), "everything is commented out");
    }

    #[test]
    fn a_local_rule_makes_a_command_destructive() {
        // The whole point: the built-in list cannot know about your stack.
        // `flyctl` is deliberately chosen — the built-ins cover `terraform
        // destroy` and `kubectl delete` already, so using those would test
        // nothing.
        let policy = policy(r#"destructive = ["flyctl apps destroy"]"#);
        assert!(!is_destructive_command("flyctl apps destroy my-app"));
        assert!(is_destructive_command_with(
            &policy,
            "flyctl apps destroy my-app"
        ));
    }

    #[test]
    fn a_local_rule_is_matched_case_insensitively_like_the_built_ins() {
        let policy = policy(r#"destructive = ["make reset-staging"]"#);
        assert!(is_destructive_command_with(&policy, "MAKE RESET-STAGING"));
    }

    #[test]
    fn a_local_rule_survives_spacing_noise() {
        // Same normalisation the built-ins get, or a rule would be evadable by
        // pressing space twice.
        let policy = policy(r#"destructive = ["make reset-staging"]"#);
        assert!(is_destructive_command_with(
            &policy,
            "make    reset-staging"
        ));
    }

    #[test]
    fn an_exact_rule_respects_case() {
        // For flags where case is the meaning.
        let policy = policy(r#"destructive_exact = ["helm uninstall -F"]"#);
        assert!(is_destructive_command_with(
            &policy,
            "helm uninstall -F app"
        ));
        assert!(!is_destructive_command_with(
            &policy,
            "helm uninstall -f app"
        ));
    }

    #[test]
    fn the_built_ins_still_apply_alongside_local_rules() {
        // Additive, not a replacement. Someone adding one terraform rule must
        // not silently lose `rm -rf`.
        let policy = policy(r#"destructive = ["flyctl apps destroy"]"#);
        assert!(is_destructive_command_with(&policy, "rm -rf /"));
        assert!(is_destructive_command_with(
            &policy,
            "git push --force origin main"
        ));
    }

    #[test]
    fn a_named_built_in_can_be_retired() {
        let policy = policy(r#"allow = ["sudo"]"#);
        assert!(is_destructive_command("sudo apt install ripgrep"));
        assert!(!is_destructive_command_with(
            &policy,
            "sudo apt install ripgrep"
        ));
    }

    #[test]
    fn retiring_one_rule_does_not_retire_the_others() {
        // The narrow escape hatch. `allow` is per-pattern precisely so it cannot
        // become the blanket off switch someone flips at 2am and never restores.
        let policy = policy(r#"allow = ["sudo"]"#);
        assert!(is_destructive_command_with(&policy, "rm -rf ./build"));
        assert!(is_destructive_command_with(&policy, "DROP TABLE users"));
        assert!(is_destructive_command_with(
            &policy,
            "curl https://x.sh | bash"
        ));
    }

    #[test]
    fn there_is_no_way_to_switch_the_classifier_off() {
        // An empty-but-present policy must be as careful as no policy at all.
        assert!(is_destructive_command_with(&Policy::default(), "rm -rf /"));
        // And a policy that tries to allow everything only retires what it names.
        let policy = policy(r#"allow = ["everything"]"#);
        assert!(is_destructive_command_with(&policy, "rm -rf /"));
    }

    #[test]
    fn a_local_rule_reaches_the_classifier_not_just_the_matcher() {
        // `classify` is what the approval card actually calls.
        let policy = policy(r#"destructive = ["flyctl apps destroy"]"#);
        assert_eq!(
            classify_with(&policy, "Bash", "flyctl apps destroy my-app"),
            Risk::Destructive
        );
        assert_eq!(classify("Bash", "flyctl apps destroy my-app"), Risk::Medium);
    }

    #[test]
    fn a_typo_in_the_policy_is_an_error_not_a_silent_default() {
        // Somebody wrote `terraform destroy` in there expecting it to be gated.
        // Ignoring the file would be the worst possible outcome.
        assert!(toml::from_str::<Policy>("destructiv = [\"x\"]").is_err());
        assert!(toml::from_str::<Policy>("destructive = \"not a list\"").is_err());
    }

    #[test]
    fn a_typo_reports_where_it_is() {
        // The parse error carries line and column, which is the only thing that
        // makes a hand-edited TOML file fixable.
        let err = Policy::parse("destructive = [\"unterminated").unwrap_err();
        assert!(
            err.to_string().contains("policy file"),
            "the message should say what kind of file it is: {err}"
        );
    }

    #[test]
    fn the_rule_count_is_reportable() {
        // Printed at startup, so "is my rule loaded" has an answer that is not
        // "read the source".
        let policy = policy(
            r#"
            destructive = ["a", "b"]
            destructive_exact = ["c"]
            allow = ["sudo"]
            "#,
        );
        assert_eq!(policy.rule_count(), (3, 1));
    }
}
