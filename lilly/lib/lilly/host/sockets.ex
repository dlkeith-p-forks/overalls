defmodule Lilly.Host.Sockets do
  @moduledoc """
  Connections Lilly cannot open itself once it runs unprivileged (ADR-0182).

  Firecracker API and vsock sockets live in jails owned by per-VM uids, and
  ingress connections start inside VM network namespaces. When Lilly runs
  as a configured service user, lilly-hostd opens them and passes the
  descriptor, which `gen_tcp` adopts. As root Lilly connects directly.
  """
  alias Lilly.Host.{Hostd, Privilege}

  # @cc [owner:ghuntley,label:security] sockets-through-hostd-when-unprivileged
  # connect_local/3 and connect_netns/4 MUST obtain the descriptor from
  # lilly-hostd whenever Lilly runs as a non-root service user, adopting it
  # with the caller's gen_tcp options, and connect directly only as root.
  @spec connect_local(Path.t(), list(), pos_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_local(path, options, timeout) do
    address = {:local, String.to_charlist(path)}

    if Privilege.unprivileged?() do
      with {:ok, fd} <- Hostd.open_unix(path, timeout),
           do: :gen_tcp.connect(address, 0, [{:fd, fd} | options], timeout)
    else
      :gen_tcp.connect(address, 0, options, timeout)
    end
  end

  @spec connect_netns(Hostd.netns_tcp(), list(), list(), pos_integer()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect_netns(request, direct_options, options, timeout) do
    if Privilege.unprivileged?() do
      with {:ok, fd} <- Hostd.open_netns_tcp(request, timeout),
           do: :gen_tcp.connect(request.destination, request.port, [{:fd, fd} | options], timeout)
    else
      :gen_tcp.connect(request.destination, request.port, direct_options ++ options, timeout)
    end
  end
end
