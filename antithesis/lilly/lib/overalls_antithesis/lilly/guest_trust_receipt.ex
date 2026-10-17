defmodule OverallsAntithesis.Lilly.GuestTrustReceipt do
  @moduledoc "Private boot-bound receipt for public guest trust delivered through the emulator vsock."

  alias OverallsAntithesis.Lilly.GuestBoot
  alias Lilly.Host.PrivateFiles
  alias Lilly.VM.GuestTrust

  @name "guest-trust.json"

  # @cc [owner:ghuntley,label:security;recovery] emulated-trust-receipt-exact-boot
  # A receipt MUST authorize only its exact placement, epoch, generation, challenge,
  # public-root digest and guest boot ID. Missing or corrupt private state MUST fail closed.
  @spec read(Path.t(), GuestBoot.t(), [binary()]) ::
          {:ok, OverallsProtocol.uuid()} | {:error, :trust_unconfirmed}
  def read(root, boot, roots) when is_list(roots) and roots != [] do
    path = Path.join(GuestBoot.path(root, boot.placement_id), @name)

    with {:ok, body} <- PrivateFiles.read_secret(path),
         {:ok, %{} = raw} <- JSON.decode(body),
         true <- exact?(raw, boot, GuestTrust.digest(roots)) do
      {:ok, raw["boot_id"]}
    else
      _ -> {:error, :trust_unconfirmed}
    end
  end

  def read(_, _, _), do: {:error, :trust_unconfirmed}

  @spec write(Path.t(), GuestBoot.t(), [binary()], OverallsProtocol.uuid(), String.t()) ::
          :ok | {:error, :trust_unconfirmed}
  def write(root, boot, roots, boot_id, digest) when is_list(roots) and roots != [] do
    with true <- OverallsProtocol.uuid?(boot_id) and digest == GuestTrust.digest(roots),
         raw = payload(boot, boot_id, digest),
         :ok <-
           PrivateFiles.write(GuestBoot.path(root, boot.placement_id), @name, JSON.encode!(raw)),
         {:ok, ^boot_id} <- read(root, boot, roots) do
      :ok
    else
      _ -> {:error, :trust_unconfirmed}
    end
  end

  def write(_, _, _, _, _), do: {:error, :trust_unconfirmed}

  @spec payload(GuestBoot.t(), OverallsProtocol.uuid(), String.t()) :: map()
  defp payload(boot, boot_id, digest),
    do: %{
      "version" => 1,
      "placement_id" => boot.placement_id,
      "execution_epoch" => boot.execution_epoch,
      "generation" => boot.generation,
      "boot_challenge" => boot.boot_challenge,
      "boot_id" => boot_id,
      "bundle_digest" => digest
    }

  @spec exact?(map(), GuestBoot.t(), String.t()) :: boolean()
  defp exact?(raw, boot, digest) do
    map_size(raw) == 7 and raw["version"] == 1 and
      raw["placement_id"] == boot.placement_id and
      raw["execution_epoch"] == boot.execution_epoch and
      raw["generation"] == boot.generation and
      raw["boot_challenge"] == boot.boot_challenge and
      OverallsProtocol.uuid?(raw["boot_id"]) and raw["bundle_digest"] == digest
  end
end
