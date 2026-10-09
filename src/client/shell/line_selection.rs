use super::*;

#[derive(Clone, Debug)]
pub(super) struct ClientLineSelection {
    pub(super) pane_id: String,
    pub(super) focus_confirmed: bool,
    pub(super) anchor_row: u32,
    pub(super) cursor_row: u32,
    pub(super) start_col: u16,
    pub(super) end_col: u16,
    pub(super) dragged: bool,
}

impl ClientShellState {
    pub(super) fn start_line_selection(
        &mut self,
        hit: &PaneHit,
        viewport_row: u16,
        col: u16,
        outcome: &mut ClientShellInput,
    ) {
        if hit.inner_rect.width == 0 || hit.inner_rect.height == 0 {
            return;
        }
        let end_col = hit.inner_rect.width.saturating_sub(1);
        let row = crate::selection::absolute_row_for_viewport(viewport_row, hit.scroll);

        // Invalidate in-flight word selection so delayed reply cannot supersede line selection
        self.word_selection_generation = self.word_selection_generation.saturating_add(1);
        self.word_selection_gesture = None;
        self.stop_selection_autoscroll();
        self.selection_highlight_clear_deadline = None;

        self.line_selection_gesture = Some(ClientLineSelection {
            pane_id: hit.pane_id.clone(),
            focus_confirmed: self
                .snapshot
                .as_deref()
                .and_then(|snapshot| snapshot.focused_pane_id.as_deref())
                == Some(hit.pane_id.as_str()),
            anchor_row: row,
            cursor_row: row,
            start_col: col,
            end_col,
            dragged: false,
        });

        self.selection = Some(crate::selection::Selection::line_range(
            hit.pane_id.clone(),
            row,
            row,
            end_col,
        ));
        outcome.repaint = true;
    }

    pub(super) fn drag_line_selection(
        &mut self,
        hit: &PaneHit,
        screen_col: u16,
        screen_row: u16,
        metrics: Option<crate::pane::ScrollMetrics>,
        outcome: &mut ClientShellInput,
    ) {
        let Some(gesture) = self.line_selection_gesture.as_mut() else {
            return;
        };
        let viewport_row = screen_row
            .saturating_sub(hit.inner_rect.y)
            .min(hit.inner_rect.height.saturating_sub(1));
        let col = screen_col
            .saturating_sub(hit.inner_rect.x)
            .min(hit.inner_rect.width.saturating_sub(1));
        let cursor_row = crate::selection::absolute_row_for_viewport(viewport_row, metrics);
        let top = hit.inner_rect.y;
        let bottom = hit.inner_rect.y + hit.inner_rect.height.saturating_sub(1);
        let left = hit.inner_rect.x;
        let right = hit.inner_rect.x + hit.inner_rect.width.saturating_sub(1);
        let moved_row = gesture.cursor_row != cursor_row;
        let moved_col = col != gesture.start_col;
        let outside_pane =
            screen_row < top || screen_row > bottom || screen_col < left || screen_col > right;
        if moved_row || moved_col || outside_pane {
            gesture.dragged = true;
        }
        if moved_row {
            gesture.cursor_row = cursor_row;
            self.selection = Some(crate::selection::Selection::line_range(
                hit.pane_id.clone(),
                gesture.anchor_row,
                cursor_row,
                gesture.end_col,
            ));
            outcome.repaint = true;
        }
    }

    pub(super) fn finish_line_selection(&mut self, outcome: &mut ClientShellInput) {
        self.stop_selection_autoscroll();
        let Some(gesture) = self.line_selection_gesture.take() else {
            return;
        };
        if let Some(selection) = self.selection.as_mut() {
            selection.finish();
        }
        if self.config.copy_on_select {
            self.request_selection_copy(outcome, true);
            if gesture.dragged {
                self.selection = None;
            } else {
                self.selection_highlight_clear_deadline =
                    Some(std::time::Instant::now() + std::time::Duration::from_millis(500));
            }
        }
    }
}
