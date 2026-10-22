defmodule MarshallArtifactsContractTest do
  use Covenant.Case, component: "marshall.artifacts"

  alias Marshall.Artifacts.{Edits, Paths, Tool}

  @tag obligation: "marshall.artifacts.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.Artifacts,
      Marshall.Artifacts.AccessChange,
      Marshall.Artifacts.Artifact,
      Marshall.Artifacts.Audit,
      Marshall.Artifacts.AuditEvent,
      Marshall.Artifacts.Authorization,
      Marshall.Artifacts.Blob,
      Marshall.Artifacts.Blobs,
      Marshall.Artifacts.Changes.ResumeStagedPublish,
      Marshall.Artifacts.Edits,
      Marshall.Artifacts.ExpiryJob,
      Marshall.Artifacts.Grant,
      Marshall.Artifacts.Library,
      Marshall.Artifacts.Limits,
      Marshall.Artifacts.Manifest,
      Marshall.Artifacts.Markdown,
      Marshall.Artifacts.PageHelper,
      Marshall.Artifacts.Paths,
      Marshall.Artifacts.Publisher,
      Marshall.Artifacts.PublishRequest,
      Marshall.Artifacts.PurgeJob,
      Marshall.Artifacts.Sharing,
      Marshall.Artifacts.Staging,
      Marshall.Artifacts.Storage,
      Marshall.Artifacts.StorageEntry,
      Marshall.Artifacts.StorageUsage,
      Marshall.Artifacts.SweepJob,
      Marshall.Artifacts.Tickets,
      Marshall.Artifacts.Tool,
      Marshall.Artifacts.UsageReconcileJob,
      Marshall.Artifacts.Version,
      Marshall.Artifacts.VersionFile,
      Marshall.Artifacts.ViewTicket
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.artifacts.I2"
  test "edits apply all or none" do
    assert Edits.apply("abc", [%{old_str: "a", new_str: "x"}, %{old_str: "c", new_str: "z"}]) ==
             {:ok, "xbz"}

    assert Edits.apply("abc", [%{old_str: "a", new_str: "x"}, %{old_str: "q", new_str: "z"}]) ==
             {:error, :edit_not_found, %{index: 1}}

    assert Edits.apply("aa", [%{old_str: "a", new_str: "x"}]) ==
             {:error, :edit_ambiguous, %{index: 0}}
  end

  @tag obligation: "marshall.artifacts.I3"
  test "paths are normalized without traversal" do
    assert {:ok, "a/b.css"} = Paths.normalize("./a/b.css")
    assert {:error, _} = Paths.normalize("a//b.css")
    assert {:error, _} = Paths.normalize("/abs.css")
    assert {:error, _} = Paths.normalize("../etc/passwd")
    assert {:error, _} = Paths.normalize("a\\b")
    assert {_, :attachment} = Paths.media_type("payload.exe")
  end

  @tag obligation: "marshall.artifacts.I4"
  test "tool requests are closed" do
    assert {:ok, _} =
             Tool.parse(%{"operation" => "publish", "base_version" => 0, "content" => "<p>x</p>"})

    assert {:error, _} = Tool.parse(%{"operation" => "publish", "content" => "<p>x</p>"})

    assert {:error, _} =
             Tool.parse(%{
               "operation" => "publish",
               "base_version" => 1,
               "content" => "x",
               "edits" => [%{"old_str" => "a", "new_str" => "b"}]
             })

    assert {:error, _} = Tool.parse(%{"operation" => "drop"})
    assert {:error, _} = Tool.parse(%{"operation" => "list", "extra" => 1})

    assert {:error, _} =
             Tool.parse(%{
               "operation" => "publish",
               "base_version" => 0,
               "content_path" => "relative.html"
             })
  end

  @tag obligation: "marshall.artifacts.I5"
  test "content responses carry the lockdown header set" do
    headers = Map.new(MarshallWeb.ArtifactContentHeaders.headers("content.test", "marshall.test"))
    csp = headers["content-security-policy"]

    assert csp =~ "sandbox allow-scripts;"
    refute csp =~ "allow-same-origin"
    assert csp =~ "connect-src 'none'"
    assert csp =~ "frame-ancestors https://marshall.test"
    assert headers["cross-origin-opener-policy"] == "same-origin"
    assert headers["cross-origin-embedder-policy"] == "require-corp"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["referrer-policy"] == "no-referrer"
    assert headers["cache-control"] == "private, no-store"
    refute Map.has_key?(headers, "set-cookie")
  end
end
