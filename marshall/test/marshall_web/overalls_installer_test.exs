defmodule MarshallWeb.OverallsInstallerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias MarshallWeb.OverallsInstaller

  @policy %{
    "version" => 1,
    "ca" => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "management_host" => "control.example.test",
    "zone" => "apps.example.test",
    "retirement" => 2_421_446_400
  }

  test "only validated deployment policy renders an executable installer" do
    assert :error = OverallsInstaller.render("control.example.test", nil)
    assert :error = OverallsInstaller.render("other.example.test", @policy)

    for field <- ["management_host", "zone", "ca"] do
      assert :error =
               OverallsInstaller.render("control.example.test", Map.put(@policy, field, "$(id)"))
    end

    assert {:ok, script} = OverallsInstaller.render("control.example.test", @policy)
    assert {"", 0} = System.cmd("bash", ["-n", "-c", script])
    refute script =~ "ssh-keyscan"
    assert script =~ "config-ssh --origin"
    assert script =~ "exec ssh \"$host\" </dev/tty"
  end

  test "origin, zone and target mismatches fail before filesystem mutation" do
    {:ok, script} = OverallsInstaller.render("control.example.test", @policy)
    root = Path.join(System.tmp_dir!(), "ssh-ca-installer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for arguments <- [
          ["https://other.example.test", "apps.example.test", "vm.apps.example.test"],
          ["https://control.example.test", "other.test", "vm.other.test"],
          ["https://control.example.test", "apps.example.test", "vm.attacker.test"]
        ] do
      assert {_, 1} =
               System.cmd("bash", ["-c", script, "installer" | arguments],
                 env: [{"HOME", root}],
                 stderr_to_stdout: true
               )

      assert File.ls!(root) == []
    end
  end

  property "generated deployment mismatches and malformed CA policies cannot render installers" do
    check all(label <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      other = String.downcase(label) <> ".other.test"
      assert :error = OverallsInstaller.render(other, @policy)

      assert :error =
               OverallsInstaller.render("control.example.test", Map.put(@policy, "ca", label))

      for field <- ["management_host", "zone"] do
        policy = Map.put(@policy, field, "$(" <> label <> ")")
        assert :error = OverallsInstaller.render("control.example.test", policy)
      end
    end
  end
end
