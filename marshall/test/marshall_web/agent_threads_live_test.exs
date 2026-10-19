defmodule MarshallWeb.AgentThreadsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Agents.{Event, Root, Thread, Turn}
  alias Marshall.Compute.{Ledger}

  setup do
    host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    %{owner: owner, vm: vm, thread: thread}
  end

  test "owner opens root, submits prompt and creates a child", c do
    {:ok, view, _} = live(signed_in(c.conn, c.owner), ~p"/machines/#{c.vm.id}/threads")
    assert has_element?(view, "#agent-prompt-form")
    assert has_element?(view, "#child-thread-form")

    view
    |> form("#agent-prompt-form", prompt: %{text: "Inspect the project"})
    |> render_submit()

    assert [%{prompt: "Inspect the project"}] = Ledger.read!(Turn, thread_id: c.thread.id)
    assert has_element?(view, "#agent-events article", "Inspect the project")

    view |> form("#child-thread-form", child: %{title: "Investigate"}) |> render_submit()
    assert_redirect(view)
    assert length(Ledger.read!(Thread, parent_thread_id: c.thread.id)) == 1
  end

  test "unshared user cannot see a thread by guessing its URL", c do
    stranger = user()

    assert {:error, {:live_redirect, %{to: "/machines"}}} =
             live(signed_in(c.conn, stranger), ~p"/machines/#{c.vm.id}/threads/#{c.thread.id}")
  end

  test "capability denial explains the failed turn to the thread reader", c do
    Ledger.create!(Event, :append, %{
      thread_id: c.thread.id,
      sequence: c.thread.next_event_sequence,
      kind: :turn_failed,
      body: %{"reason" => "capability_denied"}
    })

    {:ok, view, _} = live(signed_in(c.conn, c.owner), ~p"/machines/#{c.vm.id}/threads")

    assert has_element?(
             view,
             "#agent-events article",
             "This tool is not available for the machine profile."
           )
  end

  test "browser locale translates event headings while prompt payload stays literal", c do
    literal = "context_captured — user supplied text"

    Ledger.create!(Event, :append, %{
      thread_id: c.thread.id,
      sequence: c.thread.next_event_sequence,
      kind: :prompt,
      body: %{"prompt" => literal}
    })

    conn = c.conn |> put_req_header("accept-language", "ja") |> signed_in(c.owner)
    {:ok, view, _} = live(conn, ~p"/machines/#{c.vm.id}/threads")

    assert has_element?(view, "#agent-events article strong", "プロンプト")
    assert has_element?(view, "#agent-events article pre", literal)
    refute has_element?(view, "#agent-events article strong", "prompt")
  end

  test "a thread URL cannot be combined with a different machine path", c do
    {:ok, other_vm} = Marshall.Compute.provision(request(), actor: c.owner)
    [other_root] = Ledger.read!(Root, vm_id: other_vm.id)
    [other_thread] = Ledger.read!(Thread, root_id: other_root.id)

    assert {:error, {:live_redirect, %{to: "/machines"}}} =
             live(
               signed_in(c.conn, c.owner),
               ~p"/machines/#{c.vm.id}/threads/#{other_thread.id}"
             )
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
