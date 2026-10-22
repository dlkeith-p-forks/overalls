//! Typed, durable deployment selection for the Linux client.
//!
//! Only the validated deployment authority is persisted.  Credentials and session
//! material are deliberately outside this file and are owned by the runtime.

use mila_native_linux::route::ActivationRoute;
use serde::{Deserialize, Serialize};
use std::{fs, io, path::PathBuf};

const FILE_NAME: &str = "deployment.json";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct DeploymentSelection {
    pub(crate) host: String,
}

impl DeploymentSelection {
    pub(crate) fn validate(host: &str) -> Result<Self, PersistenceError> {
        let host = host.trim().to_ascii_lowercase();
        if host.is_empty() || host.len() > 512 || host.contains(['/', '?', '#']) {
            return Err(PersistenceError::InvalidHost);
        }
        let route = format!("overalls://{host}/machines");
        let parsed = ActivationRoute::parse(&route).map_err(|_| PersistenceError::InvalidHost)?;
        let canonical = parsed.canonical();
        let authority = canonical
            .strip_prefix("overalls://")
            .and_then(|value| value.strip_suffix("/machines"))
            .ok_or(PersistenceError::InvalidHost)?;
        Ok(Self {
            host: authority.to_owned(),
        })
    }

    pub(crate) fn route(&self) -> String {
        format!("overalls://{}/machines", self.host)
    }
}

#[derive(Debug)]
pub(crate) enum PersistenceError {
    InvalidHost,
    Io(io::Error),
    InvalidData,
}

impl From<io::Error> for PersistenceError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

fn path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("MILA_DEPLOYMENT_PATH") {
        return Some(PathBuf::from(path));
    }
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(root.join("mila").join(FILE_NAME))
}

pub(crate) fn load() -> Result<Option<DeploymentSelection>, PersistenceError> {
    let Some(path) = path() else { return Ok(None) };
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let selection: DeploymentSelection =
        serde_json::from_slice(&bytes).map_err(|_| PersistenceError::InvalidData)?;
    DeploymentSelection::validate(&selection.host).map(Some)
}

pub(crate) fn save(selection: &DeploymentSelection) -> Result<(), PersistenceError> {
    let selection = DeploymentSelection::validate(&selection.host)?;
    let Some(path) = path() else {
        return Err(PersistenceError::Io(io::Error::new(
            io::ErrorKind::NotFound,
            "configuration directory unavailable",
        )));
    };
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid configuration path"))?;
    fs::create_dir_all(parent)?;
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(&selection).map_err(|_| PersistenceError::InvalidData)?;
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_canonicalizes_host() {
        assert_eq!(
            DeploymentSelection::validate("Example.COM:443")
                .unwrap()
                .host,
            "example.com:443"
        );
        assert!(DeploymentSelection::validate("https://example.com").is_err());
        assert!(DeploymentSelection::validate("example.com/").is_err());
        assert!(DeploymentSelection::validate("example.com:0").is_err());
    }

    #[test]
    fn route_is_navigation_only() {
        let selection = DeploymentSelection::validate("example.com:443").unwrap();
        assert_eq!(selection.route(), "overalls://example.com:443/machines");
    }
}
