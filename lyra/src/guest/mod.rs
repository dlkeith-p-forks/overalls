//! Platform-neutral guest agent logic shared by the Linux and Windows agents
//! (ADR-0171): what is read, validated, persisted and replied, kept apart from
//! the operating-system layer in `platform`.

pub mod mmds;
pub mod readiness;
pub mod ssh_login;
pub mod ssh_roster;
pub mod trust;
