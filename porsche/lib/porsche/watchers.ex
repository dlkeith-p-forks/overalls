defmodule Porsche.Watchers do
  @moduledoc """
  Routes Marshall control hints to the SSH `watch` channels that asked for
  them (ADR-0222).

  A hint names only a kind and an identifier. Channels register the canonical
  identifiers Marshall authorized for their subscription; a hint is a prompt
  to re-read through ordinary authorized commands, never authority itself.
  """

  @kinds ~w(vm thread terminal_session ssh_session)

  @type kind :: String.t()
  @type key :: {kind(), String.t()} | :resync

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc "The hint kinds a watcher may register for."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # @cc [owner:ghuntley,label:security;protocol] porsche-watch-hint-routing
  # Hints MUST reach only channels registered for that exact kind and id, and
  # resync MUST reach every watcher. Unknown kinds are dropped. Routing carries
  # no payload beyond the hint's kind and identifier.
  @doc "Registers the calling process for each key, replacing earlier keys."
  @spec watch([key()]) :: :ok
  def watch(keys) when is_list(keys) do
    unwatch()

    keys
    |> Enum.uniq()
    |> Enum.each(fn key -> {:ok, _} = Registry.register(__MODULE__, key, nil) end)
  end

  @doc "Removes every registration of the calling process."
  @spec unwatch() :: :ok
  def unwatch do
    __MODULE__
    |> Registry.keys(self())
    |> Enum.each(&Registry.unregister(__MODULE__, &1))
  end

  @doc "Delivers `{:watch_hint, kind, id}` to the channels watching that id."
  @spec hint(term(), term()) :: :ok
  def hint(kind, id) when kind in @kinds and is_binary(id) do
    Registry.dispatch(__MODULE__, {kind, id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:watch_hint, kind, id})
    end)
  end

  def hint(_kind, _id), do: :ok

  @doc "Tells every watcher that hints may have been lost."
  @spec resync() :: :ok
  def resync do
    Registry.dispatch(__MODULE__, :resync, fn entries ->
      for {pid, _} <- entries, do: send(pid, :watch_resync)
    end)
  end
end
