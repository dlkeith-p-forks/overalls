defmodule Marshall.Operations.PrivateFilesTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Operations.{PrivateFiles, Privacy}
  @moduletag :tmp_dir

  test "files are private and synced; links, permissive modes and unsafe parents are rejected", %{
    tmp_dir: dir
  } do
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "secret")
    assert :ok = PrivateFiles.with_new(path, &PrivateFiles.write_sync(&1, path, "test-only"))
    assert {:ok, "test-only"} = PrivateFiles.read(path)

    assert {:error, :output_exists} =
             PrivateFiles.with_new(path, fn _ -> flunk("must not replace") end)

    File.chmod!(path, 0o640)
    assert {:error, :unsafe_private_file} = PrivateFiles.read(path)
    File.chmod!(path, 0o600)
    link = Path.join(dir, "alias")
    File.ln!(path, link)
    assert {:error, :unsafe_private_file} = PrivateFiles.read(path)
    File.rm!(link)
    File.ln_s!(path, link)
    assert {:error, :unsafe_private_file} = PrivateFiles.read(link)

    assert {:error, :output_exists} =
             PrivateFiles.with_new(link, fn _ -> flunk("must not follow link") end)

    File.chmod!(dir, 0o777)
    assert {:error, :unsafe_private_file} = PrivateFiles.read(path)
  end

  test "failed sync is reported and an incomplete destination is retained", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "incomplete")

    assert {:error, :output_write_failed} =
             PrivateFiles.with_new(path, fn file ->
               :file.close(file)
               PrivateFiles.write_sync(file, path, "cannot write")
             end)

    assert File.regular?(path)
  end

  property "operator diagnostics cannot retain arbitrary credential payloads" do
    secret = draw("secret", binary(min_length: 1, max_length: 256))

    event = %{
      level: :error,
      msg: {:report, %{secret: secret}},
      meta: %{marshall_operator: true, secret: secret, event: :operator_test}
    }

    filtered = Privacy.filter(event, nil)
    assert filtered.msg == {:string, "Operator process diagnostic (payload redacted)"}
    assert filtered.meta == %{event: :operator_test}
  end
end
