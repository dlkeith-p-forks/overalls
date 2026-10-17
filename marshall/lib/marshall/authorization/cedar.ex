defmodule Marshall.Authorization.Cedar do
  @moduledoc "Cedar policy compilation at startup and fail-closed request evaluation."
  use GenServer

  alias ExCedar.{
    Authorizer,
    Decision,
    Entities,
    Entity,
    EntityUid,
    PolicySet,
    Request,
    Schema,
    Validator
  }

  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # @cc [owner:ghuntley,label:security] cedar-startup-validation
  # Startup MUST require policy/schema compilation and successful Cedar schema
  # validation before publishing authorization state; invalid policy files MUST
  # prevent this server from starting.
  @impl true
  def init(_opts) do
    directory = Application.app_dir(:marshall, "priv/cedar")

    with {:ok, schema} <- Schema.compile(File.read!(Path.join(directory, "schema.cedarschema"))),
         {:ok, policies} <- PolicySet.compile(File.read!(Path.join(directory, "compute.cedar"))),
         {:ok, %{validated?: true, errors: []}} <- Validator.validate(policies, schema) do
      :persistent_term.put(__MODULE__, {policies, schema})
      {:ok, nil}
    else
      _ -> {:stop, :invalid_cedar_policies}
    end
  end

  # @cc [owner:ghuntley,label:security] cedar-error-free-allow-only
  # Authorization MUST return true only for a recognized typed principal and an
  # explicit Cedar allow with no evaluation errors. Missing policy state,
  # incomplete entities, invalid principals and error-bearing decisions MUST deny.
  @spec allowed?(term(), String.t(), Entity.t()) :: boolean()
  def allowed?(actor, action, %Entity{} = resource) do
    with %EntityUid{} = principal <- principal(actor),
         {policies, schema} <- :persistent_term.get(__MODULE__, nil),
         {:ok, principal_entity} <- principal_entity(actor, principal),
         {:ok, entities} <- Entities.from_list([principal_entity, resource]) do
      case Authorizer.authorize(
             policies,
             entities,
             %Request{
               principal: principal,
               action: uid("Action", action),
               resource: resource.uid,
               context: %{}
             },
             schema: schema
           ) do
        {:ok, %Decision{decision: :allow, errors: []}} -> true
        {:ok, %Decision{errors: []}} -> false
        {:ok, %Decision{}} -> evaluation_error(:decision_errors)
        {:error, _} -> evaluation_error(:evaluation_failed)
      end
    else
      _ -> false
    end
  end

  defp evaluation_error(reason) do
    Marshall.Events.emit("cedar.evaluation_error", reason: reason)
    false
  end

  @spec entity(String.t(), String.t(), map()) :: Entity.t()
  def entity(type, id, attributes \\ %{}), do: %Entity{uid: uid(type, id), attributes: attributes}

  @spec vm(String.t(), String.t(), map()) :: Entity.t()
  def vm(id, owner_id, grants \\ %{}) do
    entity("VM", id, %{
      "owner" => uid("User", owner_id),
      "web_users" => Enum.map(Map.get(grants, :web, []), &uid("User", &1)),
      "viewers" => Enum.map(Map.get(grants, :viewer, []), &uid("User", &1)),
      "operators" => Enum.map(Map.get(grants, :operator, []), &uid("User", &1)),
      "managers" => Enum.map(Map.get(grants, :manager, []), &uid("User", &1)),
      "team_admins" => Enum.map(Map.get(grants, :team_admins, []), &uid("User", &1)),
      "team_members" => Enum.map(Map.get(grants, :team_members, []), &uid("User", &1))
    })
  end

  @spec thread(String.t(), String.t(), map()) :: Entity.t()
  def thread(id, creator_id, grants \\ %{}) do
    entity("Thread", id, %{
      "owner" => uid("User", creator_id),
      "viewers" => Enum.map(Map.get(grants, :viewer, []), &uid("User", &1)),
      "operators" => Enum.map(Map.get(grants, :operator, []), &uid("User", &1)),
      "managers" => Enum.map(Map.get(grants, :manager, []), &uid("User", &1)),
      "team_admins" => Enum.map(Map.get(grants, :team_admins, []), &uid("User", &1)),
      "team_members" => Enum.map(Map.get(grants, :team_members, []), &uid("User", &1))
    })
  end

  # @cc [owner:ghuntley,label:security] cedar-team-fresh-membership
  # Team entities MUST be constructed from current unarchived memberships on
  # every decision; owners are a single user and admins include the owner so
  # ownership changes take effect on the next evaluation.
  @spec team(Marshall.Teams.Team.t()) :: Entity.t()
  def team(team) do
    roles = Marshall.Teams.Coordinator.roles(team.id)

    entity("Team", team.id, %{
      "owner" => uid("User", roles.owner || ""),
      "admins" => Enum.map(roles.admins, &uid("User", &1)),
      "members" => Enum.map(roles.members, &uid("User", &1))
    })
  end

  # @cc [owner:ghuntley,label:security] cedar-integration-fresh-managers
  # Integration entities MUST derive managers from the owning team's current
  # owner and admins, or from the user owner alone. Stored secrets never
  # influence authorization.
  @spec integration(Marshall.Galileo.Integration.t()) :: Entity.t()
  def integration(integration) do
    managers =
      if is_binary(integration.team_id) do
        Marshall.Teams.Coordinator.roles(integration.team_id).admins
      else
        []
      end

    entity("Integration", integration.id, %{
      "owner" => uid("User", integration.owner_id || ""),
      "managers" => Enum.map(managers, &uid("User", &1))
    })
  end

  defp principal(%User{id: id}) when is_binary(id), do: uid("User", id)
  defp principal(%SystemActor{purpose: :compute}), do: uid("System", "compute")
  defp principal(_), do: nil

  # @cc [owner:ghuntley,label:security] cedar-current-administrator
  # User administrator authority MUST come from the persisted account on each
  # decision, never the caller's struct, session claims or a permission cache.
  # Missing users MUST deny; the system principal remains a separate entity type.
  defp principal_entity(%User{id: id} = actor, principal) do
    query =
      User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id == ^id)

    case Ash.read_one(query) do
      {:ok, %User{administrator: administrator, deleted_at: nil}} ->
        login_jti = Marshall.Accounts.Security.jti(actor)

        if is_nil(login_jti) or match?({:ok, _}, Marshall.Accounts.Login.present(login_jti, id)) do
          {:ok,
           %Entity{
             uid: principal,
             attributes: %{
               "administrator" => administrator,
               "elevated" => Marshall.Accounts.Security.recent?(actor)
             }
           }}
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unknown_principal}
    end
  end

  defp principal_entity(%SystemActor{}, principal), do: {:ok, %Entity{uid: principal}}
  defp uid(type, id), do: EntityUid.new("Marshall::" <> type, id)
end
