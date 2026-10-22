//! Stable message identities for the GTK client.
#[derive(Clone, Copy)]
pub(crate) enum Message {
    AppName,
    Machines,
    Threads,
    Settings,
    Ready,
}
pub(crate) fn text(message: Message) -> &'static str {
    match message {
        Message::AppName => "Mila",
        Message::Machines => "Machines",
        Message::Threads => "Threads",
        Message::Settings => "Settings",
        Message::Ready => "Ready",
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fallback_is_present() {
        assert_eq!(text(Message::AppName), "Mila");
    }
}
