//! Visible hyperlink projection of plain HTTP(S) text, read back from a real
//! source terminal through `visible_hyperlinks`, the call every painted frame
//! makes. Targets are asserted per cell, not per link.
use std::collections::{BTreeMap, BTreeSet};

use super::*;

/// Source terminal behind a `PaneTerminal`.
struct Source {
    pane: PaneTerminal,
    tx: mpsc::Sender<Bytes>,
    cols: u16,
    rows: u16,
}

impl Source {
    fn new(cols: u16, rows: u16, bytes: &[u8]) -> Self {
        let (tx, _rx) = mpsc::channel(16);
        let terminal = crate::ghostty::Terminal::new(cols, rows, 1024 * 1024).unwrap();
        let source = Self {
            pane: PaneTerminal::new(GhosttyPaneTerminal::new(terminal, tx.clone()).unwrap()),
            tx,
            cols,
            rows,
        };
        source.write(bytes);
        source
    }

    fn write(&self, bytes: &[u8]) {
        self.pane
            .process_pty_bytes(PaneId::from_raw(1), 0, bytes, &self.tx);
    }

    fn resize(&mut self, cols: u16, rows: u16) {
        self.pane.resize(rows, cols, 8, 16);
        self.cols = cols;
        self.rows = rows;
    }

    /// Target by cell for every cell the host would link.
    fn links(&self) -> BTreeMap<(u16, u16), String> {
        self.pane
            .visible_hyperlinks(Rect::new(0, 0, self.cols, self.rows))
            .into_iter()
            .map(|(cell, _symbol, uri)| (cell, uri))
            .collect()
    }
}

/// `(row, first_col, last_col)` spans, inclusive, as the cells they cover.
fn cells(spans: &[(u16, u16, u16)]) -> BTreeSet<(u16, u16)> {
    spans
        .iter()
        .flat_map(|&(row, first, last)| (first..=last).map(move |x| (x, row)))
        .collect()
}

#[track_caller]
fn assert_links(source: &Source, spans: &[(u16, u16, u16)], uri: &str) {
    let links = source.links();
    assert_eq!(
        links.keys().copied().collect::<BTreeSet<_>>(),
        cells(spans),
        "linked cells"
    );
    assert!(
        links.values().all(|target| target == uri),
        "every linked cell carries {uri}: {links:?}"
    );
}

#[test]
fn hrdr25_boundaries_http_and_https_cover_one_and_several_rows() {
    let url = "https://example.com/a?b=c#d";
    let one_row = Source::new(80, 4, format!("see {url} end").as_bytes());
    assert_links(&one_row, &[(0, 4, 30)], url);

    let plain = "http://example.com/a?b=c#d";
    let one_row = Source::new(80, 4, format!("{plain}").as_bytes());
    assert_links(&one_row, &[(0, 0, 25)], plain);

    let wrapped = Source::new(12, 5, url.as_bytes());
    assert_links(&wrapped, &[(0, 0, 11), (1, 0, 11), (2, 0, 2)], url);

    let wrapped_http = Source::new(10, 5, format!("go {plain} x").as_bytes());
    assert_links(
        &wrapped_http,
        &[(0, 3, 9), (1, 0, 9), (2, 0, 8)],
        plain,
    );
}

#[test]
fn hrdr25_boundaries_exclude_surrounding_and_trailing_punctuation() {
    let url = "https://example.com/a";
    let wrapped = Source::new(80, 3, format!("({url}).").as_bytes());
    assert_links(&wrapped, &[(0, 1, 21)], url);

    let comma = Source::new(80, 3, format!("{url}, next").as_bytes());
    assert_links(&comma, &[(0, 0, 20)], url);

    let balanced = "https://example.com/a(b)";
    let kept = Source::new(80, 3, format!("{balanced}.").as_bytes());
    assert_links(&kept, &[(0, 0, 23)], balanced);

    let narrow = Source::new(8, 5, format!("({url}).").as_bytes());
    assert_links(&narrow, &[(0, 1, 7), (1, 0, 7), (2, 0, 5)], url);
}

#[test]
fn hrdr25_boundaries_stop_at_a_hard_newline() {
    let first = "https://example.com/a";
    let second = "https://b.test/2";
    let source = Source::new(
        80,
        4,
        format!("{first}\r\nnext-token {second}\r\nplain").as_bytes(),
    );
    let links = source.links();
    assert_eq!(
        links.keys().copied().collect::<BTreeSet<_>>(),
        cells(&[(0, 0, 20), (1, 11, 26)])
    );
    assert_eq!(links[&(0, 0)], first);
    assert_eq!(links[&(20, 0)], first);
    assert_eq!(links[&(11, 1)], second);
    assert!(!links.contains_key(&(0, 1)), "next-token stays plain text");

    // A hard newline exactly at the width is not a soft wrap.
    let exact = Source::new(10, 4, b"https://ab\r\nhttps://cd");
    let links = exact.links();
    assert_eq!(links[&(0, 0)], "https://ab");
    assert_eq!(links[&(9, 0)], "https://ab");
    assert_eq!(links[&(0, 1)], "https://cd");
    assert_eq!(links[&(9, 1)], "https://cd");
    assert_eq!(links.len(), 20);
}

#[test]
fn hrdr25_boundaries_explicit_targets_win_over_url_labels() {
    let label = "\x1b]8;;https://target.test/x\x1b\\click here\x1b]8;;\x1b\\";
    let source = Source::new(80, 3, label.as_bytes());
    assert_links(&source, &[(0, 0, 9)], "https://target.test/x");

    let url_label = "\x1b]8;;https://target.test/x\x1b\\https://label.test/y\x1b]8;;\x1b\\";
    let source = Source::new(80, 3, url_label.as_bytes());
    assert_links(&source, &[(0, 0, 19)], "https://target.test/x");

    let mixed = "https://plain.test/p \x1b]8;;https://exp.test/e\x1b\\label\x1b]8;;\x1b\\";
    let source = Source::new(80, 3, mixed.as_bytes());
    let links = source.links();
    assert_eq!(links[&(0, 0)], "https://plain.test/p");
    assert_eq!(links[&(19, 0)], "https://plain.test/p");
    assert!(!links.contains_key(&(20, 0)));
    assert_eq!(links[&(21, 0)], "https://exp.test/e");
    assert_eq!(links[&(25, 0)], "https://exp.test/e");
    assert_eq!(links.len(), 20 + 5);
}

#[test]
fn hrdr25_boundaries_ignore_other_schemes_and_invalid_text() {
    for text in [
        "file:///tmp/a",
        "ftp://example.com/a",
        "javascript:alert(1)",
        "HTTPS://example.com/a",
        "http:/example.com",
        "see https",
    ] {
        assert!(Source::new(40, 3, text.as_bytes()).links().is_empty(), "{text}");
    }
}

const LONG: &str = "https://example.com/abcdefghijabcdefghijabcdefghij";

#[test]
fn hrdr25_viewport_clipped_top_keeps_the_complete_target() {
    let mut source = Source::new(20, 3, format!("{LONG}\r\nx\r\ny\r\nz").as_bytes());
    assert!(source.links().is_empty(), "link scrolled out of view");
    source.pane.scroll_up(1);
    assert_links(&source, &[(0, 0, 9)], LONG);
    source.pane.scroll_up(1);
    assert_links(&source, &[(0, 0, 19), (1, 0, 9)], LONG);
    source.pane.scroll_reset();
    assert!(source.links().is_empty());
}

#[test]
fn hrdr25_viewport_clipped_bottom_keeps_the_complete_target() {
    let mut source = Source::new(20, 3, format!("a\r\nb\r\n{LONG}\r\nc").as_bytes());
    source.pane.scroll_up(10);
    assert_links(&source, &[(2, 0, 19)], LONG);
    source.pane.scroll_down(1);
    assert_links(&source, &[(1, 0, 19), (2, 0, 19)], LONG);
    source.pane.scroll_reset();
    assert_links(&source, &[(0, 0, 19), (1, 0, 9)], LONG);
}

#[test]
fn hrdr25_viewport_wide_and_combining_cells_map_exactly() {
    let url = "https://example.com/路径e\u{301}x";
    let source = Source::new(40, 3, format!("{url} tail").as_bytes());
    // 20 ASCII cells, two wide glyphs (2 cells each), e+mark in one cell, x.
    assert_links(&source, &[(0, 0, 25)], url);

    // A wide glyph that does not fit moves to the next row and leaves the
    // spacer cell before it outside the link.
    let wrapped = Source::new(21, 3, "https://example.com/路径".as_bytes());
    assert_links(
        &wrapped,
        &[(0, 0, 19), (1, 0, 3)],
        "https://example.com/路径",
    );
}

#[test]
fn hrdr25_viewport_follows_resize_and_text_replacement() {
    let mut source = Source::new(30, 6, LONG.as_bytes());
    assert_links(&source, &[(0, 0, 29), (1, 0, 19)], LONG);
    source.resize(20, 6);
    assert_links(&source, &[(0, 0, 19), (1, 0, 19), (2, 0, 9)], LONG);
    source.resize(80, 6);
    assert_links(&source, &[(0, 0, 49)], LONG);
    source.resize(24, 6);
    assert_links(&source, &[(0, 0, 23), (1, 0, 23), (2, 0, 1)], LONG);

    // Overwriting the scheme leaves ordinary text and no stale target.
    source.write(b"\x1b[HXXXXX");
    assert!(source.links().is_empty());

    source.write(b"\x1b[2J\x1b[Hhttps://other.test/z tail");
    assert_links(&source, &[(0, 0, 19)], "https://other.test/z");
    source.write(b"\x1b[2J\x1b[Hplain text only");
    assert!(source.links().is_empty());
}

#[test]
fn hrdr25_budget_over_budget_tokens_fail_closed_without_hiding_neighbours() {
    let over = format!("https://example.com/{}", "a".repeat(9000));
    let ok = "https://ok.test/1";
    let source = Source::new(80, 12, format!("{over}\r\n{ok}").as_bytes());
    let links = source.links();
    assert_eq!(links.len(), ok.len());
    assert!(links.values().all(|target| target == ok));

    let schemes = "http://".repeat(1300);
    let source = Source::new(80, 12, format!("{schemes}\r\n{ok}").as_bytes());
    let links = source.links();
    assert_eq!(links.len(), ok.len());
    assert!(links.values().all(|target| target == ok));
}
