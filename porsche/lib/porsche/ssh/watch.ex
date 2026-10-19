defmodule Porsche.SSH.Watch do
  @moduledoc """
  State and JSON lines for one exec-channel `watch` stream (ADR-0222).

  A watch subscribes through Marshall's `watch_subscribe` route, which names
  the canonical machine and thread identifiers the session may read. The
  channel registers those identifiers with `Porsche.Watchers`, coalesces
  hints for a short debounce window and writes one change notice per
  identifier. Notices carry only identifiers: clients re-read through the
  ordinary authorized commands. Every heartbeat repeats the subscription, so
  revoked authority ends the stream within one interval.
  """

  @enforce_keys [:machines, :threads, :session]
  defstruct [
    :machines,
    :threads,
    :session,
    session_id: nil,
    phase: :starting,
    subscribed: %{machines: [], threads: []},
    pending: MapSet.new(),
    flush: nil,
    heartbeat: nil
  ]

  @type phase :: :starting | :awaiting_approval | :watching
  @type t :: %__MODULE__{
          machines: [String.t()],
          threads: [String.t()],
          session: boolean(),
          session_id: String.t() | nil,
          phase: phase(),
          subscribed: %{machines: [String.t()], threads: [String.t()]},
          pending: MapSet.t({String.t(), String.t()}),
          flush: reference() | nil,
          heartbeat: reference() | nil
        }
  @type subscription :: %{session_id: String.t(), machines: [String.t()], threads: [String.t()]}

  @spec new(OverallsProtocol.SSHCommand.t()) :: t()
  def new(%{command: "watch", options: options}) do
    %__MODULE__{
      machines: list(options["machine"]),
      threads: list(options["thread"]),
      session: options["session"] == true
    }
  end

  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms, do: Application.get_env(:porsche, :watch_heartbeat_ms, 15_000)

  @spec debounce_ms() :: non_neg_integer()
  def debounce_ms, do: Application.get_env(:porsche, :watch_debounce_ms, 250)

  @doc "The closed `watch_subscribe` request for this watch."
  @spec request(t(), String.t()) :: map()
  def request(watch, session_token),
    do: %{
      "version" => 1,
      "session_token" => session_token,
      "machines" => watch.machines,
      "threads" => watch.threads
    }

  # @cc [owner:ghuntley,label:security;protocol] porsche-watch-subscription-shape
  # A subscription answer MUST be an exact map of a session UUID and at most
  # the requested number of machine and thread UUIDs; anything else is an
  # invalid response and never registers a watcher.
  @spec subscription(t(), term()) :: {:ok, subscription()} | {:error, :invalid_response}
  def subscription(
        watch,
        %{"session_id" => session, "machines" => machines, "threads" => threads} = result
      )
      when map_size(result) == 3 and is_list(machines) and is_list(threads) do
    if OverallsProtocol.uuid?(session) and length(machines) == length(watch.machines) and
         length(threads) == length(watch.threads) and
         Enum.all?(machines ++ threads, &OverallsProtocol.uuid?/1),
       do: {:ok, %{session_id: session, machines: machines, threads: threads}},
       else: {:error, :invalid_response}
  end

  def subscription(_watch, _result), do: {:error, :invalid_response}

  @doc "Registry keys for an authorized subscription."
  @spec keys(t(), subscription()) :: [Porsche.Watchers.key()]
  def keys(watch, subscription) do
    machines =
      Enum.flat_map(subscription.machines, &[{"vm", &1}, {"terminal_session", &1}])

    threads = Enum.map(subscription.threads, &{"thread", &1})
    session = if watch.session, do: [{"ssh_session", subscription.session_id}], else: []
    [:resync | machines ++ threads ++ session]
  end

  @doc "Queues one hint; returns whether a flush must be scheduled."
  @spec queue(t(), String.t(), String.t()) :: {t(), boolean()}
  def queue(watch, kind, id) do
    watch = %{watch | pending: MapSet.put(watch.pending, {kind, id})}
    {watch, is_nil(watch.flush)}
  end

  @doc "The notices for queued hints, in a stable order, and the emptied state."
  @spec drain(t()) :: {[map()], t()}
  def drain(watch) do
    notices = watch.pending |> Enum.sort() |> Enum.map(&notice/1)
    {notices, %{watch | pending: MapSet.new(), flush: nil}}
  end

  @spec notice({String.t(), String.t()}) :: map()
  defp notice({"vm", id}), do: line("machine", %{"id" => id})
  defp notice({"terminal_session", id}), do: line("terminal_session", %{"machine_id" => id})
  defp notice({"thread", id}), do: line("thread", %{"id" => id})
  defp notice({"ssh_session", id}), do: line("session", %{"id" => id})

  @spec watching(subscription()) :: map()
  def watching(subscription),
    do:
      line("watching", %{
        "session_id" => subscription.session_id,
        "machines" => subscription.machines,
        "threads" => subscription.threads
      })

  @spec line(String.t(), map()) :: map()
  def line(event, fields \\ %{}),
    do: Map.merge(fields, %{"version" => 1, "event" => event})

  @spec list(nil | String.t() | [String.t()]) :: [String.t()]
  defp list(nil), do: []
  defp list(value) when is_binary(value), do: [value]
  defp list(values) when is_list(values), do: values
end
