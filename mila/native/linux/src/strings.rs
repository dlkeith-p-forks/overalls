//! Stable message identities for the GTK client.

use std::{collections::HashMap, fs, sync::OnceLock};

#[derive(Clone, Copy)]
pub(crate) enum Message {
    AppName,
    Machines,
    Threads,
    Settings,
    Ready,
    LockTitle,
    LockUnavailable,
    LockExplain,
    DeploymentSelect,
    ThreadList,
    ThreadShow,
    SelectDeployment,
    AttachTerminal,
    MachineUuid,
    ThreadId,
    RevokeKey,
    WebShow,
    WebPublic,
    WebPrivate,
    ShareEmail,
    ShareRole,
    ShareAdd,
    ShareRemove,
    ShareLoad,
    Appearance,
    AppearanceSystem,
    AppearanceLight,
    AppearanceDark,
    Locale,
    SaveSettings,
}
pub(crate) fn text(message: Message) -> String {
    let id = match message {
        Message::AppName => "appTitle",
        Message::Machines => "machinesTitle",
        Message::Threads => "tabThreads",
        Message::Settings => "settingsTitle",
        Message::Ready => "ready",
        Message::LockTitle => "lockTitle",
        Message::LockUnavailable => "lockUnavailable",
        Message::LockExplain => "lockExplain",
        Message::DeploymentSelect => "deploymentHostLabel",
        Message::ThreadList => "tabThreads",
        Message::ThreadShow => "threadTitle",
        Message::SelectDeployment => "deploymentAdd",
        Message::AttachTerminal => "terminalAttach",
        Message::MachineUuid => "machineIdLabel",
        Message::ThreadId => "threadIdLabel",
        Message::RevokeKey => "sshRevoke",
        Message::WebShow => "webOpen",
        Message::WebPublic => "webPublic",
        Message::WebPrivate => "webPrivate",
        Message::ShareEmail => "sharingEmail",
        Message::ShareRole => "sharingRole",
        Message::ShareAdd => "sharingAdd",
        Message::ShareRemove => "sharingRemove",
        Message::ShareLoad => "sharingLoad",
        Message::Appearance => "appearance",
        Message::AppearanceSystem => "appearanceSystem",
        Message::AppearanceLight => "appearanceLight",
        Message::AppearanceDark => "appearanceDark",
        Message::Locale => "locale",
        Message::SaveSettings => "settingsSave",
    };
    catalog()
        .get(id)
        .cloned()
        .unwrap_or_else(|| fallback(message).to_owned())
}

fn fallback(message: Message) -> &'static str {
    match message {
        Message::AppName => "Mila",
        Message::Machines => "Machines",
        Message::Threads => "Threads",
        Message::Settings => "Settings",
        Message::Ready => "Ready",
        Message::LockTitle => "App lock",
        Message::LockUnavailable => "App lock is unavailable on Linux.",
        Message::LockExplain => "This device does not provide a native app-lock authenticator.",
        Message::DeploymentSelect => "Deployment host",
        Message::ThreadList => "Threads",
        Message::ThreadShow => "Show thread",
        Message::SelectDeployment => "Select deployment",
        Message::AttachTerminal => "Attach terminal",
        Message::MachineUuid => "Machine UUID",
        Message::ThreadId => "Thread ID",
        Message::RevokeKey => "Revoke SSH key",
        Message::WebShow => "Web show",
        Message::WebPublic => "Web set public",
        Message::WebPrivate => "Web set private",
        Message::ShareEmail => "Share email",
        Message::ShareRole => "Role: viewer, operator, or manager",
        Message::ShareAdd => "Share machine",
        Message::ShareRemove => "Remove share",
        Message::ShareLoad => "Load sharing",
        Message::Appearance => "Appearance",
        Message::AppearanceSystem => "System",
        Message::AppearanceLight => "Light",
        Message::AppearanceDark => "Dark",
        Message::Locale => "Locale",
        Message::SaveSettings => "Save settings",
    }
}

fn catalog() -> &'static HashMap<String, String> {
    static CATALOG: OnceLock<HashMap<String, String>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let root = std::env::var_os("MILA_LOCALE_DIR")
            .map(std::path::PathBuf::from)
            .or_else(|| option_env!("MILA_BUILT_LOCALE_DIR").map(std::path::PathBuf::from));
        let Some(root) = root else {
            return HashMap::new();
        };
        let locale = std::env::var("LANG")
            .unwrap_or_else(|_| "en".to_owned())
            .split('.')
            .next()
            .unwrap_or("en")
            .replace('_', "-");
        for candidate in [locale, "en".into()] {
            let path = root.join(format!("{candidate}.json"));
            let Ok(raw) = fs::read_to_string(path) else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
                continue;
            };
            let Some(messages) = value
                .pointer("/domains/mila/messages")
                .and_then(|v| v.as_array())
            else {
                continue;
            };
            return messages
                .iter()
                .filter_map(|message| {
                    Some((
                        message.get("id")?.as_str()?.to_owned(),
                        message
                            .get("forms")?
                            .as_array()?
                            .first()?
                            .as_str()?
                            .to_owned(),
                    ))
                })
                .collect();
        }
        HashMap::new()
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fallback_is_present() {
        assert_eq!(text(Message::AppName), "Mila");
        assert!(!text(Message::LockUnavailable).is_empty());
    }
}
