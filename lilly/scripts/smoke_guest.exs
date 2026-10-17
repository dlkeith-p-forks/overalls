Code.require_file("zfs_fixture.exs", __DIR__)
# Run as root with the pinned runtime, after building the guest and Lilly.
# This is an image/console smoke test, not the production jailer/network driver.
defmodule Lilly.GuestSmoke do
  alias Lilly.Console.Dtach

  # @cc [owner:ghuntley,label:verification] image-smoke-retained-disk
  # run/1 MUST read the marker from inside the guest after shutdown and restart
  # using the retained disk before claiming persistence; this unjailed image
  # smoke MUST NOT establish production confinement or network isolation.
  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          guest: :string,
          firecracker: :string,
          dtach: :string,
          zfs_parent_dataset: :string
        ]
      )

    guest = Keyword.fetch!(opts, :guest)
    firecracker = Keyword.fetch!(opts, :firecracker)
    dtach = Keyword.fetch!(opts, :dtach)
    manifest = guest |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
    token = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    directory = Path.join(System.tmp_dir!(), "lilly-smoke-#{token}")

    fixture =
      Lilly.ZFSFixture.create(
        Keyword.fetch!(opts, :zfs_parent_dataset),
        directory,
        Lilly.UUID.generate()
      )

    unit = "lilly-smoke-#{token}"
    socket_path = Path.join(directory, "console.sock")
    disk = Path.join(directory, "rootfs.ext4")
    configuration = Path.join(directory, "firecracker.json")

    try do
      {_, 0} =
        System.cmd("cp", [
          "--sparse=always",
          "--reflink=never",
          "--",
          Path.join(guest, "rootfs.ext4"),
          disk
        ])

      config = %{
        "boot-source" => %{
          "kernel_image_path" => Path.join(guest, "kernel"),
          "initrd_path" => Path.join(guest, "initrd"),
          "boot_args" => manifest["boot_args"]
        },
        "drives" => [
          %{
            "drive_id" => "root",
            "path_on_host" => disk,
            "is_root_device" => true,
            "is_read_only" => false,
            "cache_type" => "Writeback",
            "io_engine" => "Sync"
          }
        ],
        "machine-config" => %{"vcpu_count" => 1, "mem_size_mib" => 512, "smt" => false}
      }

      File.write!(configuration, JSON.encode!(config))
      start(unit, directory, dtach, firecracker, socket_path, configuration)
      socket = connect(socket_path, deadline(10_000))
      wait_for(socket, "root@lilly-guest", deadline(120_000))
      :ok = Dtach.write(socket, "printf '\\nLILLY_UID:%s\\n' \"$(id -u)\"\n")
      wait_for(socket, "\r\nLILLY_UID:0\r\n", deadline(10_000))
      IO.puts("Guest booted with a root console.")
      :ok = Dtach.write(socket, "printf '#{token}' > /root/lilly-smoke-marker; sync\n")
      verify_marker(socket, token)
      :ok = Dtach.close(socket)

      # A disconnected console client must not take down the guest process.
      socket = connect(socket_path, deadline(10_000))
      verify_marker(socket, token)
      # On x86, Firecracker exits on i8042 reset, not ACPI poweroff.
      :ok = Dtach.write(socket, "reboot\n")
      wait_closed(socket, deadline(30_000))
      :ok = Dtach.close(socket)
      wait_stopped(unit, deadline(30_000))
      File.rm(socket_path)

      start(unit, directory, dtach, firecracker, socket_path, configuration)
      socket = connect(socket_path, deadline(10_000))
      wait_for(socket, "root@lilly-guest", deadline(120_000))
      verify_marker(socket, token)
      :ok = Dtach.close(socket)

      IO.puts(
        "Guest smoke passed: NixOS boot, root console, detach/reattach, persistent disk across orderly shutdown/start."
      )
    after
      System.cmd("/bin/systemctl", ["stop", unit], stderr_to_stdout: true)
      System.cmd("/bin/systemctl", ["reset-failed", unit], stderr_to_stdout: true)
      wait_stopped(unit, deadline(30_000))
      :ok = Lilly.ZFSFixture.destroy(fixture)
    end
  end

  defp start(unit, directory, dtach, firecracker, socket_path, configuration) do
    {_, 0} =
      System.cmd(
        "/bin/systemd-run",
        [
          "--quiet",
          "--collect",
          "--service-type=exec",
          "--unit",
          unit,
          "--working-directory",
          directory,
          "--property=StandardOutput=null",
          "--property=StandardError=null",
          "--property=UMask=0077",
          dtach,
          "-N",
          socket_path,
          "-z",
          firecracker,
          "--no-api",
          "--config-file",
          configuration
        ],
        stderr_to_stdout: true
      )
  end

  defp verify_marker(socket, token) do
    :ok =
      Dtach.write(socket, "printf '\\nLILLY_DISK:%s\\n' \"$(cat /root/lilly-smoke-marker)\"\n")

    wait_for(socket, "\r\nLILLY_DISK:#{token}\r\n", deadline(10_000))
  end

  defp connect(path, deadline) do
    case Dtach.connect(path) do
      {:ok, socket} -> socket
      {:error, _} -> retry(fn -> connect(path, deadline) end, deadline, "console unavailable")
    end
  end

  defp wait_for(socket, marker, deadline, tail \\ "") do
    # Both the guest serial TTY and the host PTY may add carriage returns.
    # Normalize them only in this assertion helper; the client preserves bytes.
    marker = :binary.replace(marker, "\r", "", [:global])

    if System.monotonic_time(:millisecond) >= deadline,
      do: raise("guest console readiness timed out")

    case Dtach.read(socket, 1000) do
      {:ok, bytes} ->
        buffer = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(buffer, marker) != :nomatch do
          :ok
        else
          size = min(byte_size(buffer), byte_size(marker))
          wait_for(socket, marker, deadline, binary_part(buffer, byte_size(buffer) - size, size))
        end

      {:error, :timeout} ->
        wait_for(socket, marker, deadline, tail)

      {:error, _} ->
        raise "guest console closed before readiness"
    end
  end

  defp wait_stopped(unit, deadline) do
    {status, _} =
      System.cmd("/bin/systemctl", ["show", "--property=ActiveState", "--value", unit],
        stderr_to_stdout: true
      )

    if String.trim(status) in ["inactive", "failed"],
      do: :ok,
      else: retry(fn -> wait_stopped(unit, deadline) end, deadline, "guest did not stop")
  end

  defp wait_closed(socket, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("guest did not close console")

    case Dtach.read(socket, 1000) do
      {:error, :closed} -> :ok
      {:ok, _bytes} -> wait_closed(socket, deadline)
      {:error, :timeout} -> wait_closed(socket, deadline)
      {:error, _reason} -> raise "guest console failed during shutdown"
    end
  end

  defp retry(fun, deadline, message) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise(message)

    receive do
    after
      50 -> fun.()
    end
  end

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds
end

Lilly.GuestSmoke.run(System.argv())
