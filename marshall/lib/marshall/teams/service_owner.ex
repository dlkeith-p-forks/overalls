defmodule Marshall.Teams.ServiceOwner do
  @moduledoc """
  The hidden account that owns every SCIM-managed team.

  The row is created once by the `AddScimServiceOwner` migration. It is
  identified by its reserved, unique `deleted.invalid` mailbox together with
  its reserved SCIM external identifier, so neither a provisioned user nor a
  changed external identifier alone can impersonate it. The account never signs
  in; Marshall.Scim.Auth presents it as the SCIM request actor.
  """
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  @email "scim-service-owner@deleted.invalid"
  @external_id "scim-service-owner"

  @doc "Reserved mailbox of the service owner row."
  @spec email() :: String.t()
  def email, do: @email

  @doc "Reserved SCIM external identifier of the service owner row."
  @spec external_id() :: String.t()
  def external_id, do: @external_id

  # @cc [owner:ghuntley,label:security] scim-service-owner-stable-identity
  # The service owner MUST be resolved by both reserved identifiers; a missing
  # or ambiguous row MUST resolve to nil so callers fail closed.
  @doc "The persisted service owner, or nil when the reserved row is missing."
  @spec get() :: User.t() | nil
  def get do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(email == ^@email and scim_external_id == ^@external_id)
    |> Ash.read!(actor: SystemActor.compute())
    |> case do
      [%User{} = owner] -> owner
      _ -> nil
    end
  end

  @doc "The persisted service owner; raises when the reserved row is missing."
  @spec get!() :: User.t()
  def get! do
    case get() do
      %User{} = owner -> owner
      nil -> raise Marshall.Compute.Error, reason: :scim_service_owner_missing
    end
  end

  @doc "The service owner's identifier, or nil when the reserved row is missing."
  @spec id() :: Ash.UUID.t() | nil
  def id do
    case get() do
      %User{id: id} -> id
      nil -> nil
    end
  end

  @doc "Whether `actor` is the persisted service owner."
  @spec actor?(term()) :: boolean()
  def actor?(%User{id: id}) when is_binary(id), do: id == id()
  def actor?(_actor), do: false
end
