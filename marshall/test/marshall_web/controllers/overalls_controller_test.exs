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

  # @cc [owner:ghuntley,label:verification] localized-http-refusal-machine-bytes
  # Negotiated human refusals MUST retain status, newline and privacy boundaries;
  # successful installer and trust-policy bytes MUST remain locale independent.
  test "Arabic and Japanese refusals retain transport and privacy contracts" do
    for {locale, unavailable} <- [{"ar", "غير متاح"}, {"ja", "利用不可"}] do
      for path <- ["/bin/Cargo.toml", "/bin/sha256/Cargo.toml", "/bin/marvin/sha256/invalid"] do
        conn = build_conn() |> put_req_header("accept-language", locale) |> get(path)
        assert response(conn, 404) == unavailable <> "\n"
        assert get_resp_header(conn, "content-language") == [locale]
        assert get_resp_header(conn, "set-cookie") == []
      end

      missing_docs = if locale == "ar", do: "لم يتم العثور على الوثائق", else: "ドキュメントが見つかりません"

      docs =
        build_conn() |> put_req_header("accept-language", locale) |> get("/docs/missing-page")

      assert response(docs, 404) == missing_docs <> "\n"
      assert get_resp_header(docs, "content-language") == [locale]
      assert get_resp_header(docs, "set-cookie") == []

      for path <- ["/usage/export", "/git/github/missing/missing/raw?path=x"] do
        conn = build_conn() |> put_req_header("accept-language", locale) |> get(path)
        assert response(conn, 404) == unavailable
        assert get_resp_header(conn, "content-language") == [locale]
        assert get_resp_header(conn, "cache-control") in [["no-store"], ["private, no-store"]]
      end

      conn =
        build_conn()
        |> put_req_header("accept-language", locale)
        |> get("/editor/authorize/invalid")

      assert response(conn, 404) == unavailable <> "\n"
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      refute get_session(conn, :return_to)
    end
  end

  test "negotiation leaves executable installers and JSON trust policy byte identical" do
    for path <- ["/bin/install.sh", "/bin/install.ps1", "/bin/ssh-trust.json"] do
      english = build_conn() |> put_req_header("accept-language", "en") |> get(path)
      expected = response(english, 200)

      for locale <- ["ar", "ja"] do
        conn = build_conn() |> put_req_header("accept-language", locale) |> get(path)
        assert response(conn, 200) == expected
        assert get_resp_header(conn, "content-language") == [locale]
        assert get_resp_header(conn, "set-cookie") == []
        assert get_resp_header(conn, "cache-control") == ["no-store"]
      end
    end
  end

  test "repository launch guidance is localized without storing invalid input" do
    for {locale, message} <- [
          {"ar", "تعذّر التشغيل من رابط المستودع هذا. افتح الرابط مرة أخرى."},
          {"ja", "このリポジトリリンクから起動できませんでした。リンクをもう一度開いてください。"}
        ] do
      conn = build_conn() |> put_req_header("accept-language", locale)
      conn = post(conn, "/launch/pending", %{"source" => "invalid", "visit" => "invalid"})
      assert response(conn, 422) == message <> "\n"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      refute get_session(conn, MarshallWeb.PendingLaunch.key())
    end
  end

  test "localized trust failures preserve service status and never return installer bytes" do
    Application.delete_env(:marshall, :ssh_host_trust)

    for {locale, installer, ssh} <- [
          {"ar", "التحقق من موثوقية برنامج التثبيت غير متاح", "التحقق من موثوقية SSH غير متاح"},
          {"ja", "インストーラーの信頼性を確認できません", "SSHの信頼性を確認できません"}
        ] do
      for path <- ["/bin/install.sh", "/bin/install.ps1"] do
        conn = build_conn() |> put_req_header("accept-language", locale) |> get(path)
        assert response(conn, 503) == installer <> "\n"
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert get_resp_header(conn, "set-cookie") == []
      end

      conn =
        build_conn() |> put_req_header("accept-language", locale) |> get("/bin/ssh-trust.json")

      assert response(conn, 503) == ssh <> "\n"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end
  end
end
