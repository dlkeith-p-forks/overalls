defmodule MarshallWeb.AdminAuditLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.Compute.Ledger

  test "audit is available to signed-in users and shows redacted events", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/audit")

    admin = user(true)

    assert Marshall.Authorization.Cedar.allowed?(
             admin,
             "admin_read",
             Marshall.Authorization.Cedar.entity("ControlPlane", "marshall")
           )

    actor_id = admin.id
    target_id = Ash.UUID.generate()

    Ledger.create!(AdminEvent, :record, %{
      actor_id: actor_id,
      target_id: target_id,
      kind: :evacuation_control
    })

    assert {:ok, %{items: [%{kind: :evacuation_control}]}} =
             Marshall.Accounts.admin_events(%{before: nil, limit: 100}, actor: admin)

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/audit")
    assert has_element?(view, "#audit-events", "evacuation_control")
    assert has_element?(view, "#audit-events", actor_id)
    assert has_element?(view, "#audit-events", target_id)
    refute render(view) =~ "secret"
  end

  test "lifecycle history filters by VM and renders only the redacted projection", %{conn: conn} do
    admin = user(true)
    vm = Ash.UUID.generate()
    now = Ledger.now()

    for {id, action} <- [{vm, "request_stop"}, {Ash.UUID.generate(), "request_delete"}] do
      Ledger.create!(Marshall.Compute.LifecycleEvent, :record, %{
        actor_kind: :user,
        actor_id: admin.id,
        resource_type: "VirtualMachine",
        resource_id: id,
        vm_id: id,
        action: action,
        previous_state: "running",
        next_state: "stopped",
        occurred_at: now,
        expires_at: DateTime.add(now, 90, :day)
      })
    end

    {:ok, view, _} =
      live(signed_in(conn, admin), ~p"/admin/audit?#{%{kind: "lifecycle", vm_id: vm}}")

    assert has_element?(view, "#audit-events", "request_stop")
    refute has_element?(view, "#audit-events", "request_delete")
    assert has_element?(view, "input[name=vm_id][value='#{vm}']")
    assert has_element?(view, "#audit-events", "running")
  end

  test "certificate audit shows state history without account or certificate keys", %{conn: conn} do
    admin = user(true)
    account_secret = "account-secret-" <> Base.encode64(:crypto.strong_rand_bytes(32))
    request_secret = "request-secret-" <> Base.encode64(:crypto.strong_rand_bytes(32))

    Ledger.create!(Marshall.Ingress.FleetCertificateAccount, :register, %{
      issuer_url: "https://ca.example.test/directory",
      thumbprint: String.duplicate("a", 43),
      private_key: account_secret
    })

    attempted_at = Ledger.now()

    Marshall.Ingress.FleetCertificate
    |> Ledger.create!(:enqueue, %{generation: 1, zone: "apps.example.test"})
    |> Ledger.update!(:save_request, %{
      csr_der: :crypto.strong_rand_bytes(64),
      private_key_pem: request_secret,
      csr_fingerprint: String.duplicate("b", 64)
    })
    |> Ledger.update!(:mark_order_attempt, %{order_attempted_at: attempted_at})

    assert {:ok, %{uncertain_order: %{generation: 1, retry_after: retry_after}}} =
             Marshall.Ingress.certificate_audit(%{}, actor: admin)

    assert retry_after == DateTime.add(attempted_at, 3600)
    assert {:ok, _} = Marshall.Ingress.certificate_audit(%{}, actor: user(false))

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/audit?kind=certificates")
    rendered = render(view)

    assert has_element?(view, "#audit-events", "Generation 1")
    assert has_element?(view, "#audit-events", "ACME account")
    assert has_element?(view, "#uncertain-fleet-order", "Generation 1")
    assert has_element?(view, "#uncertain-fleet-order", "next due check")
    refute rendered =~ account_secret
    refute rendered =~ request_secret
    refute rendered =~ "ca.example.test"
  end

  test "elevated administrator can request an audited wildcard rotation", %{conn: conn} do
    zone = "apps.example.test"
    old_zone = Application.get_env(:marshall, :ingress_zone)
    old_acme = Application.get_env(:marshall, :fleet_acme)
    Application.put_env(:marshall, :ingress_zone, zone)
    Application.put_env(:marshall, :fleet_acme, %{zone: zone})

    on_exit(fn ->
      restore_env(:ingress_zone, old_zone)
      restore_env(:fleet_acme, old_acme)
    end)

    admin = user(true)
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/audit?kind=certificates")
    assert has_element?(view, "#rotate-fleet-certificate")
    refute has_element?(view, "#uncertain-fleet-order")
    assert render_click(element(view, "#rotate-fleet-certificate")) =~ "Generation 1"
    assert has_element?(view, "#audit-events", "enqueue")
    assert [%{kind: :fleet_certificate_rotate}] = Ledger.read!(AdminEvent)
  end

  @spec restore_env(atom(), term()) :: :ok
  defp restore_env(key, nil), do: Application.delete_env(:marshall, key)
  defp restore_env(key, value), do: Application.put_env(:marshall, key, value)

  defp user(admin),
    do:
      Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: admin})

  defp signed_in(conn, user) do
    user = if user.administrator, do: Marshall.PasskeyFixture.verified_session(user), else: user

    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
