defmodule Galileo.GitHub.Capabilities do
  @moduledoc "Bounded ephemeral custody of GitHub transfer URLs and action headers."
  use GenServer
  alias OverallsProtocol.{GitHub, Integration, PrivateServices}

  @ttl_ms 60_000
  @limit 4096
  @type scope :: :anonymous | {String.t(), pos_integer()}
  @type object :: %{oid: String.t(), size: non_neg_integer(), repository: String.t()}
  @type transfer :: %{
          url: String.t(),
          headers: [{String.t(), String.t()}],
          method: String.t(),
          object: object() | nil,
          ttl: pos_integer()
        }
  @type entry :: %{
          transfer: transfer(),
          binding: PrivateServices.binding(),
          scope: scope(),
          expires: integer()
        }
  @type state :: %{String.t() => entry()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, if(name == nil, do: [], else: [name: name]))
  end

  # @cc [owner:ghuntley,label:security] github-transfer-capability-custody
  # Transfer URLs and action headers MUST stay only in bounded process memory,
  # become unusable within sixty seconds, and have scheduled idle removal.
  # A selector MUST bind the exact VM execution, connection generation and
  # method. Mutating selectors MUST be consumed atomically before dispatch.
  @spec mint(String.t(), map(), GitHub.lease(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :unavailable}
  def mint(url, binding, lease, server \\ __MODULE__) do
    with {:ok, _} <- GitHub.download_url(url) do
      mint_transfer(
        %{url: url, headers: [], method: "GET", object: nil, ttl: @ttl_ms},
        binding,
        lease,
        server
      )
    else
      _ -> {:error, :unavailable}
    end
  end

  @spec mint_transfer(transfer(), map(), GitHub.lease(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :unavailable}
  def mint_transfer(transfer, binding, lease, server \\ __MODULE__) do
    with {:ok, _} <- GitHub.transfer_url(transfer.url),
         {:ok, binding} <- PrivateServices.binding(binding),
         true <- transfer.method in ["GET", "PUT", "POST"],
         true <- is_integer(transfer.ttl) and transfer.ttl in 1..@ttl_ms,
         true <- length(transfer.headers) <= 16,
         true <-
           Enum.all?(transfer.headers, fn {name, value} ->
             match?({:ok, _}, Integration.header([name, value]))
           end) do
      GenServer.call(server, {:mint, transfer, binding, scope(lease)})
    else
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @spec resolve(String.t(), map(), GitHub.lease(), String.t(), GenServer.server()) ::
          {:ok, transfer()} | {:error, :unavailable}
  def resolve(selector, binding, lease, method, server \\ __MODULE__) do
    with true <- GitHub.selector?(selector),
         {:ok, binding} <- PrivateServices.binding(binding) do
      GenServer.call(server, {:resolve, selector, binding, scope(lease), method})
    else
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted) |> Map.put(:log, [])

  @impl true
  def handle_call({:mint, transfer, binding, scope}, _from, state) do
    state = current(state)

    if map_size(state) < @limit do
      selector = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      entry = %{transfer: transfer, binding: binding, scope: scope, expires: now() + transfer.ttl}
      _ = Process.send_after(self(), {:expire, selector}, transfer.ttl)
      {:reply, {:ok, "/capabilities/" <> selector}, Map.put(state, selector, entry)}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:resolve, selector, binding, scope, method}, _from, state) do
    state = current(state)

    case Map.get(state, selector) do
      %{binding: ^binding, scope: ^scope, transfer: transfer} ->
        if method == transfer.method or (transfer.method == "GET" and method == "HEAD") do
          next = if GitHub.read_method?(method), do: state, else: Map.delete(state, selector)
          {:reply, {:ok, transfer}, next}
        else
          {:reply, {:error, :unavailable}, state}
        end

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  @impl true
  def handle_info({:expire, selector}, state), do: {:noreply, Map.delete(state, selector)}

  @spec scope(GitHub.lease()) :: scope()
  defp scope(:anonymous), do: :anonymous
  defp scope(lease), do: {lease.connection_id, lease.generation}
  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
  @spec current(state()) :: state()
  defp current(state), do: Map.reject(state, fn {_selector, entry} -> entry.expires <= now() end)
end
