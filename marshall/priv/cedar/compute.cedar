permit(principal is Marshall::User, action == Marshall::Action::"admin_read",
       resource == Marshall::ControlPlane::"marshall");

permit(principal is Marshall::User, action == Marshall::Action::"provision",
       resource == Marshall::ControlPlane::"marshall");

permit(principal is Marshall::User,
       action in [Marshall::Action::"admin_accounts",
                  Marshall::Action::"admin_operate", Marshall::Action::"admin_configure",
                  Marshall::Action::"admin_jobs"],
       resource == Marshall::ControlPlane::"marshall")
when { principal.administrator && principal.elevated };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage", Marshall::Action::"web"],
       resource is Marshall::VM)
when { principal.administrator && principal.elevated };

permit(principal == Marshall::System::"compute",
       action == Marshall::Action::"coordinate", resource is Marshall::Internal);

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write", Marshall::Action::"manage"],
       resource is Marshall::VM)
when { resource.owner == principal || resource.managers.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::VM)
when { resource.operators.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"read",
       resource is Marshall::VM)
when { resource.viewers.contains(principal) };

// Thread roles survive machine generations; machine-only grants do not reveal threads.
permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::Thread)
when { resource.owner == principal || resource.managers.contains(principal) ||
       resource.team_admins.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::Thread)
when { resource.operators.contains(principal) || resource.team_members.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"read",
       resource is Marshall::Thread)
when { resource.viewers.contains(principal) };

// Team authority: admins manage team machines; current members may read and use them.
// Team use includes private guest web; web-only grants retain their separate scope.
permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write",
                  Marshall::Action::"manage"],
       resource is Marshall::VM)
when { resource.team_admins.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"read", Marshall::Action::"write"],
       resource is Marshall::VM)
when { resource.team_members.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"team_read", Marshall::Action::"team_manage_members",
                  Marshall::Action::"team_transfer"],
       resource is Marshall::Team)
when { resource.owner == principal || resource.admins.contains(principal) };

permit(principal is Marshall::User, action == Marshall::Action::"team_read",
       resource is Marshall::Team)
when { resource.members.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"integration_read", Marshall::Action::"integration_manage"],
       resource is Marshall::Integration)
when { principal.administrator && principal.elevated };

permit(principal is Marshall::User,
       action in [Marshall::Action::"integration_read", Marshall::Action::"integration_manage"],
       resource is Marshall::Integration)
when { resource.owner == principal || resource.managers.contains(principal) };

// Web-only sharing never implies VM metadata, terminal or SSH access.
permit(principal is Marshall::User, action == Marshall::Action::"web",
       resource is Marshall::VM)
when { resource.owner == principal || resource.managers.contains(principal) ||
       resource.operators.contains(principal) || resource.viewers.contains(principal) ||
       resource.web_users.contains(principal) || resource.team_admins.contains(principal) ||
       resource.team_members.contains(principal) };

// Artifacts: the immutable owner and co-owners hold every role; writers publish
// and use all storage; viewers read, keep personal storage and read shared
// storage. Every content action requires an active artifact.
permit(principal is Marshall::User, action == Marshall::Action::"artifact_create",
       resource is Marshall::ControlPlane);

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read", Marshall::Action::"artifact_publish",
                  Marshall::Action::"artifact_share", Marshall::Action::"artifact_delete",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read",
                  Marshall::Action::"artifact_storage_shared_write"],
       resource is Marshall::Artifact)
when { resource.active && (resource.owner == principal || resource.owners.contains(principal)) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read", Marshall::Action::"artifact_publish",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read",
                  Marshall::Action::"artifact_storage_shared_write"],
       resource is Marshall::Artifact)
when { resource.active && resource.writers.contains(principal) };

permit(principal is Marshall::User,
       action in [Marshall::Action::"artifact_read",
                  Marshall::Action::"artifact_storage_personal",
                  Marshall::Action::"artifact_storage_shared_read"],
       resource is Marshall::Artifact)
when { resource.active && resource.viewers.contains(principal) };

// Moderation: elevated administrators may delete any active artifact. They are
// not granted content, storage or sharing access by this rule.
permit(principal is Marshall::User, action == Marshall::Action::"artifact_admin_delete",
       resource is Marshall::Artifact)
when { resource.active && principal.administrator && principal.elevated };
