defmodule OverallsAntithesis.Marshall.TerminalReplay do
  @moduledoc "One-shot, private replay arm for the authenticated Marshall host stream."

  @root "/run/overalls-terminal-replay"
  @max_request_bytes 2048
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @fields ~w(channel connection_epoch connection_session_id execution_epoch guest_session_id host_id placement_id request_id terminal_session_id version vm_id)

  @type receipt :: {String.t(), pos_integer()}
  @type stream_state :: %{
          required(:hello) => boolean() | :rejected,
          required(:host_id) => String.t(),
          required(:session_id) => String.t(),
          required(:epoch) => pos_integer()
        }
  # @cc [owner:ghuntley,label:security;verification] replay-only-current-authenticated-channel
  # The one-shot replay MUST duplicate only one encoded DATA frame on the exact
  # live authenticated host connection and attached channel named by a private
  # arm. It MUST NOT persist or emit terminal payload bytes in a receipt.
  @spec maybe_duplicate(binary(), stream_state(), map(), pos_integer(), pos_integer()) ::
          {binary(), receipt() | nil}
  def maybe_duplicate(frame, state, entry, channel, sequence) do
    root = root()
    active = Path.join(root, "active.json")

    with nil <- Map.get(entry, :replay_receipt),
         {:ok, request} <- read_arm(active),
         true <- matches?(request, state, entry, channel),
         true <-
           Marshall.Terminal.Directory.current_execution?(
             state.host_id,
             state.session_id,
             state.epoch
           ),
         claimed = Path.join([root, "claimed", request["request_id"] <> ".json"]),
         receipt = Path.join([root, "receipts", request["request_id"] <> ".json"]),
         false <- File.exists?(claimed) or File.exists?(receipt),
         :ok <- File.rename(active, claimed) do
      {frame <> frame, {request["request_id"], sequence}}
    else
      _ -> {frame, nil}
    end
  end

  # A cumulative Lilly input ACK is emitted only after its stream process has
  # decoded both DATA frames from the same WebSocket payload. The receipt is
  # therefore evidence of delivery through Lilly's production decoder.
  @spec acknowledge(String.t(), pos_integer(), pos_integer(), non_neg_integer()) :: :ok
  def acknowledge(request_id, channel, sequence, frames) do
    root = root()

    receipt = %{
      "version" => 1,
      "request_id" => request_id,
      "state" => "acknowledged",
      "channel" => channel,
      "sequence" => sequence,
      "acknowledged_frames" => frames
    }

    temporary = Path.join([root, "receipts", "." <> request_id <> ".new"])
    destination = Path.join([root, "receipts", request_id <> ".json"])

    with :ok <- File.write(temporary, JSON.encode!(receipt), [:exclusive, :binary]),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      _ -> :ok
    end
  end

  @spec read_arm(Path.t()) :: {:ok, map()} | :unavailable
  defp read_arm(path) do
    with {:ok, %{size: size, type: :regular}} when size > 0 and size <= @max_request_bytes <-
           File.stat(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_request_bytes,
         {:ok, %{} = request} <- JSON.decode(bytes),
         true <- Enum.sort(Map.keys(request)) == @fields,
         true <- valid_arm?(request) do
      {:ok, request}
    else
      _ -> :unavailable
    end
  end

  @spec valid_arm?(map()) :: boolean()
  defp valid_arm?(request) do
    request["version"] == 1 and
      Enum.all?(
        ~w(request_id host_id connection_session_id terminal_session_id vm_id placement_id),
        &uuid?(request[&1])
      ) and
      positive?(request["channel"]) and
      positive?(request["connection_epoch"]) and
      positive?(request["execution_epoch"]) and
      positive?(request["guest_session_id"])
  end

  @spec matches?(map(), stream_state(), map(), pos_integer()) :: boolean()
  defp matches?(request, state, entry, channel) do
    state.hello == true and request["host_id"] == state.host_id and
      request["connection_session_id"] == state.session_id and
      request["connection_epoch"] == state.epoch and
      request["channel"] == channel and
      request["terminal_session_id"] == Map.get(entry, :terminal_session_id) and
      request["vm_id"] == Map.get(entry, :vm_id) and
      request["placement_id"] == Map.get(entry, :placement_id) and
      request["execution_epoch"] == Map.get(entry, :execution_epoch) and
      request["guest_session_id"] == Map.get(entry, :guest_session_id)
  end

  @spec uuid?(term()) :: boolean()
  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  @spec positive?(term()) :: boolean()
  defp positive?(value), do: is_integer(value) and value > 0

  @spec root() :: Path.t()
  defp root, do: System.get_env("OVERALLS_ANTITHESIS_TERMINAL_REPLAY_ROOT", @root)
end
