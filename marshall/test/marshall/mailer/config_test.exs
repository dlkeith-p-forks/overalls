defmodule Marshall.Mailer.ConfigTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Accounts.EmailAddress
  alias Marshall.Mailer.Config

  test "local relay is explicit, literal-loopback-only and never sends upstream credentials" do
    local =
      env("implicit")
      |> Map.put("MARSHALL_MAIL_TRANSPORT", "local_relay")
      |> Map.put("MARSHALL_SMTP_HOST", "127.0.0.1")

    assert {:ok, config, _} = Config.from_env(local)
    assert config[:port] == 2525
    assert config[:auth] == :never
    assert config[:tls] == :never
    refute config[:ssl]
    refute Keyword.has_key?(config, :password)
    refute Keyword.has_key?(config, :username)

    for host <- ["localhost", "::1", "127.0.0.2", "0.0.0.0", "smtp.example.test", nil] do
      assert {:error, :invalid_mail_configuration} =
               Config.from_env(Map.put(local, "MARSHALL_SMTP_HOST", host))
    end

    for change <- [
          %{"MARSHALL_MAIL_TRANSPORT" => "unknown"},
          %{"MARSHALL_SMTP_PORT" => "0"},
          %{"MARSHALL_SMTP_PORT" => "not-a-port"},
          %{"MARSHALL_MAIL_FROM" => "invalid"}
        ] do
      assert {:error, :invalid_mail_configuration} = Config.from_env(Map.merge(local, change))
    end

    assert {:error, :invalid_mail_configuration} =
             Config.from_env(
               local
               |> Map.delete("MARSHALL_MAIL_TRANSPORT")
               |> Map.delete("MARSHALL_SMTP_PASSWORD")
             )
  end

  property "untrusted mailbox suffixes cannot inject SMTP commands or HTML delimiters" do
    check all(
            prefix <- string(:alphanumeric, min_length: 1, max_length: 30),
            suffix <-
              member_of(["\r\nRCPT TO:<other@example.test>", "\n", "\0", "<", ">", "\"", ","])
          ) do
      value = prefix <> suffix <> "@example.test"
      refute EmailAddress.valid?(value)
    end
  end

  test "both TLS modes verify certificates and hostnames, with no transport-level retries" do
    for mode <- ["implicit", "starttls"] do
      assert {:ok, config, {"Overalls", "noreply@example.test"}} = Config.from_env(env(mode))
      assert config[:auth] == :always
      assert config[:retries] == 0
      assert config[:no_mx_lookups]
      assert config[:timeout] == 3000
      tls = if mode == "implicit", do: config[:sockopts], else: config[:tls_options]
      assert tls[:verify] == :verify_peer
      assert tls[:server_name_indication] == ~c"localhost"
      assert tls[:versions] == [:"tlsv1.2", :"tlsv1.3"]
      assert config[:tls] == if(mode == "implicit", do: :never, else: :always)
    end
  end

  test "missing credentials, insecure modes and invalid addresses fail without echoing secrets" do
    valid = env("implicit")

    invalid =
      for key <- [
            "MARSHALL_SMTP_HOST",
            "MARSHALL_SMTP_USERNAME",
            "MARSHALL_SMTP_PASSWORD",
            "MARSHALL_MAIL_FROM"
          ],
          do: Map.delete(valid, key)

    invalid =
      invalid ++
        [
          Map.put(valid, "MARSHALL_SMTP_TLS", "never"),
          Map.put(valid, "MARSHALL_SMTP_PORT", "0"),
          Map.put(valid, "MARSHALL_MAIL_FROM", "bad\r\n@example.test")
        ]

    for config <- invalid do
      assert {:error, :invalid_mail_configuration} = Config.from_env(config)
    end
  end

  test "production SSL policy ignores spoofed forwarding headers" do
    config = Elixir.Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
    options = config[:marshall][MarshallWeb.Endpoint][:force_ssl]

    for host <- ["marshall.example.test", "localhost", "127.0.0.1"] do
      conn =
        Plug.Test.conn(:get, "http://#{host}/machines")
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Plug.SSL.call(Plug.SSL.init(options))

      assert conn.halted
      assert conn.status == 301
    end
  end

  test "production SSL redirects do not log magic-link paths before privacy tagging" do
    config = Elixir.Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
    options = config[:marshall][MarshallWeb.Endpoint][:force_ssl]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          Plug.Test.conn(:get, "http://marshall.example.test/magic_link/private-token-marker")

        redirected = Plug.SSL.call(conn, Plug.SSL.init(options))
        assert redirected.halted
        assert redirected.status == 301

        assert Plug.Conn.get_resp_header(redirected, "location") ==
                 ["https://marshall.example.test/magic_link/private-token-marker"]
      end)

    refute log =~ "private-token-marker"
  end

  defp env(mode),
    do: %{
      "MARSHALL_SMTP_HOST" => "localhost",
      "MARSHALL_SMTP_TLS" => mode,
      "MARSHALL_SMTP_USERNAME" => "test-user",
      "MARSHALL_SMTP_PASSWORD" => "test-password",
      "MARSHALL_MAIL_FROM" => "noreply@example.test"
    }
end
