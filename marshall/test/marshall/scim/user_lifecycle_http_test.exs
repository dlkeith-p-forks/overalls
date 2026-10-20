defmodule Marshall.Scim.UserLifecycleHttpTest do
  @moduledoc "SCIM /Users lifecycle through MarshallWeb.Endpoint with a real bearer token."
  use MarshallWeb.ConnCase, async: false
  use Oban.Testing, repo: Marshall.Repo
  import Marshall.ScimUserFixture

  alias Marshall.Accounts.{AccountLifecycle, Login, Security}
  alias Marshall.Scim.RetirementWorker

  setup do
    %{scim: enable!()}
  end

  test "requests without the configured bearer token are refused", %{scim: scim} do
    assert {401, _} = request(%{scim | token: "scim_wrong"}, :get, "/Users")
    assert {200, %{"Resources" => _}} = request(scim, :get, "/Users")
  end

  test "create provisions an active identity visible to GET and list", %{scim: scim} do
    assert {201, %{"id" => id, "active" => true, "userName" => email}} = create_user(scim)
    assert {200, %{"id" => ^id, "active" => true}} = get_user(scim, id)
    assert {200, %{"Resources" => resources}} = request(scim, :get, "/Users")
    assert Enum.any?(resources, &(&1["id"] == id and &1["userName"] == email))

    refute Enum.any?(resources, &(&1["userName"] == "scim-service-owner@deleted.invalid")),
           "the internal service owner is not a directory user"
  end

  test "PATCH active=false starts the grace period and revokes logins at once", %{scim: scim} do
    user = create_user!(scim)
    {login, _} = Marshall.PasskeyFixture.login(user)
    jti = Security.jti(login)
    assert {:ok, _} = Login.present(jti, user.id)

    assert {200, %{"active" => false}} = set_active(scim, user.id, false)

    retired = user!(user.id)
    refute retired.active
    assert is_nil(retired.deleted_at)
    grace = Marshall.Accounts.ScimRetirement.grace_seconds()
    assert grace == 7 * 24 * 60 * 60
    remaining = DateTime.diff(retired.scim_retirement_deadline, DateTime.utc_now())
    assert remaining > grace - 120 and remaining <= grace

    assert :error == Login.present(jti, user.id)
    assert %{kind: :scim_retirement, state: :scheduled} = deletion(user.id)
    assert_enqueued(worker: RetirementWorker, args: %{"user_id" => user.id})

    # A deactivated identity is still a SCIM resource: GET shows it inactive.
    assert {200, %{"active" => false}} = get_user(scim, user.id)

    # Repeating the deactivation never extends the original deadline.
    assert {200, _} = set_active(scim, user.id, false)
    assert user!(user.id).scim_retirement_deadline == retired.scim_retirement_deadline
  end

  test "DELETE is a soft retirement and the user is then gone from SCIM", %{scim: scim} do
    user = create_user!(scim)
    {login, _} = Marshall.PasskeyFixture.login(user)

    assert {204, nil} = delete_user(scim, user.id)

    retired = user!(user.id)
    assert retired, "the row and UUID survive a SCIM DELETE"
    refute retired.active
    assert retired.scim_deleted_at
    assert retired.scim_retirement_deadline
    assert is_nil(retired.deleted_at)
    assert :error == Login.present(Security.jti(login), user.id)
    assert %{kind: :scim_retirement, state: :scheduled} = deletion(user.id)

    assert {404, _} = get_user(scim, user.id)
    assert {200, %{"Resources" => resources}} = request(scim, :get, "/Users")
    refute Enum.any?(resources, &(&1["id"] == user.id))
  end

  test "reactivation inside the grace period cancels the scheduled deletion", %{scim: scim} do
    user = create_user!(scim)
    assert {200, _} = set_active(scim, user.id, false)
    assert {200, %{"active" => true}} = set_active(scim, user.id, true)

    live = user!(user.id)
    assert live.active
    assert is_nil(live.scim_retirement_deadline)
    assert %{state: :cancelled} = deletion(user.id)
    assert {:ok, :resumed} = Marshall.Accounts.ScimRetirement.reconcile(user.id)

    # A later deactivation reschedules the same durable deletion.
    assert {200, _} = set_active(scim, user.id, false)
    assert %{state: :scheduled, kind: :scim_retirement} = deletion(user.id)
  end

  test "a SCIM-deleted user is restored by active=true inside the grace period", %{scim: scim} do
    user = create_user!(scim)
    assert {204, nil} = delete_user(scim, user.id)
    assert {200, %{"active" => true}} = set_active(scim, user.id, true)
    assert {200, %{"active" => true}} = get_user(scim, user.id)
    assert is_nil(user!(user.id).scim_deleted_at)
  end

  test "after the deadline reactivation is refused and the identity is finalized", %{
    scim: scim
  } do
    user = create_user!(scim, external_id: "ext-final-" <> unique_name())
    email = to_string(user.email)
    assert {204, nil} = delete_user(scim, user.id)
    expire!(user.id)

    assert {400, _} = set_active(scim, user.id, true)
    refute user!(user.id).active

    assert :ok = perform_job(RetirementWorker, %{"user_id" => user.id})

    final = user!(user.id)
    assert final.id == user.id
    assert to_string(final.email) == "deleted-#{user.id}@deleted.invalid"
    assert final.deleted_at
    refute final.active
    assert is_nil(final.scim_external_id)
    assert %{state: :completed, completed_at: %DateTime{}, email: receipt} = deletion(user.id)
    assert to_string(receipt) == email

    # The finalized UUID can never be written or reactivated again.
    assert {404, _} = get_user(scim, user.id)
    assert {400, _} = set_active(scim, user.id, true)
    assert {400, _} = delete_user(scim, user.id)

    assert {400, _} =
             request(scim, :put, "/Users/" <> user.id, %{"userName" => email, "active" => true})

    refute user!(user.id).active

    # Directory re-provisioning of the same mailbox gets a fresh identity.
    assert {201, %{"id" => fresh}} =
             create_user(scim, name: String.replace(email, "@example.test", ""))

    refute fresh == user.id
    assert to_string(user!(user.id).email) == "deleted-#{user.id}@deleted.invalid"
  end

  test "sign-in and owned-work admission are refused for an inactive identity", %{scim: scim} do
    user = create_user!(scim)
    assert {200, _} = set_active(scim, user.id, false)

    {login, _} = Marshall.PasskeyFixture.login(user!(user.id))
    assert :error == Login.present(Security.jti(login), user.id)

    assert {:error, _} =
             Marshall.Compute.Ledger.transaction(fn -> AccountLifecycle.admit!(user.id) end)
  end
end
