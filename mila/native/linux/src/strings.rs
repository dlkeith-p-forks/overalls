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
    ThreadPrompt,
    ThreadAnswer,
    ThreadPlanApprove,
    ThreadPlanRevise,
    SelectDeployment,
    ReloadDeployment,
    ForgetDeployment,
    DeploymentForgotten,
    DeploymentForgetFailed,
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
    SignInStart,
    SignInDeploymentRequired,
    SignInConnecting,
    SignInApprove,
    SignInOpenBrowser,
    SignInSignOut,
    SignInReconnect,
    NotificationsTitle,
    NotificationsExplain,
    PushUnsupported,
    NotificationDevices,
    NotificationDeviceId,
    NotificationRefresh,
    NotificationRemove,
    NotificationEnable,
    NotificationDisable,
    NotificationRequireSignIn,
    NotificationAccepted,
    NotificationRejected,
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
        Message::ThreadPrompt => "threadPrompt",
        Message::ThreadAnswer => "threadAnswer",
        Message::ThreadPlanApprove => "threadPlanApprove",
        Message::ThreadPlanRevise => "threadPlanRevise",
        Message::SelectDeployment => "deploymentAdd",
        Message::ReloadDeployment => "deploymentReload",
        Message::ForgetDeployment => "deploymentForget",
        Message::DeploymentForgotten => "deploymentForgotten",
        Message::DeploymentForgetFailed => "deploymentForgetFailed",
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
        Message::SignInStart => "signInStart",
        Message::SignInDeploymentRequired => "signInDeploymentRequired",
        Message::SignInConnecting => "signInConnecting",
        Message::SignInApprove => "signInApprove",
        Message::SignInOpenBrowser => "signInOpenBrowser",
        Message::SignInSignOut => "signInSignOut",
        Message::SignInReconnect => "signInReconnect",
        Message::NotificationsTitle => "notificationsTitle",
        Message::NotificationsExplain => "notificationsExplain",
        Message::PushUnsupported => "pushUnsupported",
        Message::NotificationDevices => "notificationDevices",
        Message::NotificationDeviceId => "notificationDeviceId",
        Message::NotificationRefresh => "notificationRefresh",
        Message::NotificationRemove => "notificationRemove",
        Message::NotificationEnable => "notificationEnable",
        Message::NotificationDisable => "notificationDisable",
        Message::NotificationRequireSignIn => "notificationRequireSignIn",
        Message::NotificationAccepted => "notificationAccepted",
        Message::NotificationRejected => "notificationRejected",
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
        Message::ThreadPrompt => "Prompt",
        Message::ThreadAnswer => "Answer",
        Message::ThreadPlanApprove => "Approve plan",
        Message::ThreadPlanRevise => "Revise plan",
        Message::SelectDeployment => "Select deployment",
        Message::ReloadDeployment => "Reload deployment",
        Message::ForgetDeployment => "Forget deployment",
        Message::DeploymentForgotten => "Deployment forgotten.",
        Message::DeploymentForgetFailed => "Deployment could not be forgotten.",
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
        Message::SignInStart => "Sign in with browser",
        Message::SignInDeploymentRequired => "Select a deployment before signing in.",
        Message::SignInConnecting => {
            "Sign-in connecting; certificate session is pending native transport."
        }
        Message::SignInApprove => "Await approval",
        Message::SignInOpenBrowser => "Open approval page",
        Message::SignInSignOut => "Sign out",
        Message::SignInReconnect => "Reconnect",
        Message::NotificationsTitle => "Notifications",
        Message::NotificationsExplain => "Notifications are unavailable on Linux.",
        Message::PushUnsupported => "Notifications are not available on this platform.",
        Message::NotificationDevices => "Notification devices",
        Message::NotificationDeviceId => "Device ID",
        Message::NotificationRefresh => "Refresh devices",
        Message::NotificationRemove => "Remove device",
        Message::NotificationEnable => "Enable device",
        Message::NotificationDisable => "Disable device",
        Message::NotificationRequireSignIn => "Notification device controls require sign-in.",
        Message::NotificationAccepted => "Notification device request accepted.",
        Message::NotificationRejected => "Notification device request rejected.",
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
