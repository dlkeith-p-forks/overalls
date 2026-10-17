defmodule Porsche.Connection do
  @moduledoc "Transient session custody for one proven SSH connection; Marshall owns authority."
  use GenServer, restart: :temporary
  alias Porsche.{Client, SSH.Proof}
  require Porsche.Events

  @spec open(pid(), Client.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def open(connection, client, options \\ []) do
    DynamicSupervisor.start_child(
      Porsche.SSH.Connections,
      {__MODULE__, [connection: connection, client: client] ++ options}
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    connection = Keyword.fetch!(options, :connection)

    GenServer.start_link(__MODULE__, options,
      name: {:via, Registry, {Porsche.SSH.Sessions, connection}}
    )
  end

  @spec snapshot(pid()) :: {:ok, map()} | {:error, atom()}
  def snapshot(connection) do
    case Registry.lookup(Porsche.SSH.Sessions, connection) do
      [{pid, _}] -> GenServer.call(pid, :snapshot, 6000)
      _ -> {:error, :unauthorized}
    end
  catch
    :exit, _ -> {:error, :temporarily_unavailable}
  end

  # @cc [owner:ghuntley,label:security;recovery] porsche-session-requires-live-proof
  # A connection actor MUST refuse startup without that connection's proven key.
  # It MUST monitor the connection, open at most one Marshall session and stop
  # on disconnect. Closing a session MUST NOT cancel accepted domain work.
  @impl true
  def init(options) do
    :logger.update_process_metadata(%{porsche_private: true})
    connection = Keyword.fetch!(options, :connection)

    case Proof.lookup(connection) do
      {:ok, key} ->
        reference = Process.monitor(connection)

        {:ok,
         %{
           connection: connection,
           reference: reference,
           key: key,
           client: Keyword.fetch!(options, :client),
           request: Keyword.get(options, :request, &Client.request/3),
           session: nil,
           error: nil
         }, {:continue, :open}}

      :error ->
        {:stop, :unproven_connection}
    end
  end

  # @cc [owner:ghuntley,label:security] porsche-session-outcome-closed-atoms
  # Session open outcomes MUST be logged with only the closed outcome_state
  # atoms; session tokens, approval links, fingerprints, account identity and
  # raw response bodies MUST NOT be logged.
  @impl true
  def handle_continue(:open, state) do
    result =
      state.request.(state.client, "sessions", %{
        "version" => 1,
        "public_key" => state.key.public_key
      })

    Porsche.Events.emit("porsche.session_outcome", outcome_state: outcome(result, state.key))

    case result do
      {:ok, session} ->
        if valid_open?(session, state.key),
          do: {:noreply, %{state | session: session}},
          else: {:noreply, %{state | error: :invalid_response}}

      {:error, reason} ->
        {:noreply, %{state | error: reason}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %{error: error} = state) when not is_nil(error),
    do: {:reply, {:error, error}, state}

  def handle_call(:snapshot, _from, %{session: %{"status" => "pending"}} = state) do
    case state.request.(state.client, "session", credentials(state)) do
      {:ok, session} ->
        if valid_status?(session) and session["session_id"] == state.session["session_id"] do
          merged = Map.merge(state.session, session)

          merged =
            if session["status"] == "authenticated",
              do: Map.drop(merged, ["approval_path", "fingerprint"]),
              else: merged

          {:reply, {:ok, merged}, %{state | session: merged}}
        else
          {:reply, {:error, :invalid_response}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.session}, state}

  @impl true
  def handle_info(
        {:DOWN, reference, :process, connection, _reason},
        %{reference: reference, connection: connection} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{session: session} = state) when is_map(session) do
    state.request.(state.client, "close", credentials(state))
    Porsche.Events.emit("porsche.session_closed", [])
    :ok
  end

  def terminate(_, _), do: :ok

  defp outcome({:ok, session}, key) do
    if valid_open?(session, key) do
      case session["status"] do
        "authenticated" -> :ok
        _ -> :pending_approval
      end
    else
      :transport
    end
  end

  defp outcome({:error, :unauthorized}, _), do: :unauthorized
  defp outcome({:error, :forbidden}, _), do: :forbidden
  defp outcome({:error, _}, _), do: :transport

  defp credentials(state),
    do: %{"version" => 1, "session_token" => state.session["session_token"]}

  defp valid_open?(session, key) when is_map(session) do
    valid_status?(Map.drop(session, ["session_token", "fingerprint", "approval_path"])) and
      token?(session["session_token"], "porsche_session_") and
      case session["status"] do
        "authenticated" ->
          map_size(session) == 5

        "pending" ->
          map_size(session) == 6 and session["fingerprint"] == key.fingerprint and
            approval_path?(session["approval_path"])

        _ ->
          false
      end
  end

  defp valid_open?(_, _), do: false

  defp valid_status?(
         %{"status" => "pending", "session_id" => id, "expires_at" => expires} = value
       ),
       do: map_size(value) == 3 and OverallsProtocol.uuid?(id) and expiry?(expires)

  defp valid_status?(
         %{
           "status" => "authenticated",
           "session_id" => id,
           "expires_at" => expires,
           "user" => %{"id" => user, "email" => email} = account
         } = value
       ),
       do:
         map_size(value) == 4 and map_size(account) == 2 and OverallsProtocol.uuid?(id) and
           OverallsProtocol.uuid?(user) and is_binary(email) and byte_size(email) in 1..320 and
           String.valid?(email) and expiry?(expires)

  defp valid_status?(_), do: false

  defp expiry?(text) when is_binary(text) and byte_size(text) <= 40,
    do: match?({:ok, _, 0}, DateTime.from_iso8601(text))

  defp expiry?(_), do: false

  defp approval_path?("/ssh/approve/" <> token), do: token?(token, "porsche_approval_")
  defp approval_path?(_), do: false

  defp token?(value, prefix) when is_binary(value) do
    size = byte_size(prefix)

    with <<^prefix::binary-size(^size), encoded::binary-size(43)>> <- value,
         {:ok, bytes} when byte_size(bytes) == 32 <- Base.url_decode64(encoded, padding: false) do
      Base.url_encode64(bytes, padding: false) == encoded
    else
      _ -> false
    end
  end

  defp token?(_, _), do: false
end
