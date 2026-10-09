//! Non-gating profile of visible hyperlink projection, the per-frame work that
//! turns terminal cells into link targets for every painted pane.
//!
//! It uses only `visible_hyperlinks`, so the same file runs unchanged against
//! the parent to give a comparable baseline:
//! `just bench-render-scale` (filter `render_scale_profile`), or just this
//! profile with
//! `cargo test --release --locked --bin herdr render_scale_profile_web_link -- --ignored --nocapture --test-threads=1`.
use super::*;

const COLS: u16 = 120;
const ROWS: u16 = 40;

#[derive(Clone, Copy)]
enum Content {
    /// Prose only: the scan runs and finds nothing.
    Ordinary,
    /// Every third row starts a long URL that wraps over several rows.
    Urls,
    /// One unbroken token past the 8192-cell budget, in two shapes.
    OverBudget,
    /// An over-budget token built entirely from repeated schemes.
    OverBudgetSchemes,
}

impl Content {
    const ALL: [(Content, &'static str); 4] = [
        (Content::Ordinary, "ordinary"),
        (Content::Urls, "urls"),
        (Content::OverBudget, "over_budget"),
        (Content::OverBudgetSchemes, "over_budget_schemes"),
    ];

    fn bytes(self) -> Vec<u8> {
        let mut out = String::new();
        match self {
            Content::Ordinary => {
                for line in 0..ROWS {
                    out.push_str(&format!(
                        "{line:04} populated terminal row with ordinary prose 界\r\n"
                    ));
                }
            }
            Content::Urls => {
                for line in 0..ROWS {
                    if line % 3 == 0 {
                        out.push_str(&format!(
                            "{line:04} see https://example.com/profile/{}end now\r\n",
                            "wrapped-segment-".repeat(14)
                        ));
                    } else {
                        out.push_str(&format!(
                            "{line:04} populated terminal row, docs at (https://example.com/{line}).\r\n"
                        ));
                    }
                }
            }
            Content::OverBudget => {
                out.push_str("https://example.com/");
                out.push_str(&"a".repeat(9000));
                out.push_str("\r\n");
            }
            Content::OverBudgetSchemes => {
                out.push_str(&"http://".repeat(1300));
                out.push_str("\r\n");
            }
        }
        out.into_bytes()
    }
}

fn pane_with(content: Content) -> PaneTerminal {
    let (tx, _rx) = mpsc::channel(16);
    let terminal = crate::ghostty::Terminal::new(COLS, ROWS, 4 * 1024 * 1024).unwrap();
    let pane = PaneTerminal::new(GhosttyPaneTerminal::new(terminal, tx.clone()).unwrap());
    let bytes = content.bytes();
    pane.process_pty_bytes(PaneId::from_raw(1), 0, &bytes, &tx);
    pane
}

#[test]
#[ignore = "non-gating release render scaling profile"]
fn render_scale_profile_web_link_projection() {
    let area = Rect::new(0, 0, COLS, ROWS);
    for (content, name) in Content::ALL {
        for count in [1, 15] {
            let panes = (0..count).map(|_| pane_with(content)).collect::<Vec<_>>();
            let linked = panes[0].visible_hyperlinks(area).len();
            let mut samples = Vec::new();
            for sample in 0..35 {
                let start = std::time::Instant::now();
                for _ in 0..20 {
                    for pane in &panes {
                        std::hint::black_box(pane.visible_hyperlinks(area));
                    }
                }
                if sample >= 5 {
                    samples.push(start.elapsed().as_nanos() / 20);
                }
            }
            samples.sort_unstable();
            eprintln!(
                "web_link_projection_scale content={name} panes={count} linked_cells_per_pane={linked} median_ns={} p95_ns={}",
                samples[samples.len() / 2],
                samples[samples.len() * 95 / 100]
            );
        }
    }
}
