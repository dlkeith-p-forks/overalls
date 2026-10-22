//! Linux notification capability reporting.
//!
//! Mila's platform profile does not currently provide a Linux push provider.
//! Keep that absence explicit at the native boundary so the UI cannot claim
//! registration succeeded or retain a misleading enabled state.

/// Why notification delivery is unavailable on this platform.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationUnavailable {
    NoPushProvider,
}

/// Capability exposed by the platform profile.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NotificationCapability {
    Unsupported(NotificationUnavailable),
}

/// Native notification state owned by the Linux presentation host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct NotificationState {
    capability: NotificationCapability,
    enabled: bool,
}

impl NotificationState {
    /// Constructs the Linux capability from the platform profile.
    pub const fn linux() -> Self {
        Self {
            capability: NotificationCapability::Unsupported(
                NotificationUnavailable::NoPushProvider,
            ),
            enabled: false,
        }
    }

    pub const fn capability(&self) -> NotificationCapability {
        self.capability
    }

    pub const fn enabled(&self) -> bool {
        self.enabled
    }

    /// @cc [owner:ghuntley,label:security;desktop] linux-notifications-no-provider
    /// Linux MUST refuse notification enablement while no push provider exists;
    /// the native state MUST remain disabled after every refusal.
    pub fn enable(&mut self) -> Result<(), NotificationUnavailable> {
        match self.capability {
            NotificationCapability::Unsupported(reason) => {
                self.enabled = false;
                Err(reason)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{NotificationCapability, NotificationState, NotificationUnavailable};

    #[test]
    fn linux_reports_unsupported_without_enabling() {
        let mut state = NotificationState::linux();
        assert_eq!(
            state.capability(),
            NotificationCapability::Unsupported(NotificationUnavailable::NoPushProvider)
        );
        assert!(!state.enabled());
        assert_eq!(state.enable(), Err(NotificationUnavailable::NoPushProvider));
        assert!(!state.enabled());
    }
}
