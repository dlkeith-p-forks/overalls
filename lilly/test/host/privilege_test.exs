defmodule Lilly.Host.PrivilegeTest do
  # The service uid is a process-wide persistent term, so these tests own it.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Privilege
  @moduletag :tmp_dir
  @key {Privilege, :service_uid}

  setup %{tmp_dir: root} do
    previous = :persistent_term.get(@key, nil)

    on_exit(fn ->
      if previous == nil,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, previous)
    end)

    path = Path.join(root, "state")
    File.write!(path, "")
    {:ok, %File.Stat{uid: owner}} = File.lstat(path)
    %{path: path, owner: owner}
  end

  # service-uid-normalised-to-root: only root or the configured service uid
  # reads as 0; any other owner keeps its uid.
  @tag :hegel
  test "a file reads as root-owned exactly when its owner is the service uid", %{
    path: path,
    owner: owner
  } do
    Hegel.check(
      fn ->
        service = draw("service", one_of([constant(owner), integer(0..1_262_142)]))
        :persistent_term.put(@key, service)
        {:ok, %File.Stat{uid: reported}} = Privilege.lstat(path)
        {:ok, %File.Stat{uid: stat_reported}} = Privilege.stat(path)

        expected = if owner == 0 or owner == service, do: 0, else: owner
        assert reported == expected
        assert stat_reported == expected
      end,
      []
    )
  end

  test "without a configured service uid nothing but root is trusted", %{
    path: path,
    owner: owner
  } do
    :persistent_term.put(@key, 0)
    assert {:ok, %File.Stat{uid: ^owner}} = Privilege.lstat(path)
  end
end
