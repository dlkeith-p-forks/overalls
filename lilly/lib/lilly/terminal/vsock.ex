defmodule Lilly.Terminal.Vsock do
  @moduledoc "Bounded Firecracker vsock terminal client speaking the guest terminald framing."
  require Lilly.Events

  @port 1075
  @hello_nonce 16
  @hello_tag 32
  @attach_token 16
  @frame_overhead 4
  @max_payload 8192
  @replay_cap 8_388_608

  @magic 0x4C
  @op_hello 1
  @op_create 2
  @op_list 3
  @op_kill 4
  @op_resize 5
  @op_ping 6
  @op_attach 10
  @op_recover_token 11
  @op_create_once 12
  @op_creation_status 13
  @op_cancel_creation 14
  @op_users 15
  @op_ok 0x80
  @op_err 0x81

  @type socket :: :gen_tcp.socket()
  @type identity :: %{
          required(:uds_path) => String.t(),
          required(:placement_id) => String.t(),
          required(:execution_epoch) => pos_integer(),
          required(:boot_challenge) => String.t(),
          optional(:actor_pid) => pid(),
          optional(:host_id) => String.t(),
          optional(:generation) => pos_integer()
        }
  @type guest_session :: %{
          required(:guest_session_id) => pos_integer(),
          required(:user) => String.t(),
          required(:cols) => pos_integer(),
          required(:rows) => pos_integer(),
          required(:viewers) => non_neg_integer(),
          required(:alive) => boolean(),
          required(:created_ms) => non_neg_integer(),
          required(:last_ms) => non_neg_integer()
        }
  @type dial_error ::
          :connect_failed | :handshake_failed | :timeout | :closed | :rejected

  @type attach :: %{
          required(:socket) => socket(),
          required(:from) => non_neg_integer(),
          required(:replay) => binary(),
          required(:replay_bytes) => non_neg_integer()
        }

  # @cc [owner:ghuntley,label:security] hello-key-derivation
  # hello_tag/2 MUST derive the daemon key exactly as terminald does: the SHA-256
  # digest of the boot challenge bytes followed by the fixed domain label, and
  # the HMAC over the label, nonce, placement and epoch with no separators.
  @spec hello_tag(identity(), binary()) :: binary()
  def hello_tag(identity, nonce) do
    key = :crypto.hash(:sha256, [identity.boot_challenge, "overalls-terminald-v1"])

    :crypto.mac(
      :hmac,
      :sha256,
      key,
      [
        "terminald-hello-v1",
        nonce,
        identity.placement_id,
        Integer.to_string(identity.execution_epoch)
      ]
    )
  end

  @spec port() :: pos_integer()
  def port, do: @port

  # @cc [owner:ghuntley,label:protocol] connect-requires-fresh-hello
  # connect/2 MUST present a freshly generated nonce and its exact HMAC tag as
  # the first frame and MUST fail without further I/O when the daemon rejects it.
  @spec connect(identity(), keyword()) :: {:ok, socket()} | {:error, dial_error()}
  def connect(identity, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)

    with_dial(identity, timeout, fn socket ->
      with :ok <- authenticate(socket, identity, timeout) do
        {:ok, socket}
      end
    end)
  end

  @spec create(socket(), String.t(), String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, %{guest_session_id: pos_integer(), attach_token: binary()}}
          | {:error, dial_error()}
  def create(socket, user, term, cols, rows, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)
    payload = <<byte_size(user), user::binary, byte_size(term), term::binary, cols::16, rows::16>>

    {operation, payload} =
      case Keyword.get(options, :request_id) do
        nil -> {@op_create, payload}
        request_id -> {@op_create_once, request_bytes!(request_id) <> payload}
      end

    with {:ok, socket} <- send_frame_checked(socket, operation, payload),
         {:ok, @op_ok, <<id::64, token::binary-size(@attach_token)>>} <-
           receive_frame(socket, timeout) do
      {:ok, %{guest_session_id: id, attach_token: token}}
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  @spec creation_status(socket(), String.t()) ::
          {:ok,
           %{
             state: :running | :exited | :unknown,
             guest_session_id: pos_integer() | nil
           }}
          | {:error, dial_error()}
  def creation_status(socket, request_id) do
    with :ok <- send_frame(socket, @op_creation_status, request_bytes!(request_id)) do
      case receive_frame(socket, 2000) do
        {:ok, @op_ok, <<id::64, alive>>} when id > 0 and alive in [0, 1] ->
          {:ok, %{state: if(alive == 1, do: :running, else: :exited), guest_session_id: id}}

        {:ok, @op_err, <<2>>} ->
          {:ok, %{state: :unknown, guest_session_id: nil}}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :handshake_failed}
      end
    end
  end

  @spec cancel_creation(socket(), String.t()) :: :ok | {:error, dial_error()}
  def cancel_creation(socket, request_id) do
    with :ok <- send_frame(socket, @op_cancel_creation, request_bytes!(request_id)),
         {:ok, @op_ok, <<>>} <- receive_frame(socket, 2000) do
      Lilly.Events.emit("lilly.terminal_creation_cancel_ack", request_id: request_id)
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :rejected}
    end
  end

  defp request_bytes!(id) do
    if OverallsProtocol.uuid?(id) do
      Base.decode16!(String.replace(id, "-", ""), case: :mixed)
    else
      raise ArgumentError, "Invalid terminal request identity"
    end
  end

  @spec kill(socket(), pos_integer(), keyword()) :: :ok | {:error, dial_error()}
  # @cc [owner:ghuntley,label:security] recover-token-is-host-local
  # Recovery MUST use an authenticated guest control socket. The token MUST
  # remain in host memory and MUST NOT enter Marshall controls or diagnostics.
  @spec recover_token(socket(), pos_integer()) :: {:ok, binary()} | {:error, dial_error()}
  def recover_token(socket, guest_session_id) do
    with :ok <- send_frame(socket, @op_recover_token, <<guest_session_id::64>>),
         {:ok, @op_ok, <<token::binary-size(@attach_token)>>} <- receive_frame(socket, 2000) do
      {:ok, token}
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  def kill(socket, guest_session_id, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)

    with {:ok, socket} <- send_frame_checked(socket, @op_kill, <<guest_session_id::64>>),
         {:ok, @op_ok, ""} <- receive_frame(socket, timeout) do
      :ok
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  @spec resize(socket(), pos_integer(), pos_integer(), pos_integer(), keyword()) ::
          :ok | {:error, dial_error()}
  def resize(socket, guest_session_id, cols, rows, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)
    payload = <<guest_session_id::64, cols::16, rows::16>>

    with {:ok, socket} <- send_frame_checked(socket, @op_resize, payload),
         {:ok, @op_ok, ""} <- receive_frame(socket, timeout) do
      :ok
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  @spec list(socket(), keyword()) :: {:ok, [guest_session()]} | {:error, dial_error()}
  def list(socket, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)

    with {:ok, socket} <- send_frame_checked(socket, @op_list, <<>>),
         {:ok, @op_ok, payload} <- receive_frame(socket, timeout),
         {:ok, sessions} <- decode_list(payload) do
      {:ok, sessions}
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  @spec users(socket()) :: {:ok, [String.t()]} | {:error, dial_error()}
  def users(socket) do
    with :ok <- send_frame(socket, @op_users, <<>>),
         {:ok, @op_ok, <<count::16, rest::binary>>} when count <= 64 <-
           receive_frame(socket, 2000) do
      decode_users(rest, count, [])
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :rejected}
    end
  end

  @spec decode_users(binary(), non_neg_integer(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, dial_error()}
  defp decode_users(<<>>, 0, users), do: {:ok, Enum.reverse(users)}

  defp decode_users(<<length, rest::binary>>, count, users) when count > 0 and length in 1..64 do
    with <<user::binary-size(^length), tail::binary>> <- rest,
         true <- String.valid?(user) and not String.contains?(user, [<<0>>, "\n", "\r"]) do
      decode_users(tail, count - 1, [user | users])
    else
      _ -> {:error, :handshake_failed}
    end
  end

  defp decode_users(_, _, _), do: {:error, :handshake_failed}

  @spec ping(socket(), keyword()) :: :ok | {:error, dial_error()}
  def ping(socket, options \\ []) do
    timeout = Keyword.get(options, :timeout, 2000)

    with {:ok, socket} <- send_frame_checked(socket, @op_ping, <<>>),
         {:ok, @op_ok, ""} <- receive_frame(socket, timeout) do
      :ok
    else
      {:ok, @op_err, <<_code>>} -> {:error, :rejected}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  # @cc [owner:ghuntley,label:security] attach-reports-replay-start
  # attach/6 MUST dial a fresh socket, complete a fresh boot-bound hello before
  # presenting the session token, request the
  # caller's scrollback cursor, and return the daemon's actual replay start so
  # skipped scrollback is explicit; the returned socket carries raw live bytes.
  @spec attach(identity(), pos_integer(), binary(), :rw | :ro, non_neg_integer(), keyword()) ::
          {:ok, attach() | %{socket: socket(), from: non_neg_integer(), replay: binary()}}
          | {:error, dial_error()}
  def attach(identity, guest_session_id, token, mode, cursor, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5000)
    cols = if mode == :rw, do: Keyword.get(options, :cols, 0), else: 0
    rows = if mode == :rw, do: Keyword.get(options, :rows, 0), else: 0

    with_dial(identity, timeout, fn socket ->
      with :ok <- authenticate(socket, identity, timeout),
           mode_value <- if(mode == :rw, do: 1, else: 0),
           payload =
             <<guest_session_id::64, token::binary-size(@attach_token), mode_value, cursor::64,
               cols::16, rows::16>>,
           :ok <- send_frame(socket, @op_attach, payload),
           {:ok, @op_ok, <<from::64, replay_len::32>>} <- receive_frame(socket, timeout),
           true <- replay_len <= @replay_cap do
        if Keyword.get(options, :stream_replay, false) do
          {:ok, %{socket: socket, from: from, replay: <<>>, replay_bytes: replay_len}}
        else
          with {:ok, replay} <- receive_exact(socket, replay_len, timeout),
               do: {:ok, %{socket: socket, from: from, replay: replay, replay_bytes: replay_len}}
        end
      else
        {:ok, @op_err, <<_code>>} -> {:error, :rejected}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :handshake_failed}
      end
    end)
  end

  @spec write(socket(), binary()) :: :ok | {:error, term()}
  def write(socket, bytes), do: :gen_tcp.send(socket, bytes)

  @spec close(socket()) :: :ok
  def close(socket), do: :gen_tcp.close(socket)

  # @cc [owner:ghuntley,label:recovery] failed-guest-negotiation-closes-socket
  # Every failure after dialing, including authentication, malformed attachment
  # replies and incomplete replay, MUST close the new socket before returning.
  # Successful calls transfer the socket to the caller for explicit ownership.
  @spec with_dial(identity(), non_neg_integer(), (socket() ->
                                                    {:ok, result} | {:error, dial_error()})) ::
          {:ok, result} | {:error, dial_error()}
        when result: var
  defp with_dial(identity, timeout, operation) do
    with {:ok, socket} <- dial(identity.uds_path, timeout) do
      try do
        case operation.(socket) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            close(socket)
            {:error, reason}
        end
      rescue
        _ ->
          close(socket)
          {:error, :handshake_failed}
      end
    else
      {:error, reason} ->
        Lilly.Terminal.Metrics.dial(identity, false)
        {:error, reason}
    end
  end

  @spec authenticate(socket(), identity(), non_neg_integer()) :: :ok | {:error, dial_error()}
  defp authenticate(socket, identity, timeout) do
    result =
      with :ok <- send_frame(socket, @op_hello, hello_payload(identity)),
           {:ok, @op_ok, ""} <- receive_frame(socket, timeout),
           do: :ok,
           else: (
             {:ok, @op_err, <<_>>} -> {:error, :rejected}
             {:error, reason} -> {:error, reason}
             _ -> {:error, :handshake_failed}
           )

    Lilly.Terminal.Metrics.dial(identity, result == :ok)
    result
  end

  defp hello_payload(identity) do
    nonce = :crypto.strong_rand_bytes(@hello_nonce)
    tag = hello_tag(identity, nonce)
    <<nonce::binary-size(@hello_nonce), tag::binary-size(@hello_tag)>>
  end

  # @cc [owner:ghuntley,label:protocol] firecracker-vsock-connect-before-hello
  # Every dial MUST negotiate Firecracker's CONNECT port handshake before
  # terminald frames. A missing, oversized or invalid response closes the socket.
  defp dial(path, timeout) do
    case Lilly.Host.Sockets.connect_local(
           path,
           [:binary, packet: :line, packet_size: 64, active: false, send_timeout: timeout],
           timeout
         ) do
      {:ok, socket} ->
        with :ok <- :gen_tcp.send(socket, "CONNECT #{@port}\n"),
             {:ok, response} <- :gen_tcp.recv(socket, 0, timeout),
             true <- Regex.match?(~r/\AOK [1-9][0-9]{0,9}\n\z/, response),
             :ok <- :inet.setopts(socket, packet: :raw, packet_size: 0) do
          {:ok, socket}
        else
          _ ->
            :gen_tcp.close(socket)
            {:error, :handshake_failed}
        end

      {:error, _} ->
        {:error, :connect_failed}
    end
  end

  defp send_frame_checked(socket, op, payload) do
    case send_frame(socket, op, payload) do
      :ok -> {:ok, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_frame(socket, op, payload) do
    frame = <<@magic, op, byte_size(payload)::16, payload::binary>>

    case :gen_tcp.send(socket, frame) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :closed}
    end
  end

  defp receive_frame(socket, timeout) do
    with {:ok, <<@magic, op, length::16>>} when length <= @max_payload <-
           receive_exact(socket, @frame_overhead, timeout),
         {:ok, payload} <- receive_exact(socket, length, timeout) do
      {:ok, op, payload}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :handshake_failed}
    end
  end

  defp receive_exact(_socket, 0, _timeout), do: {:ok, ""}

  defp receive_exact(socket, length, timeout) do
    case :gen_tcp.recv(socket, length, timeout) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      {:ok, _} -> {:error, :closed}
      {:error, :closed} -> {:error, :closed}
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :closed}
    end
  end

  defp decode_list(<<count::16, rest::binary>>) when count <= 64,
    do: decode_entries(rest, count, [])

  defp decode_list(_), do: {:error, :handshake_failed}

  defp decode_entries("", 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_entries(<<id::64, user_len, rest::binary>>, count, acc)
       when count > 0 and user_len in 1..64 do
    with <<user::binary-size(^user_len), cols::16, rows::16, viewers::16, alive, created_ms::64,
           last_ms::64, remaining::binary>> <-
           rest,
         true <-
           id in 1..9_223_372_036_854_775_807 and String.valid?(user) and
             cols in 1..4096 and rows in 1..512 and viewers in 0..8 and alive in [0, 1] and
             created_ms <= 9_223_372_036_854_775_807 and last_ms <= 9_223_372_036_854_775_807 do
      entry = %{
        guest_session_id: id,
        user: user,
        cols: cols,
        rows: rows,
        viewers: viewers,
        alive: alive == 1,
        created_ms: created_ms,
        last_ms: last_ms
      }

      decode_entries(remaining, count - 1, [entry | acc])
    else
      _ -> {:error, :handshake_failed}
    end
  end

  defp decode_entries(_, _, _), do: {:error, :handshake_failed}
end
