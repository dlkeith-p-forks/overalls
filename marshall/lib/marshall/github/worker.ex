defmodule Marshall.GitHub.Worker do
  @moduledoc "ID-only rotation/revocation jobs plus minute-based durable rediscovery."
  use Oban.Worker,
    queue: :github,
    max_attempts: 8,
    unique: [
      period: 30,
      keys: [:id, :op, :generation],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, :unavailable}
  def perform(%Oban.Job{args: %{"id" => id, "op" => "refresh"}}) when is_binary(id),
    do: Marshall.GitHub.refresh_connection(id)

  def perform(%Oban.Job{args: %{"id" => id, "op" => "revoke"}}) when is_binary(id),
    do: Marshall.GitHub.revoke_connection(id)

  def perform(%Oban.Job{args: %{"id" => id, "op" => "cleanup"}}) when is_binary(id),
    do: Marshall.GitHub.cleanup_authorization(id)

  def perform(%Oban.Job{args: %{"id" => id, "op" => "cleanup_refresh"}}) when is_binary(id),
    do: Marshall.GitHub.cleanup_refresh(id)

  def perform(%Oban.Job{args: args}) when args in [%{}, %{"op" => "reconcile"}],
    do: Marshall.GitHub.reconcile()

  def perform(_), do: :ok
end
