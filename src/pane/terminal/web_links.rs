//! Plain-text HTTP(S) links in the visible viewport.
//!
//! Hosts only see cursor-addressed rows, so a URL that the source terminal
//! soft-wrapped loses its continuity on the way out. This module finds those
//! URLs in the source terminal and hands each covered cell the complete target
//! through the same hyperlink triples an explicit OSC 8 link uses.

use ratatui::layout::Rect;

use super::{ghostty_cell_symbol, VisibleHyperlinks};

/// What the scanner needs to know about one cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ScanCell {
    /// Empty or whitespace: ends the current token.
    Blank,
    /// Text that cannot continue a scheme (wide, non-ASCII, explicit link).
    Opaque,
    Char(char),
}

/// Finds `http://` and `https://` in reading order, once per token.
///
/// A seed is only a hint. The terminal resolves the token with its own
/// soft-wrap authority, so a false seed costs one bounded lookup and nothing
/// more. After a seed, the rest of its token yields none: an unbroken
/// over-budget token must not be re-walked once per scheme it contains.
#[derive(Debug)]
pub(super) struct SchemeScanner {
    recent: [(char, u16, u16); 8],
    len: usize,
    in_resolved_token: bool,
}

impl SchemeScanner {
    pub(super) fn new() -> Self {
        Self {
            recent: [('\0', 0, 0); 8],
            len: 0,
            in_resolved_token: false,
        }
    }

    /// A row that does not continue the previous row's soft wrap ends the token.
    pub(super) fn start_row(&mut self, continues_previous_row: bool) {
        if !continues_previous_row {
            self.len = 0;
            self.in_resolved_token = false;
        }
    }

    /// Stop seeding until the current token ends.
    pub(super) fn skip_token(&mut self) {
        self.in_resolved_token = true;
    }

    /// Returns where a scheme that ends at this cell begins.
    pub(super) fn cell(&mut self, x: u16, y: u16, cell: ScanCell) -> Option<(u16, u16)> {
        let ch = match cell {
            ScanCell::Blank => {
                self.len = 0;
                self.in_resolved_token = false;
                return None;
            }
            ScanCell::Opaque => {
                self.len = 0;
                return None;
            }
            ScanCell::Char(ch) => ch,
        };
        if self.len == self.recent.len() {
            self.recent.copy_within(1.., 0);
            self.len -= 1;
        }
        self.recent[self.len] = (ch, x, y);
        self.len += 1;
        if self.in_resolved_token {
            return None;
        }
        let (_, sx, sy) = scheme_start(&self.recent[..self.len])?;
        self.in_resolved_token = true;
        Some((sx, sy))
    }
}

fn scheme_start(window: &[(char, u16, u16)]) -> Option<(char, u16, u16)> {
    ["https://", "http://"].into_iter().find_map(|scheme| {
        let start = window.len().checked_sub(scheme.len())?;
        window[start..]
            .iter()
            .map(|(ch, _, _)| *ch)
            .eq(scheme.chars())
            .then(|| window[start])
    })
}

pub(super) fn classify(codepoint: u32, wide: crate::ghostty::CellWide) -> ScanCell {
    if wide != crate::ghostty::CellWide::Narrow {
        return ScanCell::Opaque;
    }
    match char::from_u32(codepoint) {
        None => ScanCell::Opaque,
        Some('\0') => ScanCell::Blank,
        Some(ch) if ch.is_whitespace() => ScanCell::Blank,
        Some(ch) if ch.is_ascii() => ScanCell::Char(ch),
        Some(_) => ScanCell::Opaque,
    }
}

/// Appends an inferred target to every visible cell its regions cover.
///
/// Explicit links win: a covered cell that already carries an OSC 8 target is
/// left to the explicit pass. The caller resolved each token once; this only
/// walks the rows those regions touch.
pub(super) fn append_inferred_links(
    render_state: &mut crate::ghostty::RenderState,
    area: Rect,
    inferred: &[crate::ghostty::ViewportWebLink],
    links: &mut VisibleHyperlinks,
) -> Result<(), crate::ghostty::Error> {
    let mut spans = Vec::new();
    for (link, resolved) in inferred.iter().enumerate() {
        for region in &resolved.regions {
            if region.row >= area.height || region.start_col >= area.width {
                continue;
            }
            let end = region.end_col.min(area.width - 1);
            spans.push((region.row, region.start_col, end, link));
        }
    }
    spans.sort_unstable();
    let mut row_iterator = crate::ghostty::RowIterator::new()?;
    let mut row_cells = crate::ghostty::RowCells::new()?;
    let mut rows = render_state.populate_row_iterator(&mut row_iterator)?;
    let mut next = 0;
    let mut y = 0u16;
    while next < spans.len() && rows.next() {
        if spans[next].0 == y {
            let mut cells = rows.populate_cells(&mut row_cells)?;
            while next < spans.len() && spans[next].0 == y {
                let (_, start, end, link) = spans[next];
                for x in start..=end {
                    cells.select(x)?;
                    if cells.has_hyperlink()? {
                        continue;
                    }
                    links.push((
                        (area.x + x, area.y + y),
                        ghostty_cell_symbol(&cells)?,
                        std::sync::Arc::clone(&inferred[link].uri),
                    ));
                }
                next += 1;
            }
        }
        y += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(scanner: &mut SchemeScanner, y: u16, text: &str) -> Vec<(u16, u16)> {
        text.chars()
            .enumerate()
            .filter_map(|(x, ch)| {
                let cell = if ch == ' ' {
                    ScanCell::Blank
                } else {
                    ScanCell::Char(ch)
                };
                scanner.cell(x as u16, y, cell)
            })
            .collect()
    }

    #[test]
    fn hrdr25_boundaries_scanner_reports_scheme_start_once_per_token() {
        let mut scanner = SchemeScanner::new();
        assert_eq!(
            feed(&mut scanner, 0, "see (https://a.test/ x"),
            vec![(5, 0)]
        );
        let mut scanner = SchemeScanner::new();
        assert_eq!(
            feed(&mut scanner, 0, "http://a https://b"),
            vec![(0, 0), (9, 0)]
        );
        let mut scanner = SchemeScanner::new();
        assert_eq!(feed(&mut scanner, 0, "xhttp://a,http://b"), vec![(1, 0)]);
        let mut scanner = SchemeScanner::new();
        assert!(feed(&mut scanner, 0, "HTTP://a ftp://b http:/c").is_empty());
    }

    #[test]
    fn hrdr25_boundaries_scanner_follows_soft_wraps_and_stops_at_hard_breaks() {
        let mut scanner = SchemeScanner::new();
        assert!(feed(&mut scanner, 0, "ab http").is_empty());
        scanner.start_row(true);
        assert_eq!(feed(&mut scanner, 1, "s://x"), vec![(3, 0)]);

        let mut scanner = SchemeScanner::new();
        assert!(feed(&mut scanner, 0, "ab http").is_empty());
        scanner.start_row(false);
        assert!(feed(&mut scanner, 1, "s://x").is_empty());
    }

    #[test]
    fn hrdr25_budget_scanner_skips_the_rest_of_an_unbroken_token() {
        let mut scanner = SchemeScanner::new();
        let token = "http://".repeat(2000);
        assert_eq!(feed(&mut scanner, 0, &token), vec![(0, 0)]);
        // Wrapped continuation of the same token stays skipped, a hard break
        // or a blank allows the next token to seed again.
        scanner.start_row(true);
        assert!(feed(&mut scanner, 1, "https://more").is_empty());
        scanner.start_row(false);
        assert_eq!(feed(&mut scanner, 2, "https://next"), vec![(0, 2)]);
        assert!(feed(&mut scanner, 2, " ").is_empty());
        assert_eq!(feed(&mut scanner, 2, "http://again"), vec![(0, 2)]);
    }

    #[test]
    fn hrdr25_boundaries_scanner_skip_token_suppresses_until_blank() {
        let mut scanner = SchemeScanner::new();
        scanner.skip_token();
        assert!(feed(&mut scanner, 0, "xxhttp://a").is_empty());
        assert_eq!(feed(&mut scanner, 0, " http://b"), vec![(1, 0)]);
    }

    #[test]
    fn hrdr25_boundaries_classify_cells() {
        use crate::ghostty::CellWide;
        assert_eq!(classify(0, CellWide::Narrow), ScanCell::Blank);
        assert_eq!(classify(' ' as u32, CellWide::Narrow), ScanCell::Blank);
        assert_eq!(classify('h' as u32, CellWide::Narrow), ScanCell::Char('h'));
        assert_eq!(classify('é' as u32, CellWide::Narrow), ScanCell::Opaque);
        assert_eq!(classify('界' as u32, CellWide::Wide), ScanCell::Opaque);
        assert_eq!(classify(0, CellWide::SpacerTail), ScanCell::Opaque);
    }
}
