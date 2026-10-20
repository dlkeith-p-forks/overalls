use adw::prelude::*;
use gtk::{gio, glib, Label};
use std::{cell::RefCell, rc::Rc};

use adw::{Application, ApplicationWindow};
use mila_native_linux::route::ActivationRoute;

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
        let label = Label::builder()
            .label("Mila native Linux scaffold\nReady for an overalls:// link")
            .wrap(true)
            .selectable(false)
            .margin_top(32)
            .margin_bottom(32)
            .margin_start(32)
            .margin_end(32)
            .build();
        let window = ApplicationWindow::builder()
            .application(app)
            .title("Mila")
            .default_width(720)
            .default_height(420)
            .content(&label)
            .build();
        *self.status.borrow_mut() = Some(label);
        window
    }

    fn activate(&self, app: &adw::Application) {
        let window = self.ensure_window(app);
        window.present();
    }

    fn open(&self, app: &adw::Application, files: &[gio::File]) {
        let window = self.ensure_window(app);
        let Some(file) = files.first() else {
            self.set_status("Mila native Linux scaffold\nReady for an overalls:// link");
            window.present();
            return;
        };
        let uri = file.uri();
        match ActivationRoute::parse(uri.as_str()) {
            Ok(route) => {
                self.set_status(&format!("Mila\nRoute: {}", route.canonical()));
            }
            Err(_) => self.set_status("Mila\nThe link could not be opened."),
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
        // GApplication forwards subsequent URI launches to this process.
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    let state = NativeState::new();
    let activated_state = state.clone();
    application.connect_activate(move |app| activated_state.activate(app));
    let opened_state = state.clone();
    application.connect_open(move |app, files, _hint| opened_state.open(app, files));
    application.run()
}
