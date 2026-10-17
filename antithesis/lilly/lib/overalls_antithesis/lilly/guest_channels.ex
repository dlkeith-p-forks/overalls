defmodule OverallsAntithesis.Lilly.GuestChannels do
  @moduledoc "Actual local terminald transport for the inner emulated guest host."

  alias OverallsAntithesis.Lilly.{GuestBoot, GuestExecutor, GuestTrustReceipt}
  alias OverallsProtocol.Execution
  alias Lilly.Control.Config

  # @cc [owner:ghuntley,label:security;verification] emulated-terminal-current-boot
  # Terminal dial options MUST require a freshly verified exact running boot,
  # a current private guest-trust receipt and a local socket derived from that
  # placement under the operator-selected emulator socket root. Neither a
  # caller path nor missing readiness or trust may grant
  # dial authority. The real terminal client still performs its port handshake
  # and challenge HMAC; this adapter does not manufacture guest replies.
  @spec terminal_options(Config.t(), Execution.command()) ::
          {:ok, keyword()} | {:error, :terminal_unavailable}
  def terminal_options(config, command) do
    with {:ok, boot} <- GuestExecutor.current_boot(config, command),
         %{guest_trust_roots: [_ | _] = roots} <- config.execution,
         {:ok, _boot_id} <- GuestTrustReceipt.read(config.state_dir, boot, roots),
         {:ok, path} <- socket_path(boot) do
      {:ok,
       [
         vsock_path: path,
         boot_log_path: nil,
         boot_challenge: boot.boot_challenge,
         placement_id: boot.placement_id,
         execution_epoch: boot.execution_epoch,
         generation: boot.generation
       ]}
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  @spec socket_path(GuestBoot.t()) :: {:ok, Path.t()} | {:error, :terminal_unavailable}
  def socket_path(boot) do
    with root when is_binary(root) <- System.get_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT"),
         true <- valid_root?(root),
         path = Path.join([root, binary_part(boot.placement_id, 0, 8), "v.sock"]),
         true <- byte_size(path) <= 107,
         {:ok, %{type: :other, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o170000) == 0o140000 do
      {:ok, path}
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  @spec valid_root?(String.t()) :: boolean()
  defp valid_root?(root),
    do:
      Path.type(root) == :absolute and Path.expand(root) == root and
        not String.contains?(root, [<<0>>, "\n", "\r"])

  # Audi's private connector is host-local. The outer Audi service has no
  # authenticated bridge into the inner host's connector; a TAP alone cannot
  # satisfy that boundary, its trust delivery, or production network isolation.
  @spec open_ingress(Config.t(), Execution.command(), map()) :: {:error, :ingress_unavailable}
  def open_ingress(_config, _command, _binding), do: {:error, :ingress_unavailable}
end
