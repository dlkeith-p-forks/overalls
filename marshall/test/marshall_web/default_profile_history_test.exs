defmodule MarshallWeb.DefaultProfileHistoryTest do
  use MarshallWeb.ConnCase, async: false
  use ExUnitProperties
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Ledger, Operation, Reservation, VirtualMachine}

  @typep selection :: nil | :oss | :customer | :standard

  # @cc [owner:ghuntley,label:verification;product] browser-profile-draft-oracle
  # Omitted profiles MUST start as OSS. Generated explicit choices, refreshes and
  # reloads MUST preserve the last choice and request identity through admission;
  # replaying the same URL MUST create no additional VM, reservation or operation.
  property "profile drafts survive refresh and reload before duplicate submission", %{conn: conn} do
    check all(
            initial <- member_of([nil, :oss, :customer, :standard]),
            changes <-
              list_of(member_of([:refresh, :reload, :oss, :customer, :standard]), max_length: 8),
            max_runs: 16
          ) do
      fixture = host_fixture()
      owner = user()
      conn = signed_in(conn, owner)
      key = Ash.UUID.generate()

      values = %{
        "request_key" => key,
        "vcpu" => "1",
        "memory_mib" => "512",
        "disk_gib" => "2",
        "image_id" => image_id()
      }

      values = if initial, do: Map.put(values, "profile", Atom.to_string(initial)), else: values
      url = "/machines/new?" <> Plug.Conn.Query.encode(%{"machine" => values})
      {:ok, view, _} = live(conn, url)
      expected = expected_profile(initial)
      assert has_element?(view, "#machine_profile option[selected][value='#{expected}']")

      {view, url, expected} =
        Enum.reduce(changes ++ [:refresh, :reload], {view, url, expected}, fn
          :refresh, {view, url, expected} ->
            send(view.pid, :refresh)
            assert has_element?(view, "#machine_profile option[selected][value='#{expected}']")
            {view, url, expected}

          :reload, {view, url, expected} ->
            GenServer.stop(view.pid)
            {:ok, reloaded, _} = live(conn, url)

            assert has_element?(
                     reloaded,
                     "#machine_profile option[selected][value='#{expected}']"
                   )

            {reloaded, url, expected}

          profile, {view, _url, _expected} ->
            view
            |> form("#provision-form", machine: %{profile: Atom.to_string(profile)})
            |> render_change()

            {view, assert_patch(view), Atom.to_string(profile)}
        end)

      assert has_element?(view, "#machine_request_key[value='#{key}']")
      Ledger.update!(fixture.host, :report, %{reported_at: Ledger.now()})
      view |> form("#provision-form", machine: %{}) |> render_submit()
      assert [%{id: id, profile: profile}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
      assert Atom.to_string(profile) == expected
      assert_redirect(view, "/machines/#{id}")

      {:ok, replay, _} = live(conn, url)
      replay |> form("#provision-form", machine: %{}) |> render_submit()
      assert_redirect(replay, "/machines/#{id}")
      assert [%{id: ^id}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
      assert length(Ledger.read!(Reservation, vm_id: id)) == 1
      assert length(Ledger.read!(Operation, vm_id: id)) == 1
    end
  end

  @spec expected_profile(selection()) :: String.t()
  defp expected_profile(nil), do: "oss"
  defp expected_profile(profile), do: Atom.to_string(profile)

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
