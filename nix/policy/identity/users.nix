# @cc [owner:ghuntley,label:security] reviewed-fleet-user-inputs
# Fleet identities MUST contain reviewed public keys only; login, administration
# and recovery grants MUST be explicit. Private identities MUST remain external.
{
  ghuntley = {
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFiX7qvQS3QjzL8y31KxMPn5EOyufjgz2YuRD3GNWcuR"
    ];
    login = true;
    group = "users";
    extraGroups = [];
    admin = true;
    secretRecovery = true;
  };
}
