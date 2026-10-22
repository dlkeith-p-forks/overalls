use adw::prelude::*;
use adw::{Application, ApplicationWindow};
use gtk::{gio, glib, Align, Box, Button, Entry, Label, Orientation};
use mila_native_linux::adapter::{
    format_machine_action, format_share_command, format_ssh_key_revoke, format_thread_command,
    format_thread_turns, format_web_command, TerminalStream,
};
use mila_native_linux::route::{parse_activation_uris, ActivationRoute};
use mila_native_linux::session::{
    ApprovalInfo, SessionBinding, SignInEvent, SignInFlow, SignInPhase, WhoamiOutcome,
};
use std::{cell::RefCell, rc::Rc};
mod persistence;
mod strings;
const APPLICATION_ID: &str = "dev.overalls.Mila.Linux";
#[derive(Clone)]
struct NativeState {
    status: Rc<RefCell<Option<Label>>>,
    sign_in: Rc<RefCell<SignInFlow>>,
    session: Rc<RefCell<SessionBinding>>,
}
impl NativeState {
    fn new() -> Self {
        Self {
            status: Rc::new(RefCell::new(None)),
            sign_in: Rc::new(RefCell::new(SignInFlow::default())),
            session: Rc::new(RefCell::new(SessionBinding::default())),
        }
    }
    fn ensure_window(&self, app: &adw::Application) -> ApplicationWindow {
        if let Some(window) = app.active_window() {
            if let Ok(window) = window.downcast::<ApplicationWindow>() {
                return window;
            }
        }
        let root = Box::new(Orientation::Vertical, 12);
        root.set_margin_top(24);
        root.set_margin_bottom(24);
        root.set_margin_start(24);
        root.set_margin_end(24);
        let title_text = strings::text(strings::Message::AppName);
        let title = Label::new(Some(&title_text));
        title.set_halign(Align::Start);
        title.add_css_class("title-1");
        root.append(&title);
        let nav = Box::new(Orientation::Horizontal, 8);
        let ready_text = strings::text(strings::Message::Ready);
        let content = Label::new(Some(&ready_text));
        content.set_wrap(true);
        content.set_halign(Align::Start);
        *self.status.borrow_mut() = Some(content.clone());
        for (name, text) in [
            ("Machines", "Machines\nSelect a machine to view its status."),
            ("Threads", "Threads\nRecent conversations appear here."),
            (
                "Settings",
                "Settings\nRuntime settings are managed by the core library.",
            ),
        ] {
            let button = Button::with_label(name);
            let label = content.clone();
            let text = text.to_string();
            button.connect_clicked(move |_| label.set_label(&text));
            nav.append(&button);
        }
        root.append(&nav);

        let settings = persistence::load_settings().unwrap_or_default();
        let appearance_label = Label::new(Some(&strings::text(strings::Message::Appearance)));
        appearance_label.set_halign(Align::Start);
        root.append(&appearance_label);
        let settings_actions = Box::new(Orientation::Horizontal, 8);
        for (label, appearance) in [
            (
                strings::text(strings::Message::AppearanceSystem),
                persistence::Appearance::System,
            ),
            (
                strings::text(strings::Message::AppearanceLight),
                persistence::Appearance::Light,
            ),
            (
                strings::text(strings::Message::AppearanceDark),
                persistence::Appearance::Dark,
            ),
        ] {
            let button = Button::with_label(&label);
            let status = content.clone();
            let locale = settings.locale.clone();
            button.connect_clicked(move |_| {
                let value = persistence::Settings {
                    appearance,
                    locale: locale.clone(),
                };
                match persistence::save_settings(&value) {
                    Ok(()) => status.set_label(&format!(
                        "{}: {:?}",
                        strings::text(strings::Message::Appearance),
                        appearance
                    )),
                    Err(_) => status.set_label("Settings could not be saved."),
                }
            });
            settings_actions.append(&button);
        }
        root.append(&settings_actions);
        let locale = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::Locale))
            .text(&settings.locale)
            .hexpand(true)
            .build();
        let save_settings = Button::with_label(&strings::text(strings::Message::SaveSettings));
        let locale_input = locale.clone();
        let settings_status = content.clone();
        let saved_appearance = settings.appearance;
        save_settings.connect_clicked(move |_| {
            match persistence::Settings::validate(saved_appearance, locale_input.text().as_str())
                .and_then(|value| persistence::save_settings(&value).map(|_| value))
            {
                Ok(value) => {
                    settings_status.set_label(&format!("Settings saved: {}", value.locale))
                }
                Err(_) => settings_status.set_label("Settings locale rejected by Rust policy."),
            }
        });
        root.append(&locale);
        root.append(&save_settings);

        let deployment = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::DeploymentSelect))
            .hexpand(true)
            .build();
        if let Ok(Some(selection)) = persistence::load() {
            deployment.set_text(&selection.host);
        }
        let select = Button::with_label(&strings::text(strings::Message::SelectDeployment));
        let deployment_status = content.clone();
        let deployment_input = deployment.clone();
        select.connect_clicked(move |_| {
            let host = deployment_input.text().trim().to_owned();
            match persistence::DeploymentSelection::validate(&host) {
                Ok(selection) => {
                    let route = selection.route();
                    let _ = persistence::save(&selection);
                    let parsed = ActivationRoute::parse(&route).expect("validated route");
                    deployment_status
                        .set_label(&format!("Deployment selected\n{}", parsed.canonical()))
                }
                Err(_) => deployment_status.set_label("Deployment host rejected by Rust policy."),
            }
        });
        root.append(&deployment);
        root.append(&select);

        // The lifecycle controls are deliberately state-only until the host
        // supplies its owner-only Linux device signer and HTTPS trust fetcher.
        // They still exercise the same generation/approval/reconnect reducer as
        // the connected path and never claim authenticated authority locally.
        let sign_in_controls = Box::new(Orientation::Horizontal, 8);
        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let sign_in_button = Button::with_label(&strings::text(strings::Message::SignInStart));
        sign_in_button.connect_clicked(move |_| {
            let mut flow = sign_in.borrow_mut();
            *flow = flow.clone().apply(SignInEvent::Start);
            sign_in_status
                .set_label("Sign-in connecting; certificate session is pending native signer.");
        });
        sign_in_controls.append(&sign_in_button);

        let approval_url = Entry::builder()
            .placeholder_text("Browser approval URL (HTTPS)")
            .hexpand(true)
            .build();
        let approval_fingerprint = Entry::builder()
            .placeholder_text("Approval fingerprint")
            .hexpand(true)
            .build();
        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let url = approval_url.clone();
        let fingerprint = approval_fingerprint.clone();
        let approval_button = Button::with_label(&strings::text(strings::Message::SignInApprove));
        approval_button.connect_clicked(move |_| {
            let mut flow = sign_in.borrow_mut();
            let generation = flow.generation;
            let outcome = WhoamiOutcome::Approval {
                url: url.text().trim().to_owned(),
                fingerprint: fingerprint.text().trim().to_owned(),
            };
            *flow = flow.clone().apply(SignInEvent::Whoami {
                generation,
                outcome,
                at: 0,
            });
            sign_in_status.set_label(if flow.phase == SignInPhase::AwaitingApproval {
                "Approval pending; open the HTTPS link in your browser."
            } else {
                "Approval URL rejected by Rust policy."
            });
        });
        sign_in_controls.append(&approval_button);

        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let open_approval = Button::with_label(&strings::text(strings::Message::SignInOpenBrowser));
        open_approval.connect_clicked(move |_| {
            let flow = sign_in.borrow();
            let Some(approval) = flow.approval.as_ref() else {
                sign_in_status.set_label("No live approval link is available.");
                return;
            };
            if ApprovalInfo::validate(&approval.url, &approval.fingerprint, approval.issued_at)
                .is_err()
            {
                sign_in_status.set_label("Approval URL rejected by Rust policy.");
                return;
            }
            match gio::AppInfo::launch_default_for_uri(
                &approval.url,
                None::<&gio::AppLaunchContext>,
            ) {
                Ok(()) => sign_in_status.set_label("Approval opened in the browser."),
                Err(_) => sign_in_status.set_label("The browser could not open approval."),
            }
        });
        sign_in_controls.append(&open_approval);

        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let session = self.session.clone();
        let sign_out_button = Button::with_label(&strings::text(strings::Message::SignInSignOut));
        sign_out_button.connect_clicked(move |_| {
            session.borrow_mut().clear();
            let mut flow = sign_in.borrow_mut();
            *flow = flow.clone().apply(SignInEvent::SignOut);
            sign_in_status.set_label("Signed out; deployment trust and approval remain pinned.");
        });
        sign_in_controls.append(&sign_out_button);
        root.append(&sign_in_controls);
        root.append(&approval_url);
        root.append(&approval_fingerprint);

        let sign_in = self.sign_in.clone();
        let sign_in_status = content.clone();
        let reconnect = Button::with_label(&strings::text(strings::Message::SignInReconnect));
        reconnect.connect_clicked(move |_| {
            let mut flow = sign_in.borrow_mut();
            let previous = flow.phase;
            *flow = flow.clone().apply(SignInEvent::Start);
            sign_in_status.set_label(if previous == SignInPhase::Disconnected {
                "Reconnect started; a fresh generation must reauthenticate."
            } else {
                "Reconnect requires a disconnected authenticated session."
            });
        });
        root.append(&reconnect);

        // Linux intentionally reports lock capability explicitly. The shared Flutter
        // policy marks Linux as unavailable; keeping this state visible prevents
        // presenting a control that cannot be honored by the native platform.
        let lock_title = strings::text(strings::Message::LockTitle);
        let lock_button = Button::with_label(&lock_title);
        let lock_status = content.clone();
        lock_button.connect_clicked(move |_| {
            let explanation = strings::text(strings::Message::LockExplain);
            let unavailable = strings::text(strings::Message::LockUnavailable);
            lock_status.set_label(&format!("{unavailable}\n{explanation}"));
        });
        root.append(&lock_button);
        let machine_id = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::MachineUuid))
            .hexpand(true)
            .build();
        let request_id = Entry::builder()
            .placeholder_text("Request UUID (for mutations)")
            .hexpand(true)
            .build();
        let actions = Box::new(Orientation::Horizontal, 8);
        for action in ["show", "start", "stop", "pause", "resume"] {
            let button = Button::with_label(action);
            let machine = machine_id.clone();
            let request = request_id.clone();
            let label = content.clone();
            let action = action.to_owned();
            button.connect_clicked(move |_| {
                let request = (!request.text().is_empty()).then(|| request.text().to_string());
                match format_machine_action(&action, machine.text().as_str(), request.as_deref()) {
                    Ok(command) => label.set_label(&format!("Machine command\n{command}")),
                    Err(_) => label.set_label("Machine command rejected by Rust policy."),
                }
            });
            actions.append(&button);
        }
        root.append(&machine_id);
        root.append(&request_id);
        root.append(&actions);
        let share_email = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ShareEmail))
            .hexpand(true)
            .build();
        let share_role = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ShareRole))
            .hexpand(true)
            .build();
        let share_actions = Box::new(Orientation::Horizontal, 8);
        for (label_text, operation) in [
            (strings::text(strings::Message::ShareAdd), "add"),
            (strings::text(strings::Message::ShareRemove), "remove"),
        ] {
            let button = Button::with_label(&label_text);
            let machine = machine_id.clone();
            let email = share_email.clone();
            let role = share_role.clone();
            let status = content.clone();
            button.connect_clicked(move |_| {
                let request = "porsche-0000000000000000000000000000000000000000";
                let selected_role =
                    (!role.text().trim().is_empty()).then(|| role.text().trim().to_owned());
                match format_share_command(
                    operation,
                    machine.text().trim(),
                    email.text().trim(),
                    selected_role.as_deref(),
                    request,
                ) {
                    Ok(command) => status.set_label(&format!("Sharing command\n{command}")),
                    Err(_) => status.set_label("Sharing request rejected by Rust policy."),
                }
            });
            share_actions.append(&button);
        }
        root.append(&share_email);
        root.append(&share_role);
        root.append(&share_actions);
        let share_response = Entry::builder()
            .placeholder_text("share show JSON (paste response)")
            .hexpand(true)
            .build();
        let share_load = Button::with_label(&strings::text(strings::Message::ShareLoad));
        let share_status = content.clone();
        let response_input = share_response.clone();
        share_load.connect_clicked(
            move |_| match mila_native_linux::adapter::decode_share_listing(
                response_input.text().as_bytes(),
            ) {
                Ok((owner, grants)) => share_status
                    .set_label(&format!("Owner: {owner}\n{} share grants", grants.len())),
                Err(_) => share_status.set_label("Sharing listing rejected by Rust policy."),
            },
        );
        root.append(&share_response);
        root.append(&share_load);
        // Terminal controls keep only typed lifecycle state. PTY bytes remain in
        // the transport and never enter GTK labels or application state.
        let terminal = Entry::builder()
            .placeholder_text("Terminal session ID")
            .hexpand(true)
            .build();
        let terminal_input = Entry::builder()
            .placeholder_text("Input length (bytes)")
            .hexpand(true)
            .build();
        let terminal_columns = Entry::builder()
            .placeholder_text("Columns")
            .text("80")
            .hexpand(true)
            .build();
        let terminal_rows = Entry::builder()
            .placeholder_text("Rows")
            .text("24")
            .hexpand(true)
            .build();
        let terminal_actions = Box::new(Orientation::Horizontal, 8);
        let terminal_stream = Rc::new(RefCell::new(TerminalStream::new()));
        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let session_input = terminal.clone();
        let attach = Button::with_label(&strings::text(strings::Message::AttachTerminal));
        attach.connect_clicked(move |_| {
            let session = session_input.text().trim().to_owned();
            if session.is_empty() || session.len() > 128 {
                terminal_status.set_label("Terminal session rejected by Rust policy.");
                return;
            }
            let mut stream = stream.borrow_mut();
            match stream.attach() {
                Ok(generation) => terminal_status.set_label(&format!(
                    "Terminal attaching\nSession {session}\nGeneration {generation}"
                )),
                Err(_) => terminal_status.set_label("Terminal attach unavailable."),
            }
        });
        terminal_actions.append(&attach);

        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let connect = Button::with_label("Connect");
        connect.connect_clicked(move |_| {
            let mut stream = stream.borrow_mut();
            let generation = stream.state().generation();
            let cursor = stream.state().resume_cursor().unwrap_or(0);
            match stream.connected(generation, cursor, true) {
                Ok(()) => terminal_status.set_label(&format!(
                    "Terminal attached\nGeneration {generation}\nRead-write"
                )),
                Err(_) => terminal_status.set_label("Terminal connection rejected."),
            }
        });
        terminal_actions.append(&connect);

        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let reconnect = Button::with_label("Reconnect");
        reconnect.connect_clicked(move |_| {
            let mut stream = stream.borrow_mut();
            match stream.reconnect() {
                Ok(generation) => terminal_status
                    .set_label(&format!("Terminal reconnecting\nGeneration {generation}")),
                Err(_) => terminal_status.set_label("Terminal reconnect unavailable."),
            }
        });
        terminal_actions.append(&reconnect);

        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let input = terminal_input.clone();
        let input_button = Button::with_label("Send input");
        input_button.connect_clicked(move |_| {
            let length = input.text().trim().parse::<usize>().ok();
            let Some(length) = length else {
                terminal_status.set_label("Terminal input length rejected.");
                return;
            };
            match stream.borrow().validate_input(length) {
                Ok(()) => {
                    terminal_status.set_label(&format!("Terminal input accepted ({length} bytes)"))
                }
                Err(_) => terminal_status.set_label("Terminal input rejected by Rust policy."),
            }
        });
        terminal_actions.append(&input_button);

        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let columns = terminal_columns.clone();
        let rows = terminal_rows.clone();
        let resize = Button::with_label("Resize");
        resize.connect_clicked(move |_| {
            let parsed = columns
                .text()
                .trim()
                .parse::<u16>()
                .ok()
                .zip(rows.text().trim().parse::<u16>().ok());
            let Some((columns, rows)) = parsed else {
                terminal_status.set_label("Terminal size rejected.");
                return;
            };
            match stream.borrow().validate_resize(columns, rows) {
                Ok(()) => terminal_status
                    .set_label(&format!("Terminal resize accepted ({columns}x{rows})")),
                Err(_) => terminal_status.set_label("Terminal resize rejected by Rust policy."),
            }
        });
        terminal_actions.append(&resize);

        let terminal_status = content.clone();
        let stream = terminal_stream.clone();
        let kill = Button::with_label("Kill");
        kill.connect_clicked(move |_| {
            let generation = stream.borrow().state().generation();
            match stream.borrow_mut().kill(generation) {
                Ok(()) => {
                    terminal_status.set_label(&format!("Terminal ended\nGeneration {generation}"))
                }
                Err(_) => terminal_status.set_label("Terminal kill rejected."),
            }
        });
        terminal_actions.append(&kill);
        root.append(&terminal);
        root.append(&terminal_input);
        root.append(&terminal_columns);
        root.append(&terminal_rows);
        root.append(&terminal_actions);
        let thread_id = Entry::builder()
            .placeholder_text(&strings::text(strings::Message::ThreadId))
            .hexpand(true)
            .build();
        let thread_actions = Box::new(Orientation::Horizontal, 8);
        for operation in ["ls", "show"] {
            let label = if operation == "ls" {
                strings::text(strings::Message::ThreadList)
            } else {
                strings::text(strings::Message::ThreadShow)
            };
            let button = Button::with_label(&label);
            let input = thread_id.clone();
            let status = content.clone();
            let operation = operation.to_owned();
            button.connect_clicked(move |_| {
                let id = (!input.text().is_empty()).then(|| input.text().to_string());
                match format_thread_command(&operation, id.as_deref()) {
                    Ok(command) => status.set_label(&format!("Thread command\n{command}")),
                    Err(_) => status.set_label("Thread command rejected by Rust policy."),
                }
            });
            thread_actions.append(&button);
        }
        let turns = Button::with_label("Thread turns");
        let turns_input = thread_id.clone();
        let turns_status = content.clone();
        turns.connect_clicked(move |_| {
            match format_thread_turns(turns_input.text().trim(), None) {
                Ok(command) => turns_status.set_label(&format!("Thread turns\n{command}")),
                Err(_) => turns_status.set_label("Thread turns rejected by Rust policy."),
            }
        });
        thread_actions.append(&turns);
        root.append(&thread_id);
        root.append(&thread_actions);
        let web_port = Entry::builder()
            .placeholder_text("Web port (1-65535)")
            .hexpand(true)
            .build();
        let web_request = Entry::builder()
            .placeholder_text("Request UUID (for web changes)")
            .hexpand(true)
            .build();
        let web_actions = Box::new(Orientation::Horizontal, 8);
        for (label_text, operation, public) in [
            (strings::text(strings::Message::WebShow), "show", false),
            (strings::text(strings::Message::WebPublic), "set", true),
            (strings::text(strings::Message::WebPrivate), "set", false),
        ] {
            let button = Button::with_label(&label_text);
            let machine = machine_id.clone();
            let port = web_port.clone();
            let request = web_request.clone();
            let status = content.clone();
            button.connect_clicked(move |_| {
                let parsed_port = (!port.text().is_empty())
                    .then(|| port.text().parse::<u16>().ok())
                    .flatten();
                let request_id = (!request.text().is_empty()).then(|| request.text().to_string());
                match format_web_command(
                    operation,
                    machine.text().as_str(),
                    parsed_port,
                    public,
                    request_id.as_deref(),
                ) {
                    Ok(command) => status.set_label(&format!("Web command\n{command}")),
                    Err(_) => status.set_label("Web request rejected by Rust policy."),
                }
            });
            web_actions.append(&button);
        }
        root.append(&web_port);
        root.append(&web_request);
        root.append(&web_actions);
        let key_id = Entry::builder()
            .placeholder_text("SSH key ID")
            .hexpand(true)
            .build();
        let key_request = Entry::builder()
            .placeholder_text("Request UUID (porsche-…)")
            .hexpand(true)
            .build();
        let revoke = Button::with_label(&strings::text(strings::Message::RevokeKey));
        let key_id_for_action = key_id.clone();
        let key_request_for_action = key_request.clone();
        let label_for_action = content.clone();
        revoke.connect_clicked(move |_| {
            match format_ssh_key_revoke(
                key_id_for_action.text().as_str(),
                key_request_for_action.text().as_str(),
            ) {
                Ok(command) => label_for_action.set_label(&format!("SSH key command\n{command}")),
                Err(_) => label_for_action.set_label("SSH key request rejected by Rust policy."),
            }
        });
        root.append(&key_id);
        root.append(&key_request);
        root.append(&revoke);
        root.append(&content);
        ApplicationWindow::builder()
            .application(app)
            .title("Mila")
            .default_width(720)
            .default_height(420)
            .content(&root)
            .build()
    }
    fn activate(&self, app: &adw::Application) {
        self.ensure_window(app).present();
    }
    fn open(&self, app: &adw::Application, files: &[gio::File]) {
        let window = self.ensure_window(app);
        let uris = files.iter().map(|file| file.uri()).collect::<Vec<_>>();
        let results = parse_activation_uris(uris.iter().map(|uri| uri.as_str()));
        let accepted = results
            .iter()
            .filter_map(|result| result.as_ref().ok())
            .map(|route| route.canonical())
            .collect::<Vec<_>>();
        let rejected = results.len().saturating_sub(accepted.len());
        if accepted.is_empty() {
            self.set_status("Mila\nNo supported link could be opened.");
        } else if rejected == 0 {
            self.set_status(&format!("Mila\nRoutes:\n{}", accepted.join("\n")));
        } else {
            self.set_status(&format!(
                "Mila\nRoutes:\n{}\nRejected links: {rejected}",
                accepted.join("\n")
            ));
        }
        window.present();
    }
    fn set_status(&self, value: &str) {
        if let Some(label) = self.status.borrow().as_ref() {
            label.set_label(value);
        }
    }
}
fn main() -> glib::ExitCode {
    adw::init().expect("GTK/libadwaita initialization failed");
    let css = gtk::CssProvider::new();
    css.load_from_data("* { font-family: JetBrains Mono, monospace; font-size: 14px; } window, box { background: #fff; color: #000; } button, entry { border: 2px solid #000; border-radius: 0; background: #eee; color: #000; } button:hover { background: #000; color: #fff; } @media (prefers-color-scheme: dark) { window, box { background: #000; color: #fff; } button, entry { border-color: #fff; background: #111; color: #fff; } button:hover { background: #fff; color: #000; } } ");
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().expect("display"),
        &css,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    let application = Application::builder()
        .application_id(APPLICATION_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    let state = NativeState::new();
    let a = state.clone();
    application.connect_activate(move |app| a.activate(app));
    let o = state.clone();
    application.connect_open(move |app, files, _| o.open(app, files));
    application.run()
}
