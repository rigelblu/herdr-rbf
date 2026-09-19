use super::*;

impl HeadlessServer {
    pub(super) fn handle_client_shell_endpoint_request(
        &mut self,
        client_id: u64,
        boot_id: String,
        mut request: Box<api::schema::Request>,
    ) -> bool {
        let Some(client) = self.clients.get(&client_id) else {
            return false;
        };
        if !matches!(client.mode, ClientConnectionMode::ClientShell) {
            self.remove_client_and_resize_if_needed(client_id);
            return true;
        }
        let request_id = request.id.clone();
        if !crate::server::client_commands::supports_client_shell_method(&request.method) {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "unsupported_endpoint_command",
                "this method is not available through the client shell command lane",
            );
            self.send_to_client(client_id, message);
            return false;
        }
        if boot_id != self.client_shell_boot_id {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "stale_boot",
                "endpoint command targeted an earlier server boot",
            );
            self.send_to_client(client_id, message);
            return false;
        }
        let surface_active = client.shell_surface_active;
        if let api::schema::Method::ClientShellSurfaceSet(params) = &request.method {
            let Some((changed, projection_revision)) =
                self.set_client_shell_surface_active(client_id, params.active)
            else {
                return false;
            };
            self.send_to_client(
                client_id,
                crate::server::client_commands::success_message_with_result(
                    boot_id,
                    request_id,
                    api::schema::ResponseResult::ClientShellSurfaceSet {
                        active: params.active,
                        projection_revision,
                    },
                ),
            );
            return changed;
        }
        if client.shell_endpoint_command_in_flight {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "endpoint_busy",
                "this endpoint is still processing another command",
            );
            self.send_to_client(client_id, message);
            return false;
        }
        if let api::schema::Method::TerminalAttach(params) = &request.method {
            return self.handle_semantic_terminal_attach(
                client_id,
                boot_id,
                request_id,
                params.clone(),
            );
        }
        if !surface_active {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "surface_inactive",
                "this method requires an active client shell surface",
            );
            self.send_to_client(client_id, message);
            return false;
        }
        if self.attached_shell_target(client_id).is_some()
            && !matches!(
                &request.method,
                api::schema::Method::PaneSelectionRead(_)
                    | api::schema::Method::PaneSelectionReadJoined(_)
            )
        {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "unsupported_endpoint_command",
                "attached terminals only accept selection reads",
            );
            self.send_to_client(client_id, message);
            return false;
        }

        let api_request_id = format!(
            "endpoint:{}:{client_id}:{request_id}",
            self.client_shell_boot_id
        );
        request.id = api_request_id.clone();
        let (respond_to, response_rx) = std::sync::mpsc::channel();
        if let Err(err) = crate::server::client_commands::spawn_response_waiter(
            client_id,
            boot_id.clone(),
            request_id.clone(),
            response_rx,
            self.server_event_tx.clone(),
        ) {
            let message = crate::server::client_commands::error_message(
                boot_id,
                request_id,
                "server_unavailable",
                format!("failed to start endpoint response bridge: {err}"),
            );
            self.send_to_client(client_id, message);
            return false;
        }
        if let Some(client) = self.clients.get_mut(&client_id) {
            client.shell_endpoint_command_in_flight = true;
            // A later source restore has a new projection revision. Keep this request's lease
            // so a delayed worktree response cannot focus a pane after endpoint switching.
            client.shell_endpoint_command_surface_revision = Some(client.shell_projection_revision);
            let deferred_worktree = matches!(
                &request.method,
                api::schema::Method::WorktreeCreate(_) | api::schema::Method::WorktreeRemove(_)
            );
            let deferred_navigation = matches!(
                &request.method,
                api::schema::Method::WorktreeCreate(params) if params.focus
            );
            client.shell_deferred_navigation_request_id =
                deferred_worktree.then(|| api_request_id.clone());
            client.shell_deferred_navigation_response = deferred_navigation.then(Vec::new);
        }
        let foreground_changed = self.promote_client_to_foreground(client_id);
        foreground_changed
            | self.handle_client_shell_api_request(
                client_id,
                api::ApiRequestMessage {
                    request: *request,
                    respond_to,
                    response_write_complete: None,
                    stream_active: None,
                },
            )
    }

    fn handle_semantic_terminal_attach(
        &mut self,
        client_id: u64,
        boot_id: String,
        request_id: String,
        params: api::schema::TerminalAttachParams,
    ) -> bool {
        if self.attached_shell_target(client_id).is_some() {
            self.send_to_client(
                client_id,
                crate::server::client_commands::error_message(
                    boot_id,
                    request_id,
                    "terminal_attach_failed",
                    "this connection is already attached to a terminal",
                ),
            );
            return false;
        }
        let Some(terminal_id) = self.resolve_terminal_target_id_string(&params.terminal_id) else {
            self.send_to_client(
                client_id,
                crate::server::client_commands::error_message(
                    boot_id,
                    request_id,
                    "terminal_not_found",
                    format!(
                        "terminal attach failed: terminal {} not found",
                        params.terminal_id
                    ),
                ),
            );
            return false;
        };
        let target = match self.app.resolve_terminal_target(&terminal_id) {
            Ok(target) => target,
            Err(_) => {
                self.send_to_client(
                    client_id,
                    crate::server::client_commands::error_message(
                        boot_id,
                        request_id,
                        "terminal_not_found",
                        format!("terminal attach failed: terminal {terminal_id} not found"),
                    ),
                );
                return false;
            }
        };
        let Some(pane_id) = self.app.public_pane_id(target.ws_idx, target.pane_id) else {
            self.send_to_client(
                client_id,
                crate::server::client_commands::error_message(
                    boot_id,
                    request_id,
                    "terminal_not_found",
                    format!("terminal attach failed: terminal {terminal_id} not found"),
                ),
            );
            return false;
        };
        let real_terminal_id =
            match self.claim_terminal_attachment(client_id, &terminal_id, params.takeover) {
                Ok(terminal_id) => terminal_id,
                Err(reason) => {
                    self.send_to_client(
                        client_id,
                        crate::server::client_commands::error_message(
                            boot_id,
                            request_id,
                            "terminal_attach_failed",
                            reason,
                        ),
                    );
                    return false;
                }
            };

        let stamp = self.allocate_activity_stamp();
        let Some(client) = self.clients.get_mut(&client_id) else {
            return false;
        };
        let (cols, rows) = client.terminal_size;
        let cell_size = client.cell_size;
        client.shell_presentation = Some(
            crate::server::clients::ClientShellPresentation::AttachedTerminal {
                terminal_id: terminal_id.clone(),
            },
        );
        client.shell_projection_revision = client.shell_projection_revision.saturating_add(1);
        let projection_revision = client.shell_projection_revision;
        client.shell_snapshot = None;
        client.shell_surface_active = true;
        client.render_state.reset_baseline();
        client.request_repaint();
        client.last_activity = stamp;

        self.tab_geometry_controllers
            .retain(|_, controller_id| *controller_id != client_id);
        self.promote_client_to_foreground(client_id);
        self.resize_attached_terminal(&real_terminal_id, rows, cols, cell_size);
        self.send_to_client(
            client_id,
            crate::server::client_commands::success_message_with_result(
                boot_id,
                request_id,
                api::schema::ResponseResult::TerminalAttached {
                    pane_id,
                    projection_revision,
                },
            ),
        );
        self.sync_terminal_attach_titles();
        true
    }
}
