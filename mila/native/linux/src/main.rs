use adw::prelude::*;
use adw::{Application, ApplicationWindow};
use gtk::{gio, glib, Align, Box, Button, Entry, Label, Orientation};
use mila_native_linux::adapter::{format_machine_action, format_ssh_key_revoke};
use mila_native_linux::route::ActivationRoute;
use std::{cell::RefCell, rc::Rc};
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
        let title = Label::new(Some("Mila"));
        title.set_halign(Align::Start);
        title.add_css_class("title-1");
        root.append(&title);
        let nav = Box::new(Orientation::Horizontal, 8);
        let content = Label::new(Some("Ready"));
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
