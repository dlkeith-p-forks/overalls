defmodule Lilly.Host.InceptionProof do
  @moduledoc "Boot-local native nesting evidence; CPU flags alone never advertise Inception."
  alias Lilly.Host.PrivateFiles
  alias Lilly.VM.Config

  # @cc [owner:ghuntley,label:capacity;security] inception-report-native-receipt
  # image_id/1 MUST require a private successful native-probe receipt matching
  # this host boot, the configured image, probe artifact and exact VMM executable.
  # Disabled/unloaded nesting, changed inputs or missing evidence MUST withhold
  # eligibility without preventing ordinary host reporting. The successful
  # nested Firecracker receipt is the virtualization evidence; module flags alone
  # are never consulted as proof. No SMTP is returned.
  @spec image_id(Config.t()) :: String.t() | nil
  def image_id(%Config{
        inception_proof_file: file,
        inception_probe_id: probe,
        inception_image_id: image,
        inception_smtp_file: smtp,
        firecracker: firecracker
      })
      when is_binary(file) and is_binary(probe) and is_binary(image) do
    with {:ok, current} <- File.read("/proc/sys/kernel/random/boot_id"),
         boot = String.trim(current),
         true <- OverallsProtocol.uuid?(boot),
         {:ok, _} <- Lilly.VM.Credentials.load(smtp),
         {:ok, encoded} <- PrivateFiles.read_secret(file),
         {:ok, value} <- JSON.decode(encoded),
         true <- matches?(value, boot, image, probe, firecracker),
         do: image,
         else: (_ -> nil)
  end

  def image_id(_), do: nil

  @doc false
  @spec matches?(term(), String.t(), String.t(), String.t(), Path.t()) :: boolean()
  def matches?(value, boot, image, probe, firecracker) do
    value === %{
      "version" => 1,
      "boot_id" => boot,
      "image_id" => image,
      "probe_id" => probe,
      "firecracker" => firecracker
    }
  end
end
