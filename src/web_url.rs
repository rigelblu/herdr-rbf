//! Plain-text web URL grammar shared by word selection and terminal link
//! projection. It maps text to display cells, then finds an `http(s)://` token
//! and trims trailing sentence punctuation and unbalanced closers.

pub(crate) fn safe_web_url(url: &str) -> Option<&str> {
    (url.starts_with("http://") || url.starts_with("https://")).then_some(url)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TextCell {
    pub(crate) ch: char,
    pub(crate) start_col: u16,
    pub(crate) end_col: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CellSpan {
    pub(crate) start: usize,
    pub(crate) end: usize,
}

impl CellSpan {
    pub(crate) fn contains(self, idx: usize) -> bool {
        idx >= self.start && idx <= self.end
    }

    pub(crate) fn columns(self, cells: &[TextCell]) -> (u16, u16) {
        (cells[self.start].start_col, cells[self.end].end_col)
    }
}

pub(crate) fn url_byte_range(text: &str, clicked_byte: usize) -> Option<std::ops::Range<usize>> {
    let clicked_idx = text.get(..clicked_byte)?.chars().count();
    let cells = text_cells(text);
    let span = url_span_at_column(&cells, clicked_idx)?;
    let start = byte_index_for_cell(text, span.start);
    let end = byte_index_after_cell(text, span.end);
    safe_web_url(text.get(start..end)?)?;
    Some(start..end)
}

pub(crate) fn text_cells(row: &str) -> Vec<TextCell> {
    let mut next_col = 0u16;
    row.chars()
        .map(|ch| {
            let width = u16::from(crate::ghostty::unicode_codepoint_width(ch as u32));
            let start_col = if width == 0 {
                next_col.saturating_sub(1)
            } else {
                next_col
            };
            if width > 0 {
                next_col = next_col.saturating_add(width);
            }
            TextCell {
                ch,
                start_col,
                end_col: next_col.saturating_sub(1),
            }
        })
        .collect()
}

pub(crate) fn byte_index_for_cell(row: &str, cell_idx: usize) -> usize {
    row.char_indices()
        .nth(cell_idx)
        .map(|(idx, _)| idx)
        .unwrap_or(row.len())
}

pub(crate) fn byte_index_after_cell(row: &str, cell_idx: usize) -> usize {
    row.char_indices()
        .nth(cell_idx.saturating_add(1))
        .map(|(idx, _)| idx)
        .unwrap_or(row.len())
}

pub(crate) fn url_span_at_column(cells: &[TextCell], clicked_idx: usize) -> Option<CellSpan> {
    let mut start = 0;
    while start < cells.len() {
        if starts_with_chars(&cells[start..], "http://")
            || starts_with_chars(&cells[start..], "https://")
        {
            let mut end = start;
            while end + 1 < cells.len() && !cells[end + 1].ch.is_whitespace() {
                end += 1;
            }
            if clicked_idx >= start && clicked_idx <= end {
                let span = trim_url_edges(cells, CellSpan { start, end })?;
                return span.contains(clicked_idx).then_some(span);
            }
            start = end + 1;
        } else {
            start += 1;
        }
    }
    None
}

fn trim_url_edges(cells: &[TextCell], span: CellSpan) -> Option<CellSpan> {
    let start = span.start;
    let mut end = span.end;
    // Net open-minus-close count per bracket pair over the cells before `end`,
    // kept as `end` moves left so each trim step costs O(1).
    let mut depth = [0i32; 3];
    for cell in &cells[start..=end] {
        if let Some((pair, delta)) = bracket_delta(cell.ch) {
            depth[pair] += delta;
        }
    }
    while start <= end {
        let ch = cells[end].ch;
        if let Some((pair, delta)) = bracket_delta(ch) {
            depth[pair] -= delta;
        }
        if !should_trim_trailing_url_cell(ch, &depth) {
            break;
        }
        if end == 0 {
            return None;
        }
        end -= 1;
    }
    (start <= end).then_some(CellSpan { start, end })
}

/// Bracket pair index and the effect of this character on its open count.
fn bracket_delta(ch: char) -> Option<(usize, i32)> {
    match ch {
        '(' => Some((0, 1)),
        ')' => Some((0, -1)),
        '[' => Some((1, 1)),
        ']' => Some((1, -1)),
        '{' => Some((2, 1)),
        '}' => Some((2, -1)),
        _ => None,
    }
}

/// `depth` counts the cells before `ch`; a closer stays only if it balances one.
fn should_trim_trailing_url_cell(ch: char, depth: &[i32; 3]) -> bool {
    match ch {
        '"' | '\'' | '`' | '.' | ',' | ';' | ':' | '!' | '?' => true,
        ')' => depth[0] <= 0,
        ']' => depth[1] <= 0,
        '}' => depth[2] <= 0,
        _ => false,
    }
}

fn starts_with_chars(cells: &[TextCell], prefix: &str) -> bool {
    prefix
        .chars()
        .enumerate()
        .all(|(idx, expected)| cells.get(idx).is_some_and(|cell| cell.ch == expected))
}
