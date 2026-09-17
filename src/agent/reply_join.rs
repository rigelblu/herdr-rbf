#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum JoinDecision {
    SavedReply,
    Unavailable,
    NotJoined,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Joined {
    pub(crate) text: String,
    pub(crate) breaks_removed: usize,
    pub(crate) decided_by: JoinDecision,
}

#[derive(Clone, Copy)]
struct MatchState {
    start: usize,
    end: usize,
    breaks_removed: usize,
}

pub(crate) fn join_codex(rows: &str, saved_reply: Option<&str>) -> Joined {
    let Some(saved_reply) = saved_reply else {
        return unavailable(rows);
    };
    let row_text = rows.lines().collect::<Vec<_>>();
    let Some(first) = row_text.first() else {
        return not_joined(rows);
    };

    let mut states = Vec::new();
    for variant in first_row_variants(first) {
        states.extend(
            saved_reply
                .match_indices(variant)
                .map(|(start, text)| MatchState {
                    start,
                    end: start + text.len(),
                    breaks_removed: 0,
                }),
        );
    }

    for row in &row_text[1..] {
        let mut next = Vec::new();
        for state in states {
            for boundary in boundaries(saved_reply, state.end) {
                for variant in row_variants(row, !boundary.source_newline) {
                    if saved_reply[boundary.end..].starts_with(variant) {
                        next.push(MatchState {
                            start: state.start,
                            end: boundary.end + variant.len(),
                            breaks_removed: state.breaks_removed
                                + usize::from(!boundary.source_newline),
                        });
                    }
                }
            }
        }
        states = next;
        if states.is_empty() {
            return unavailable(rows);
        }
    }

    let mut matches = states
        .into_iter()
        .map(|state| {
            (
                saved_reply[state.start..state.end].to_owned(),
                state.breaks_removed,
            )
        })
        .collect::<Vec<_>>();
    matches.sort_unstable();
    matches.dedup();
    let (text, breaks_removed) = match matches.as_slice() {
        [(text, breaks_removed)] => (text.clone(), *breaks_removed),
        [] => return unavailable(rows),
        matches => {
            let normalized = matches[0].0.trim_start_matches([' ', '\t']).to_owned();
            let breaks_removed = matches[0].1;
            if !matches.iter().all(|(text, breaks)| {
                *breaks == breaks_removed && text.trim_start_matches([' ', '\t']) == normalized
            }) {
                return unavailable(rows);
            }
            (normalized, breaks_removed)
        }
    };

    Joined {
        text,
        breaks_removed,
        decided_by: JoinDecision::SavedReply,
    }
}

pub(crate) fn join_codex_replies(rows: &str, saved_replies: &[String]) -> Joined {
    let mut matches = saved_replies
        .iter()
        .map(|reply| join_codex(rows, Some(reply)))
        .filter(|joined| joined.decided_by == JoinDecision::SavedReply)
        .collect::<Vec<_>>();
    matches.sort_unstable_by(|left, right| {
        (&left.text, left.breaks_removed).cmp(&(&right.text, right.breaks_removed))
    });
    matches.dedup_by(|left, right| {
        left.text == right.text && left.breaks_removed == right.breaks_removed
    });
    match matches.as_slice() {
        [joined] => joined.clone(),
        // Nothing matched: these rows are not a reply, so herdr never wanted a reply's
        // text for them. That is an ordinary copy. Unavailable is reserved for the cases
        // the user can act on -- no hook, no session id, an unreadable session file, a
        // spent budget -- all decided by the caller, and for the ambiguous match below.
        [] => not_joined(rows),
        // Two or more replies match the same rows differently, so joining would guess.
        _ => unavailable(rows),
    }
}

#[derive(Clone, Copy)]
struct Boundary {
    end: usize,
    source_newline: bool,
}

fn boundaries(source: &str, start: usize) -> Vec<Boundary> {
    let mut result = vec![Boundary {
        end: start,
        source_newline: false,
    }];
    let remaining = &source[start..];
    let horizontal = remaining
        .char_indices()
        .take_while(|(_, ch)| matches!(ch, ' ' | '\t'))
        .map(|(offset, ch)| offset + ch.len_utf8())
        .last();
    if let Some(length) = horizontal {
        result.push(Boundary {
            end: start + length,
            source_newline: false,
        });
    }
    if remaining.starts_with('\n') {
        result.push(Boundary {
            end: start + 1,
            source_newline: true,
        });
    }
    result
}

fn row_variants(row: &str, strip_leading_whitespace: bool) -> Vec<&str> {
    if let Some(text) = row.strip_prefix("• ") {
        return vec![text];
    }
    if strip_leading_whitespace {
        let text = row.trim_start_matches([' ', '\t']);
        if text != row {
            return vec![text, row];
        }
    }
    if let Some(text) = row.strip_prefix("  ") {
        return vec![text, row];
    }
    vec![row]
}

fn first_row_variants(row: &str) -> Vec<&str> {
    if let Some(text) = row.strip_prefix("• ") {
        return vec![text];
    }
    if let Some(text) = row.strip_prefix("  ") {
        return vec![text, &row[1..], row];
    }
    if let Some(text) = row.strip_prefix(' ') {
        return vec![text, row];
    }
    vec![row]
}

pub(crate) fn unavailable(rows: &str) -> Joined {
    Joined {
        text: rows.to_owned(),
        breaks_removed: 0,
        decided_by: JoinDecision::Unavailable,
    }
}

pub(crate) fn not_joined(rows: &str) -> Joined {
    Joined {
        text: rows.to_owned(),
        breaks_removed: 0,
        decided_by: JoinDecision::NotJoined,
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[derive(serde::Deserialize)]
    struct ReplyFixture {
        reply: String,
        expected: String,
    }

    fn fixture(json: &str) -> ReplyFixture {
        serde_json::from_str(json).expect("reply fixture")
    }

    fn temp_path(label: &str) -> std::path::PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "herdr-agent-copy-{label}-{}-{}.jsonl",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn rollout_record(text: &str) -> String {
        format!(
            "{}\n",
            serde_json::json!({
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": text}]
                }
            })
        )
    }

    fn session_file(home: &std::path::Path, session_id: &str) -> std::path::PathBuf {
        home.join("sessions/2026/09/17")
            .join(format!("rollout-test-{session_id}.jsonl"))
    }

    fn restore_codex_home(previous: Option<std::ffi::OsString>) {
        if let Some(value) = previous {
            std::env::set_var("CODEX_HOME", value);
        } else {
            std::env::remove_var("CODEX_HOME");
        }
    }

    #[test]
    fn codex_one_line() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.rows"
        ));
        let fixture = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.reply.json"
        )));

        let joined = super::join_codex(rows.trim_end(), Some(&fixture.reply));

        assert_eq!(joined.text, fixture.expected);
        assert_eq!(joined.breaks_removed, 3);
        assert_eq!(joined.decided_by, super::JoinDecision::SavedReply);
    }

    #[test]
    fn codex_three_lines() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.rows"
        ));
        let fixture = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.reply.json"
        )));

        let joined = super::join_codex(rows.trim_end(), Some(&fixture.reply));

        assert_eq!(joined.text, fixture.expected);
        assert_eq!(joined.breaks_removed, 1);
        assert_eq!(joined.decided_by, super::JoinDecision::SavedReply);
    }

    #[test]
    fn codex_no_reply() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.rows"
        ))
        .trim_end();

        let no_session = super::join_codex(rows, None);
        assert_eq!(no_session.text, rows);
        assert_eq!(no_session.breaks_removed, 0);
        assert_eq!(no_session.decided_by, super::JoinDecision::Unavailable);

        let missing = temp_path("missing");
        assert!(crate::agent::codex_reply::read_recent_messages(&missing).is_none());

        let truncated = temp_path("truncated");
        std::fs::write(&truncated, b"{\"type\":\"response_item\"")
            .expect("write truncated rollout");
        assert!(crate::agent::codex_reply::read_recent_messages(&truncated).is_none());
        std::fs::remove_file(&truncated).expect("remove truncated rollout");

        let absent = temp_path("absent");
        std::fs::write(
            &absent,
            concat!(
                "{\"type\":\"response_item\",\"payload\":{",
                "\"type\":\"message\",\"role\":\"assistant\",",
                "\"content\":[{\"type\":\"output_text\",\"text\":\"still streaming\"}]}}\n"
            ),
        )
        .expect("write rollout without selected reply");
        let messages =
            crate::agent::codex_reply::read_recent_messages(&absent).expect("valid rollout tail");
        let no_match = super::join_codex(rows, messages.last().map(String::as_str));
        assert_eq!(no_match.text, rows);
        assert_eq!(no_match.breaks_removed, 0);
        assert_eq!(no_match.decided_by, super::JoinDecision::Unavailable);
        std::fs::remove_file(&absent).expect("remove rollout without selected reply");

        let ambiguous =
            super::join_codex("• alpha\n  beta", Some("alpha beta\nother\nalpha\nbeta"));
        assert_eq!(ambiguous.text, "• alpha\n  beta");
        assert_eq!(ambiguous.breaks_removed, 0);
        assert_eq!(ambiguous.decided_by, super::JoinDecision::Unavailable);
    }

    #[test]
    fn older_reply_prevents_false_join() {
        let path = temp_path("older-reply");
        let mut rollout = rollout_record("alpha\nbeta");
        for index in 0..16 {
            rollout.push_str(&rollout_record(&format!("unrelated reply {index}")));
        }
        rollout.push_str(&rollout_record("alpha beta"));
        std::fs::write(&path, rollout).expect("write rollout with older reply");

        let messages = crate::agent::codex_reply::read_recent_messages(&path)
            .expect("read rollout with older reply");
        let joined = super::join_codex_replies("• alpha\n  beta", &messages);

        assert_eq!(joined.text, "• alpha\n  beta");
        assert_eq!(joined.breaks_removed, 0);
        assert_eq!(joined.decided_by, super::JoinDecision::Unavailable);

        std::fs::remove_file(path).expect("remove rollout with older reply");
    }

    #[test]
    fn non_reply_rows_are_an_ordinary_copy() {
        let path = temp_path("non-reply-rows-decision");
        let mut rollout = rollout_record("a reply about something else entirely");
        rollout.push_str(&rollout_record("and a second unrelated reply"));
        std::fs::write(&path, rollout).expect("write rollout with unrelated replies");

        let messages = crate::agent::codex_reply::read_recent_messages(&path)
            .expect("read rollout with unrelated replies");
        let rows = "\u{2502} command output\n\u{2514} next tool row";
        let joined = super::join_codex_replies(rows, &messages);

        assert_eq!(joined.text, rows);
        assert_eq!(joined.breaks_removed, 0);
        // No candidate matched, so herdr never wanted a reply's text here. That is an
        // ordinary copy, not a failed lookup. Unavailable is for the cases the user can
        // act on -- no hook, no session id, an unreadable file, a spent budget -- and for
        // a genuinely ambiguous match.
        assert_eq!(joined.decided_by, super::JoinDecision::NotJoined);

        std::fs::remove_file(path).expect("remove rollout with unrelated replies");
    }

    #[test]
    fn break_counts() {
        let one_line_rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.rows"
        ));
        let one_line = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.reply.json"
        )));
        let three_line_rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.rows"
        ));
        let three_line = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.reply.json"
        )));

        assert_eq!(
            super::join_codex(one_line_rows.trim_end(), Some(&one_line.reply)).breaks_removed,
            3
        );
        assert_eq!(
            super::join_codex(three_line_rows.trim_end(), Some(&three_line.reply)).breaks_removed,
            1
        );
        assert_eq!(
            super::join_codex(
                one_line_rows.lines().next().expect("first row"),
                Some(&one_line.reply)
            )
            .breaks_removed,
            0
        );
    }

    #[test]
    fn partial_selection() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.rows"
        ));
        let one_line = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.reply.json"
        )));
        let drawn = rows.lines().collect::<Vec<_>>();

        let partial_start = drawn[0].find("Testing").expect("partial start");
        let partial_end =
            drawn[3].find(" successfully").expect("partial end") + " successfully".len();
        let partial_rows = [
            &drawn[0][partial_start..],
            drawn[1],
            drawn[2],
            &drawn[3][..partial_end],
        ]
        .join("\n");
        let expected_start = one_line.expected.find("Testing").expect("source start");
        let expected_end =
            one_line.expected.find(" successfully").expect("source end") + " successfully".len();
        let partial = super::join_codex(&partial_rows, Some(&one_line.reply));
        assert_eq!(
            partial.text,
            one_line.expected[expected_start..expected_end]
        );
        assert_eq!(partial.breaks_removed, 3);

        let gutter_rows = drawn[..2].join("\n");
        let gutter = super::join_codex(&gutter_rows, Some(&one_line.reply));
        let gutter_end =
            one_line.expected.find("git status").expect("gutter end") + "git status".len();
        assert_eq!(gutter.text, one_line.expected[..gutter_end]);
        assert_eq!(gutter.breaks_removed, 1);

        let inside_gutter_rows = format!(
            " {}\n{}",
            drawn[0].strip_prefix("• ").expect("reply gutter"),
            drawn[1]
        );
        let inside_gutter = super::join_codex(&inside_gutter_rows, Some(&one_line.reply));
        assert_eq!(inside_gutter.text, one_line.expected[..gutter_end]);
        assert_eq!(inside_gutter.breaks_removed, 1);

        let three_line_rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.rows"
        ));
        let three_line = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-three-lines.reply.json"
        )));
        let continuation_rows = three_line_rows
            .lines()
            .skip(1)
            .collect::<Vec<_>>()
            .join("\n");
        let continuation_start = three_line
            .expected
            .find("$(date)")
            .expect("continuation source start");

        let continuation = super::join_codex(&continuation_rows, Some(&three_line.reply));

        assert_eq!(continuation.text, three_line.expected[continuation_start..]);
        assert_eq!(continuation.breaks_removed, 0);
        assert_eq!(continuation.decided_by, super::JoinDecision::SavedReply);
    }

    #[test]
    fn codex_prose() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-prose.rows"
        ));
        let fixture = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-prose.reply.json"
        )));

        let joined = super::join_codex(rows.trim_end(), Some(&fixture.reply));
        assert_eq!(joined.text, fixture.expected);
        assert_eq!(joined.breaks_removed, 2);

        let hyphen = super::join_codex("• keep rb-\n  drive exact", Some("keep rb-drive exact"));
        assert_eq!(hyphen.text, "keep rb-drive exact");
        assert_eq!(hyphen.breaks_removed, 1);
    }

    #[test]
    fn codex_wrapped_lists() {
        let rows = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-lists.rows"
        ));
        let fixture = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-lists.reply.json"
        )));

        let joined = super::join_codex(rows.trim_end(), Some(&fixture.reply));

        assert_eq!(joined.text, fixture.expected);
        assert_eq!(joined.breaks_removed, 2);
        assert_eq!(joined.decided_by, super::JoinDecision::SavedReply);
    }

    #[test]
    fn non_reply_rows() {
        let fixture = fixture(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/agent-copy/codex-108-one-line.reply.json"
        )));
        let spanning = format!(
            "│ command output\n{}\n└ next tool row",
            include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/fixtures/agent-copy/codex-108-one-line.rows"
            ))
            .trim_end()
        );

        let joined = super::join_codex(&spanning, Some(&fixture.reply));

        assert_eq!(joined.text, spanning);
        assert_eq!(joined.breaks_removed, 0);
        assert_eq!(joined.decided_by, super::JoinDecision::Unavailable);
    }

    #[test]
    #[ignore = "performance profile creates a 58 MiB rollout"]
    fn budget() {
        let _guard = crate::config::test_config_env_lock().lock().unwrap();
        let home = temp_path("budget-home");
        let session_id = "019d-budget";
        let path = session_file(&home, session_id);
        std::fs::create_dir_all(path.parent().expect("session parent"))
            .expect("create session directory");
        let mut writer =
            std::io::BufWriter::new(std::fs::File::create(&path).expect("create large rollout"));
        let padding = rollout_record(&"x".repeat(64 * 1024));
        let target = 58 * 1024 * 1024u64;
        let mut written = 0u64;
        while written < target {
            writer.write_all(padding.as_bytes()).expect("pad rollout");
            written += padding.len() as u64;
        }
        writer
            .write_all(rollout_record("budget reply").as_bytes())
            .expect("write final reply");
        writer.flush().expect("flush rollout");
        assert!(std::fs::metadata(&path).unwrap().len() >= target);

        let previous = std::env::var_os("CODEX_HOME");
        std::env::set_var("CODEX_HOME", &home);
        assert!(
            crate::agent::codex_reply::recent_messages(session_id, std::time::Duration::ZERO)
                .is_none()
        );
        crate::agent::codex_reply::recent_messages(
            session_id,
            crate::agent::codex_reply::SESSION_LOOKUP_BUDGET,
        )
        .expect("warm lookup");
        let mut elapsed = Vec::with_capacity(100);
        for _ in 0..100 {
            let start = std::time::Instant::now();
            crate::agent::codex_reply::recent_messages(
                session_id,
                crate::agent::codex_reply::SESSION_LOOKUP_BUDGET,
            )
            .expect("budgeted lookup");
            elapsed.push(start.elapsed());
        }
        elapsed.sort_unstable();
        assert!(elapsed[94] < crate::agent::codex_reply::SESSION_LOOKUP_BUDGET);

        restore_codex_home(previous);
        std::fs::remove_dir_all(home).expect("remove large rollout");
    }

    #[test]
    fn cache_invalidation() {
        let _guard = crate::config::test_config_env_lock().lock().unwrap();
        let home = temp_path("cache-home");
        let session_id = "019d-cache";
        let path = session_file(&home, session_id);
        std::fs::create_dir_all(path.parent().expect("session parent"))
            .expect("create session directory");
        std::fs::write(&path, rollout_record("first reply")).expect("write first reply");
        let previous = std::env::var_os("CODEX_HOME");
        std::env::set_var("CODEX_HOME", &home);

        let first = crate::agent::codex_reply::recent_messages(
            session_id,
            std::time::Duration::from_millis(150),
        )
        .expect("first lookup");
        assert_eq!(first.last().map(String::as_str), Some("first reply"));

        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("open rollout for append");
        file.write_all(rollout_record("second reply").as_bytes())
            .expect("append reply");
        file.flush().expect("flush appended reply");
        let second = crate::agent::codex_reply::recent_messages(
            session_id,
            std::time::Duration::from_millis(150),
        )
        .expect("second lookup");
        assert_eq!(second.last().map(String::as_str), Some("second reply"));

        restore_codex_home(previous);
        std::fs::remove_dir_all(home).expect("remove cache rollout");
    }
}
