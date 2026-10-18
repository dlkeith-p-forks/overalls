defmodule Lilly.Host.MountTableTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Lilly.Host.{MountTable, Paths}

  @mountinfo """
  22 1 0:21 / / rw,relatime shared:1 - zfs zroot/root rw,xattr,posixacl
  27 68 0:27 / /run/credentials/x.service rw,nosuid,nodev shared:3 - tmpfs none ro,size=1024k
  40 22 0:21 /vms/a/disk /pool/.lilly-jails/firecracker/a/root/rootfs.ext4 rw,nosuid shared:9 - zfs zroot/lilly/vm-a rw,xattr
  41 22 0:44 / /mnt/with\\040space rw - ext4 /dev/vdb1 rw
  """

  test "rows follow mountinfo order in findmnt's shape" do
    assert {:ok, [root, credentials, bind, spaced]} = MountTable.parse(@mountinfo)

    assert root == %{
             "target" => "/",
             "source" => "zroot/root",
             "fstype" => "zfs",
             "fsroot" => "/",
             "options" => "rw,relatime,xattr,posixacl"
           }

    # A read-only superblock makes the mount read-only, as findmnt reports.
    assert credentials["options"] == "ro,nosuid,nodev,size=1024k"
    # A bind mount's source carries its fsroot in brackets.
    assert bind["source"] == "zroot/lilly/vm-a[/vms/a/disk]"
    assert bind["fsroot"] == "/vms/a/disk"
    # Octal escapes are decoded.
    assert spaced["target"] == "/mnt/with space"
  end

  test "a malformed line refuses the whole table" do
    assert MountTable.parse(@mountinfo <> "garbage without separator\n") == :error
  end

  # Any row the kernel can write round-trips through the parser (contract
  # mount-table-matches-findmnt): targets with spaces, tabs and backslashes
  # come back decoded, and nothing is silently dropped.
  property "escaped targets decode to the original path" do
    parts =
      draw(
        "parts",
        list_of(
          string(Enum.to_list(97..122) ++ ~c" \t\\", min_length: 1, max_length: 8),
          min_length: 1,
          max_length: 4
        )
      )

    target = "/" <> Enum.join(parts, "/")

    escaped =
      target
      |> String.to_charlist()
      |> Enum.map(fn
        c when c in [?\s, ?\t, ?\n, ?\\] ->
          "\\" <> String.pad_leading(Integer.to_string(c, 8), 3, "0")

        c ->
          <<c>>
      end)
      |> Enum.join()

    line = "50 22 0:30 / #{escaped} rw - tmpfs tmpfs rw\n"
    assert {:ok, [%{"target" => ^target}]} = MountTable.parse(line)
  end

  test "canonical/1 resolves symlinks and refuses missing or relative paths" do
    directory = Path.join(System.tmp_dir!(), "paths-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "real/inner"))
    File.ln_s!("real", Path.join(directory, "link"))
    File.ln_s!(Path.join(directory, "real/inner"), Path.join(directory, "absolute"))
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, base} = Paths.canonical(directory)

    assert Paths.canonical(Path.join(directory, "link/inner")) == {:ok, base <> "/real/inner"}

    assert Paths.canonical(Path.join(directory, "absolute/../inner")) ==
             {:ok, base <> "/real/inner"}

    assert Paths.canonical(Path.join(directory, "missing")) == :error
    assert Paths.canonical("relative/path") == :error
  end

  test "device_numbers/1 accepts only /dev/<name>" do
    assert Paths.device_numbers("/tmp/x") == :error
    assert Paths.device_numbers("/dev/../etc/passwd") == :error
  end
end
