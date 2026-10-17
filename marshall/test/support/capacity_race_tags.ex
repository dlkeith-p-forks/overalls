defmodule Marshall.Compute.CapacityRaceTags do
  @moduledoc "Peer-side connection identity for controlled committed race fixtures."
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Compute.Relocation
  alias Marshall.Compute.CapacityRaceRestorationFailure, as: RestorationFailure
  alias Marshall.Repo

  @type params :: %{vm_id: String.t(), idempotency_key: String.t()}
  @type refusal :: Exception.t() | atom()
  @type clone_result ::
          {:clone, {:ok, map()} | {:error, refusal()}, {:ok, term()} | {:error, term()} | nil}

  # @cc [owner:ghuntley,label:verification;concurrency] tagged-relocation-real-action
  # A tagged relocation MUST invoke the real public action on the checked-out
  # peer connection. The fixture MUST NOT fabricate an admission or retry errors.
  @spec relocate(String.t(), params(), Marshall.Accounts.User.t()) ::
          {:relocate, {:ok, Relocation.t()} | {:error, refusal()}}
  def relocate(tag, params, actor) do
    with_tag(tag, fn ->
      case Marshall.Compute.relocate(params, actor: actor) do
        {:ok, %Relocation{}} = result -> {:relocate, result}
        {:error, error} = result when is_exception(error) or is_atom(error) -> {:relocate, result}
        _ -> raise "unexpected relocation fixture result shape"
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] tagged-clone-activation-boundary
  # A tagged clone MUST retain its real admission result and real coordinator
  # activation result separately. Queue acceptance MUST NOT imply activation.
  @spec clone(String.t(), params(), Marshall.Accounts.User.t()) :: clone_result()
  def clone(tag, params, actor) do
    with_tag(tag, fn ->
      case Marshall.Compute.clone(params, actor: actor) do
        {:ok, %{id: id} = view} when is_binary(id) ->
          unless OverallsProtocol.uuid?(id), do: raise("invalid clone fixture identity")
          {:clone, {:ok, view}, Marshall.Compute.CloneCoordinator.advance(id)}

        {:error, error} = result when is_exception(error) or is_atom(error) ->
          {:clone, result, nil}

        _ ->
          raise "unexpected clone fixture result shape"
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] race-tag-connection-custody
  # A bounded ASCII tag MUST apply only to the operation's checked-out database
  # connection and the prior application_name MUST be restored on success or
  # failure. A cleanup error MUST NOT erase the original action failure.
  @spec with_tag(String.t(), (-> value)) :: value when value: term()
  defp with_tag(tag, operation) do
    unless byte_size(tag) in 1..63 and Regex.match?(~r/\A[a-z0-9_-]+\z/, tag),
      do: raise("invalid capacity race connection tag")

    Repo.checkout(fn ->
      previous =
        case Ecto.Adapters.SQL.query!(Repo, "SELECT current_setting('application_name')", [],
               log: false
             ).rows do
          [[value]] when is_binary(value) -> value
          _ -> raise "invalid prior capacity race connection identity"
        end

      primary =
        capture(fn ->
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT set_config('application_name', $1, false)",
            [tag],
            log: false
          )

          operation.()
        end)

      secondary =
        capture(fn ->
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT set_config('application_name', $1, false)",
            [previous],
            log: false
          )
        end)

      resolve(primary, secondary)
    end)
  end

  @spec capture((-> value)) :: Cleanup.outcome(value) when value: term()
  defp capture(operation) do
    try do
      {:ok, operation.()}
    catch
      kind, reason -> {:raised, {kind, reason, __STACKTRACE__}}
    end
  end

  @spec resolve(Cleanup.outcome(value), Cleanup.outcome(term())) :: value when value: term()
  defp resolve({:ok, value}, {:ok, _}), do: value
  defp resolve({:raised, {kind, reason, stack}}, {:ok, _}), do: :erlang.raise(kind, reason, stack)

  defp resolve({:raised, primary}, {:raised, secondary}),
    do: raise(ExUnit.MultiError, errors: [primary, secondary])

  defp resolve({:ok, value}, {:raised, secondary}),
    do: raise(RestorationFailure, action_result: value, cleanup_failure: secondary)
end
