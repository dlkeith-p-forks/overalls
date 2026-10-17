defmodule Lilly.Host.ImageCatalogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.{Image, ImageCatalog}
  @moduletag :tmp_dir
  @moduletag :capture_log

  @typep command :: {:corrupt, non_neg_integer()} | {:repair, non_neg_integer()} | :restart
  @typep model :: %{
           required(:valid) => %{non_neg_integer() => boolean()},
           required(:advertisable) => MapSet.t(non_neg_integer())
         }

  # @cc [owner:ghuntley,label:verification] image-catalog-restart-model
  # Model Lilly restarts, same-size artifact corruption and repair. Only images
  # whose bytes were digest-verified by the current catalog and remain unchanged
  # may be advertised; staged images never are, and startup never waits.
  property "restart sequences advertise exactly the currently verified unchanged images", %{
    tmp_dir: root
  } do
    File.chmod!(root, 0o700)

    check all(
            count <- integer(1..3),
            commands <- list_of(command(count), max_length: 8),
            max_runs: 15
          ) do
      base = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir_p!(base)
      File.chmod!(base, 0o700)
      paths = for index <- 0..(count - 1), do: image(base, index)
      table = table()
      {staged, pid} = restart(table, paths, nil)

      model = %{
        valid: Map.new(0..(count - 1), &{&1, true}),
        advertisable: MapSet.new(0..(count - 1))
      }

      {staged, pid, _model} =
        Enum.reduce(commands, {staged, pid, model}, fn command, {staged, pid, model} ->
          {staged, pid, model} = step(command, table, paths, staged, pid, model)
          assert_projection(table, staged, model)
          {staged, pid, model}
        end)

      GenServer.stop(pid)
      assert ImageCatalog.verified(table, staged) == []
    end
  end

  test "startup returns before hashing and an absent catalog advertises nothing", %{
    tmp_dir: root
  } do
    File.chmod!(root, 0o700)
    path = image(root, 0, 64 * 1024 * 1024)
    assert {:ok, staged} = Image.stage(path)
    table = table()
    assert ImageCatalog.verified(table, [staged]) == []
    {:ok, pid} = ImageCatalog.start_link(name: table, images: [staged])
    assert ImageCatalog.verified(table, [staged]) == []
    _ = :sys.get_state(pid)
    assert [%Image{verified: true, id: id}] = ImageCatalog.verified(table, [staged])
    assert id == staged.id
    assert Image.available_ids(ImageCatalog.verified(table, [staged])) == [id]
    other = %{staged | path: Path.join(root, "absent")}
    assert ImageCatalog.verified(table, [other]) == []
    GenServer.stop(pid)
  end

  @spec command(pos_integer()) :: StreamData.t(command())
  defp command(count) do
    index = integer(0..(count - 1))

    one_of([
      map(index, &{:corrupt, &1}),
      map(index, &{:repair, &1}),
      constant(:restart)
    ])
  end

  defp step(:restart, table, paths, _staged, pid, model) do
    {staged, pid} = restart(table, paths, pid)

    advertisable =
      model.valid |> Enum.filter(fn {_, valid} -> valid end) |> MapSet.new(&elem(&1, 0))

    {staged, pid, %{model | advertisable: advertisable}}
  end

  defp step({kind, index}, _table, paths, staged, pid, model) do
    replace_rootfs(Enum.at(paths, index), index, kind == :repair)

    {staged, pid,
     %{
       model
       | valid: Map.put(model.valid, index, kind == :repair),
         advertisable: MapSet.delete(model.advertisable, index)
     }}
  end

  @spec assert_projection(atom(), [Image.t()], model()) :: :ok
  defp assert_projection(table, staged, model) do
    verified = ImageCatalog.verified(table, staged)
    assert Enum.all?(verified, &(&1.verified == true))
    assert Enum.all?(staged, &(&1.verified == false))
    assert Image.available_ids(staged) == []

    expected =
      model.advertisable |> Enum.map(&Enum.at(staged, &1).id) |> Enum.sort()

    assert Image.available_ids(verified) == expected
    :ok
  end

  defp restart(table, paths, pid) do
    if pid, do: GenServer.stop(pid)
    staged = Enum.map(paths, &(Image.stage(&1) |> elem(1)))
    {:ok, pid} = ImageCatalog.start_link(name: table, images: staged)
    _ = :sys.get_state(pid)
    {staged, pid}
  end

  defp table, do: :"image_catalog_#{System.unique_integer([:positive])}"

  defp image(root, index, rootfs_bytes \\ 0) do
    directory = Path.join(root, "image-#{index}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    artifacts =
      Map.new(["kernel", "initrd", "rootfs"], fn name ->
        file = if(name == "rootfs", do: "rootfs.ext4", else: name)
        data = content(name, index, true, rootfs_bytes)
        write_read_only(Path.join(directory, file), data)

        {name,
         %{
           "bytes" => byte_size(data),
           "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
         }}
      end)

    manifest =
      Map.merge(artifacts, %{
        "version" => 4,
        "workspace_source_version" => nil,
        "architecture" => "x86_64",
        "boot_args" => "console=ttyS0",
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648
      })

    write_read_only(Path.join(directory, "manifest.json"), JSON.encode!(manifest))
    directory
  end

  defp content("rootfs", index, valid, padding) do
    marker = if valid, do: "valid", else: "wrong"
    "synthetic rootfs #{index} #{marker}" <> :binary.copy(<<0>>, padding)
  end

  defp content(name, index, _valid, _padding), do: "synthetic #{name} #{index}"

  # Replacement uses a fresh inode and retains the old one, as a Nix store
  # replacement would, so identity cannot collide within timestamp granularity.
  defp replace_rootfs(directory, index, valid) do
    path = Path.join(directory, "rootfs.ext4")
    File.rename!(path, path <> ".#{System.unique_integer([:positive])}")
    write_read_only(path, content("rootfs", index, valid, 0))
  end

  defp write_read_only(path, data) do
    File.write!(path, data)
    File.chmod!(path, 0o444)
  end
end
