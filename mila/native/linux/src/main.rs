use adw::prelude::*;
use adw::{Application, ApplicationWindow};
use gtk::{gio, glib, Align, Box, Button, Entry, Label, Orientation};
use mila_native_linux::adapter::{
    format_machine_action, format_ssh_key_revoke, format_thread_command, format_web_command,
    validate_terminal_operation, TerminalOperation,
};
use mila_native_linux::route::ActivationRoute;
use std::{cell::RefCell, rc::Rc};
mod strings;
const APPLICATION_ID: &str = "dev.overalls.Mila.Linux";
#[derive(Clone)]
struct NativeState {
    status: Rc<RefCell<Option<Label>>>,
}
impl NativeState {
    fn new() -> Self {
        Self {
            status: Rc::new(RefCell::new(None)),
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

        let deployment = Entry::builder()
            .placeholder_text("Deployment host (example: overalls.example:443)")
            .hexpand(true)
            .build();
        let select = Button::with_label("Select deployment");
        let deployment_status = content.clone();
        let deployment_input = deployment.clone();
        select.connect_clicked(move |_| {
            let host = deployment_input.text().trim().to_owned();
            let route = format!("overalls://{host}/machines");
            match ActivationRoute::parse(&route) {
                Ok(parsed) => deployment_status
                    .set_label(&format!("Deployment selected\n{}", parsed.canonical())),
                Err(_) => deployment_status.set_label("Deployment host rejected by Rust policy."),
            }
        });
        root.append(&deployment);
        root.append(&select);

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
            .placeholder_text("Machine UUID")
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
        let terminal = Entry::builder()
            .placeholder_text("Terminal session ID")
            .hexpand(true)
            .build();
        let attach = Button::with_label("Attach terminal");
        let terminal_status = content.clone();
        let terminal_input = terminal.clone();
        attach.connect_clicked(move |_| {
            let session_value = terminal_input.text();
            let session = session_value.trim();
            if session.is_empty() || session.len() > 128 {
                terminal_status.set_label("Terminal session rejected by Rust policy.");
                return;
            }
            match validate_terminal_operation(TerminalOperation::Attach {
                from: 0,
                columns: 80,
                rows: 24,
                read_write: true,
            }) {
                Ok(()) => {
                    terminal_status.set_label(&format!("Terminal attached\nSession {session}"))
                }
                Err(_) => terminal_status.set_label("Terminal attach rejected by Rust policy."),
            }
        });
        root.append(&terminal);
        root.append(&attach);
        let thread_id = Entry::builder()
            .placeholder_text("Thread ID (optional for list)")
            .hexpand(true)
            .build();
        let thread_actions = Box::new(Orientation::Horizontal, 8);
        for operation in ["ls", "show"] {
            let button = Button::with_label(&format!("Thread {operation}"));
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
            ("Web show", "show", false),
            ("Web set public", "set", true),
            ("Web set private", "set", false),
        ] {
            let button = Button::with_label(label_text);
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
        let revoke = Button::with_label("Revoke SSH key");
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
        if let Some(file) = files.first() {
            let uri = file.uri();
            match ActivationRoute::parse(uri.as_str()) {
                Ok(route) => self.set_status(&format!("Mila\nRoute: {}", route.canonical())),
                Err(_) => self.set_status("Mila\nThe link could not be opened."),
            }
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
