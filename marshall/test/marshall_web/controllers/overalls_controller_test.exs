defmodule MarshallWeb.OverallsControllerTest do
  use MarshallWeb.ConnCase

  setup do
    previous = Application.fetch_env(:marshall, :ssh_host_trust)

    Application.put_env(
      :marshall,
      :ssh_host_trust,
      %{
        "version" => 1,
        "ca" =>
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "management_host" => "localhost",
        "zone" => "apps.example.test",
        "retirement" => 2_421_446_400
      }
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :ssh_host_trust, value)
        :error -> Application.delete_env(:marshall, :ssh_host_trust)
      end
    end)
  end

  test "missing deployment trust disables the installer" do
    Application.delete_env(:marshall, :ssh_host_trust)
    conn = build_conn() |> get("/bin/install.sh")
    assert response(conn, 503) == "Installer trust unavailable\n"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "public installer pins downloads and keeps the final SSH interactive" do
    conn = build_conn() |> get("/bin/install.sh")
    script = response(conn, 200)
    assert script =~ "set -euo pipefail"
    assert script =~ "management_host='localhost'"
    assert script =~ "deployment_zone='apps.example.test'"
    assert script =~ "/bin/$target"
    assert script =~ "/bin/sha256/$target"
    assert script =~ ~s([ "$actual" = "$expected" ])
    assert script =~ "exec ssh \"$host\" </dev/tty"
    assert {"", 0} = System.cmd("bash", ["-n", "-c", script])
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "missing deployment trust disables the PowerShell installer" do
    Application.delete_env(:marshall, :ssh_host_trust)
    conn = build_conn() |> get("/bin/install.ps1")
    assert response(conn, 503) == "Installer trust unavailable\n"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "PowerShell installer is deployment bound, verifies the digest and gates OpenSSH 9.6" do
    conn = build_conn() |> get("/bin/install.ps1")
    script = response(conn, 200)
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
    assert script =~ "$ManagementHost = 'localhost'"
    assert script =~ "$GuestZone = 'apps.example.test'"
    refute script =~ "@OVERALLS_"
    assert script =~ "$Target = 'windows-amd64'"
    assert script =~ ~s("$Origin/bin/sha256/$Target")
    assert script =~ "Get-FileHash -Algorithm SHA256"
    assert script =~ "if ($Actual -cne $Expected) { Fail 'Binary checksum mismatch' }"
    assert script =~ "-G 'invalid;hostname'"
    assert script =~ "winget.exe install --id Microsoft.OpenSSH.Preview"
    assert script =~ "config-ssh --origin $Origin --zone $Zone --ssh $Ssh --staged-installer"
    assert script =~ "& $Installed ssh $Machine"
  end

  test "artifact selector cannot traverse the package" do
    for path <- ["/bin/Cargo.toml", "/bin/sha256/Cargo.toml"] do
      assert build_conn() |> get(path) |> response(404) == "Unavailable\n"
    end
  end
end
