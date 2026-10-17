defmodule OverallsAntithesis.Lilly.GuestBoot do
  @moduledoc "Durable emulator-only boot identity, separate from native Intent and Boot."

  alias Lilly.Host.PrivateFiles
  alias Lilly.Network.Guest
  @maximum 9_223_372_036_854_775_807
  @record_name "guest-boot.json"

  @type t :: %{
          placement_id: OverallsProtocol.uuid(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          boot_challenge: String.t(),
          image_id: String.t(),
          disk_bytes: pos_integer(),
          profile: OverallsProtocol.AddressPool.profile(),
          slot: pos_integer(),
          address: String.t(),
          tap: String.t(),
          mac: String.t(),
          state: :launching | :running | :stopped
        }

  @spec path(Path.t(), OverallsProtocol.uuid()) :: Path.t()
  def path(root, placement), do: Path.join([root, "guest-boots", placement])

  # @cc [owner:ghuntley,label:recovery] guest-boot-persisted-before-launch
  # A launch MUST durably reserve one challenge for its exact command tuple,
  # image, disk and derived network identity before RPC. Replays reuse it; a
  # newer boot may replace it only after the previous process was stopped.
  @spec prepare(Path.t(), OverallsProtocol.Execution.command()) ::
          {:ok, t()} | {:error, :guest_boot_unconfirmed}
  def prepare(root, command) do
    with true <- valid_command?(command),
         {:ok, prior} <- read(root, command.placement_id),
         {:ok, next} <- next(prior, command),
         :ok <- write(root, next) do
      {:ok, next}
    else
      _ -> {:error, :guest_boot_unconfirmed}
    end
  end

  @spec read(Path.t(), OverallsProtocol.uuid()) ::
          {:ok, t() | nil} | {:error, :guest_boot_unconfirmed}
  def read(root, placement) do
    file = Path.join(path(root, placement), @record_name)

    case File.lstat(file) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, _} ->
        with {:ok, body} <- PrivateFiles.read_secret(file),
             {:ok, raw} <- JSON.decode(body),
             {:ok, boot} <- decode(raw),
             true <- boot.placement_id == placement do
          {:ok, boot}
        else
          _ -> {:error, :guest_boot_unconfirmed}
        end

      _ ->
        {:error, :guest_boot_unconfirmed}
    end
  end

  @spec mark(Path.t(), t(), :running | :stopped) ::
          :ok | {:error, :guest_boot_unconfirmed}
  def mark(root, boot, state) when state in [:running, :stopped] do
    with {:ok, ^boot} <- read(root, boot.placement_id),
         :ok <- write(root, %{boot | state: state}) do
      :ok
    else
      _ -> {:error, :guest_boot_unconfirmed}
    end
  end

  @spec next(t() | nil, OverallsProtocol.Execution.command()) ::
          {:ok, t()} | {:error, :guest_boot_unconfirmed}
  defp next(nil, command), do: {:ok, fresh(command)}

  defp next(prior, command) do
    revision = {command.execution_epoch, command.generation}
    previous = {prior.execution_epoch, prior.generation}

    cond do
      prior.placement_id != command.placement_id or prior.image_id != command.image_id or
        prior.disk_bytes != command.disk_bytes or prior.profile != command.profile or
          prior.slot != command.slot ->
        {:error, :guest_boot_unconfirmed}

      revision == previous and prior.state in [:launching, :running] ->
        {:ok, prior}

      revision > previous and prior.state == :stopped ->
        {:ok, fresh(command)}

      true ->
        {:error, :guest_boot_unconfirmed}
    end
  end

  @spec fresh(OverallsProtocol.Execution.command()) :: t()
  defp fresh(command) do
    {:ok, network} = Guest.new(command.placement_id, command.profile, command.slot)

    %{
      placement_id: command.placement_id,
      execution_epoch: command.execution_epoch,
      generation: command.generation,
      boot_challenge: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      image_id: command.image_id,
      disk_bytes: command.disk_bytes,
      profile: command.profile,
      slot: command.slot,
      address: network.address,
      tap: network.tap,
      mac: network.mac,
      state: :launching
    }
  end

  @spec write(Path.t(), t()) :: :ok | {:error, atom()}
  defp write(root, boot) do
    directory = path(root, boot.placement_id)

    with :ok <- PrivateFiles.directory(Path.join(root, "guest-boots")),
         :ok <- PrivateFiles.write(directory, @record_name, JSON.encode!(encode(boot))) do
      :ok
    end
  end

  @spec encode(t()) :: map()
  defp encode(boot),
    do: %{
      "version" => 2,
      "placement_id" => boot.placement_id,
      "execution_epoch" => boot.execution_epoch,
      "generation" => boot.generation,
      "boot_challenge" => boot.boot_challenge,
      "image_id" => boot.image_id,
      "disk_bytes" => boot.disk_bytes,
      "profile" => Atom.to_string(boot.profile),
      "slot" => boot.slot,
      "address" => boot.address,
      "tap" => boot.tap,
      "mac" => boot.mac,
      "state" => Atom.to_string(boot.state)
    }

  @spec decode(term()) :: {:ok, t()} | :error
  defp decode(
         %{
           "version" => 2,
           "placement_id" => placement,
           "execution_epoch" => epoch,
           "generation" => generation,
           "boot_challenge" => challenge,
           "image_id" => image,
           "disk_bytes" => disk,
           "profile" => profile,
           "slot" => slot,
           "address" => address,
           "tap" => tap,
           "mac" => mac,
           "state" => state
         } = raw
       )
       when map_size(raw) == 13 do
    with true <- OverallsProtocol.uuid?(placement),
         true <- is_integer(epoch) and epoch in 1..@maximum,
         true <- is_integer(generation) and generation in 1..@maximum,
         true <- is_binary(challenge) and Regex.match?(~r/\A[0-9a-f]{64}\z/, challenge),
         true <- OverallsProtocol.ImageManifest.id?(image),
         true <- is_integer(disk) and disk in 2_147_483_648..@maximum,
         parsed_profile when parsed_profile in [:customer, :standard, :oss, :inception] <-
           parse_profile(profile),
         {:ok, network} <- Guest.new(placement, parsed_profile, slot),
         true <- address == network.address and tap == network.tap and mac == network.mac,
         true <- state in ["launching", "running", "stopped"] do
      {:ok,
       %{
         placement_id: placement,
         execution_epoch: epoch,
         generation: generation,
         boot_challenge: challenge,
         image_id: image,
         disk_bytes: disk,
         profile: parsed_profile,
         slot: slot,
         address: address,
         tap: tap,
         mac: mac,
         state: String.to_existing_atom(state)
       }}
    else
      _ -> :error
    end
  end

  defp decode(_), do: :error

  @spec parse_profile(term()) :: OverallsProtocol.AddressPool.profile() | :error
  defp parse_profile("customer"), do: :customer
  defp parse_profile("standard"), do: :standard
  defp parse_profile("oss"), do: :oss
  defp parse_profile("inception"), do: :inception
  defp parse_profile(_), do: :error

  @spec valid_command?(OverallsProtocol.Execution.command()) :: boolean()
  defp valid_command?(command),
    do:
      OverallsProtocol.uuid?(command.placement_id) and
        OverallsProtocol.ImageManifest.id?(command.image_id) and
        is_integer(command.execution_epoch) and command.execution_epoch in 1..@maximum and
        is_integer(command.generation) and command.generation in 1..@maximum and
        is_integer(command.disk_bytes) and command.disk_bytes in 2_147_483_648..@maximum and
        match?({:ok, _}, Guest.new(command.placement_id, command.profile, command.slot))
end
