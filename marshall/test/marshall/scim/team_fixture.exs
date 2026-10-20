defmodule Marshall.Scim.TeamFixture do
  @moduledoc """
  Shared SCIM team fixtures. Configuration goes through the production
  administrator action and requests through the real `/scim/v2` endpoint.
  """
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  alias Marshall.Compute.Ledger

  @endpoint MarshallWeb.Endpoint

  @type scim_response :: {pos_integer(), map() | nil}

  @doc "An elevated administrator able to change the SCIM configuration."
  @spec admin() :: Marshall.Accounts.User.t()
  def admin do
    Marshall.ComputeFixtures.user()
    |> Ledger.update!(:assign_administrator, %{administrator: true})
    |> Marshall.PasskeyFixture.verified_session()
  end

  @doc "Enable SCIM through the administrator `:enable` operation and return the bearer token."
  @spec enable!(Marshall.Accounts.User.t()) :: String.t()
  def enable!(admin \\ admin()) do
    assert {:ok, %{enabled: true, token: token}} = configure(admin, %{operation: :enable})
    assert is_binary(token)
    token
  end

  @doc "Disable SCIM through the administrator `:disable` operation."
  @spec disable!(Marshall.Accounts.User.t()) :: :ok
  def disable!(admin \\ admin()) do
    assert {:ok, %{enabled: false}} = configure(admin, %{operation: :disable})
    refute Marshall.Scim.enabled?()
    :ok
  end

  @spec configure(Marshall.Accounts.User.t(), map()) :: {:ok, map()} | {:error, term()}
  defp configure(admin, arguments) do
    Marshall.Scim.Configuration
    |> Ash.ActionInput.for_action(:configure, arguments, actor: admin)
    |> Ash.run_action()
  end

  @doc "Send one SCIM request and decode its JSON body."
  @spec request(String.t(), atom(), String.t(), map() | nil) :: scim_response()
  def request(token, method, path, body \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/scim+json")
      |> put_req_header("accept", "application/scim+json")

    conn = dispatch(conn, @endpoint, method, "/scim/v2" <> path, body && Jason.encode!(body))

    decoded =
      case conn.resp_body do
        "" -> nil
        body -> Jason.decode!(body)
      end

    {conn.status, decoded}
  end

  @doc "A SCIM Group body."
  @spec group(String.t(), [Ash.UUID.t()], String.t() | nil) :: map()
  def group(name, member_ids, external_id \\ nil) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "displayName" => name,
      "externalId" => external_id || Ash.UUID.generate(),
      "members" => Enum.map(member_ids, &%{"value" => &1})
    }
  end

  @doc "A SCIM PatchOp body."
  @spec patch([map()]) :: map()
  def patch(operations) do
    %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => operations
    }
  end

  @doc "Current (unarchived) memberships of a team as {user_id, role} pairs."
  @spec memberships(Ash.UUID.t()) :: [{Ash.UUID.t(), atom()}]
  def memberships(team_id) do
    Marshall.Teams.TeamMember
    |> Ledger.read!(team_id: team_id)
    |> Enum.map(&{&1.user_id, &1.role})
    |> Enum.sort()
  end

  @doc "A unique valid team name."
  @spec team_name() :: String.t()
  def team_name, do: "scim-" <> (Ash.UUID.generate() |> binary_part(0, 8))
end
