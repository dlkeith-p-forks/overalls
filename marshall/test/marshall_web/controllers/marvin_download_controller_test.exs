defmodule MarshallWeb.MarvinDownloadControllerTest do
  use MarshallWeb.ConnCase

  alias MarshallWeb.MarvinDownloadController

  setup do
    previous = System.get_env("OVERALLS_MARVIN_RELEASE")

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_MARVIN_RELEASE", previous),
        else: System.delete_env("OVERALLS_MARVIN_RELEASE")
    end)

    :ok
  end

  test "public routes refuse missing releases without creating login state" do
    System.delete_env("OVERALLS_MARVIN_RELEASE")

    for path <- [
          "/bin/chrome.zip",
          "/bin/firefox.xpi",
          "/bin/marvin/manifest.json",
          "/bin/marvin/sha256/chrome.zip",
          "/bin/marvin/sha256/firefox.xpi"
        ] do
      conn = build_conn() |> get(path)
      assert response(conn, 404) == "Unavailable\n"
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  test "release selection rejects mutable paths and traversal beneath the store" do
    for root <- [
          "/tmp/browser",
          "/nix/store/../etc",
          "/nix/store/not-a-store-path",
          "/nix/store/" <> String.duplicate("a", 32) <> "-browser/../other"
        ] do
      System.put_env("OVERALLS_MARVIN_RELEASE", root)
      assert build_conn() |> get("/bin/chrome.zip") |> response(404) == "Unavailable\n"
      assert build_conn() |> get("/bin/marvin/manifest.json") |> response(404) == "Unavailable\n"
    end
  end

  test "artifact and checksum selectors are a closed allowlist" do
    for selector <- ["manifest.json", "chrome.zip/../secret", "Chrome.zip", "source.mjs", ""] do
      assert MarvinDownloadController.artifact(build_conn(), %{"artifact" => selector}).status ==
               404

      assert MarvinDownloadController.checksum(build_conn(), %{"artifact" => selector}).status ==
               404
    end

    assert build_conn() |> get("/bin/marvin/sha256/options.mjs") |> response(404) ==
             "Unavailable\n"
  end

  @tag :host
  test "immutable malformed releases refuse unsafe file shapes and mismatched lengths" do
    for kind <- [
          :missing_manifest,
          :invalid_manifest,
          :oversized_manifest,
          :manifest_symlink,
          :root_symlink
        ] do
      System.put_env("OVERALLS_MARVIN_RELEASE", store_fixture(kind))
      assert build_conn() |> get("/bin/chrome.zip") |> response(404) == "Unavailable\n"
      assert build_conn() |> get("/bin/marvin/manifest.json") |> response(404) == "Unavailable\n"

      assert build_conn() |> get("/bin/marvin/sha256/chrome.zip") |> response(404) ==
               "Unavailable\n"
    end

    for kind <- [:artifact_symlink, :bin_symlink, :length_mismatch, :empty_artifact] do
      System.put_env("OVERALLS_MARVIN_RELEASE", store_fixture(kind))
      assert build_conn() |> get("/bin/chrome.zip") |> response(404) == "Unavailable\n"
    end
  end

  @tag :host
  test "immutable package downloads agree with the public manifest and checksums" do
    root = System.fetch_env!("OVERALLS_MARVIN_RELEASE")
    conn = build_conn() |> get("/bin/marvin/manifest.json")
    manifest = conn |> response(200) |> Jason.decode!()
    assert manifest["version"] == 1
    assert manifest["extension_version"] == "0.1.0"
    assert manifest["unsigned"] == true
    assert get_resp_header(conn, "set-cookie") == []

    for {name, content_type} <- [
          {"chrome.zip", "application/zip"},
          {"firefox.xpi", "application/x-xpinstall"}
        ] do
      artifact = build_conn() |> get("/bin/" <> name)
      bytes = response(artifact, 200)
      expected = File.read!(Path.join([root, "bin", name]))
      digest = :crypto.hash(:sha256, expected) |> Base.encode16(case: :lower)
      assert bytes == expected
      assert manifest["artifacts"][name] == %{"sha256" => digest, "size" => byte_size(bytes)}
      assert get_resp_header(artifact, "content-type") == [content_type]

      assert get_resp_header(artifact, "content-disposition") == [
               ~s(attachment; filename="#{name}")
             ]

      assert get_resp_header(artifact, "set-cookie") == []

      assert build_conn() |> get("/bin/marvin/sha256/" <> name) |> response(200) ==
               digest <> "\n"
    end
  end

  @type fixture_kind ::
          :missing_manifest
          | :invalid_manifest
          | :oversized_manifest
          | :manifest_symlink
          | :root_symlink
          | :artifact_symlink
          | :bin_symlink
          | :length_mismatch
          | :empty_artifact

  # @cc [owner:ghuntley,label:verification;security] marvin-download-immutable-negative-fixtures
  # Negative fixtures MUST be newly authored temporary files imported into the
  # Nix store, never mutations of a selected package or production directory.
  # This opt-in host test requires a Nix daemon; it proves HTTP refusal of those
  # fixed file shapes, not signature validation or browser installation.
  @spec store_fixture(fixture_kind()) :: String.t()
  defp store_fixture(kind) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    directory = Path.join(System.tmp_dir!(), "overalls-marvin-download-" <> suffix)

    File.mkdir_p!(Path.join(directory, "bin"))
    on_exit(fn -> File.rm_rf!(directory) end)

    if kind == :bin_symlink do
      File.rename!(Path.join(directory, "bin"), Path.join(directory, "archives"))
      File.ln_s!("archives", Path.join(directory, "bin"))
    end

    bytes = "fixture"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    artifact = %{"sha256" => digest, "size" => byte_size(bytes)}

    manifest =
      Jason.encode!(%{
        "version" => 1,
        "unsigned" => true,
        "artifacts" => %{"chrome.zip" => artifact, "firefox.xpi" => artifact}
      })

    File.write!(Path.join(directory, "bin/firefox.xpi"), bytes)

    case kind do
      :artifact_symlink -> File.ln_s!("firefox.xpi", Path.join(directory, "bin/chrome.zip"))
      :length_mismatch -> File.write!(Path.join(directory, "bin/chrome.zip"), bytes <> "changed")
      :empty_artifact -> File.write!(Path.join(directory, "bin/chrome.zip"), "")
      _ -> File.write!(Path.join(directory, "bin/chrome.zip"), bytes)
    end

    case kind do
      :missing_manifest ->
        :ok

      :invalid_manifest ->
        File.write!(Path.join(directory, "manifest.json"), "[]")

      :oversized_manifest ->
        File.write!(Path.join(directory, "manifest.json"), String.duplicate(" ", 16_385))

      :manifest_symlink ->
        File.write!(Path.join(directory, "metadata.json"), manifest)
        File.ln_s!("metadata.json", Path.join(directory, "manifest.json"))

      _ ->
        File.write!(Path.join(directory, "manifest.json"), manifest)
    end

    input =
      if kind == :root_symlink do
        path = directory <> "-link"
        File.ln_s!(directory, path)
        on_exit(fn -> File.rm_rf!(path) end)
        path
      else
        directory
      end

    {output, 0} = System.cmd("nix-store", ["--add", input], stderr_to_stdout: true)
    root = String.trim(output)
    assert String.starts_with?(root, "/nix/store/")

    if kind == :root_symlink do
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(root)
    end

    root
  end
end
