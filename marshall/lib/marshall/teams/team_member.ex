# @cc [owner:ghuntley,label:security] team-one-current-membership
# Each team/member pair MUST have at most one unarchived membership and a
# team MUST have exactly one unarchived owner. Role replacement MUST retain
# audited history rather than overwrite membership evidence.
defmodule Marshall.Teams.TeamMember do
  @moduledoc "One current role per team/member; replacement retains audited history."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Teams,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "team_members"
    repo Marshall.Repo

    identity_wheres_to_sql current_member: "archived_at IS NULL",
                           one_owner: "archived_at IS NULL AND role = 'owner'"
  end

  archive do
    exclude_read_actions([:history])
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
  end

  actions do
    defaults [:read]
    read :history

    create :record do
      accept [:team_id, :user_id, :role, :recorded_by_id]
    end

    update :replace_role do
      accept [:role, :recorded_by_id]
    end

    destroy :remove
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:replace_role, :remove])]
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:owner, :admin, :member]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :team, Marshall.Teams.Team, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :recorded_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :current_member, [:team_id, :user_id], where: expr(is_nil(archived_at))
    identity :one_owner, [:team_id], where: expr(is_nil(archived_at) and role == :owner)
  end
end
