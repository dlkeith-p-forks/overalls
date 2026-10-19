defmodule MarshallNotificationsContractTest do
  use Covenant.Case, component: "marshall.notifications", async: false
  import Marshall.ComputeFixtures
  alias Marshall.{Compute, Notifications, SSH}
  alias Marshall.Agents.{Planning, Root, Thread, Turn}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Delivery, DeliveryWorker, Device, Susan}
  alias OverallsProtocol.{PushPoke, SusanPoke}
  require Ash.Query
  @moduletag capture_log: true

  @route "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"

  setup tags do
    :ok = Marshall.DataCase.setup_sandbox(tags)
    on_exit(fn -> Application.delete_env(:marshall, :notifications_enabled) end)
    :ok
  end

  @tag obligation: "marshall.notifications.I1"
  test "the Susan origin is compiled and only the test branch reads configuration" do
    assert Susan.production_origin() == "https://notifications.overalls.dev"
    previous = Application.get_env(:marshall, Susan)

    try do
      Application.put_env(:marshall, Susan, [])
      assert Susan.origin() == "https://notifications.overalls.dev"
    after
      Application.put_env(:marshall, Susan, previous)
    end

    # Every configuration read sits inside `if Mix.env() == :test`.
    source = File.read!(Path.expand("../../../lib/marshall/notifications/susan.ex", __DIR__))
    ast = Code.string_to_quoted!(source)

    {_, outside} =
      Macro.prewalk(ast, 0, fn
        {:if, _, [{:==, _, [{{:., _, [{:__aliases__, _, [:Mix]}, :env]}, _, []}, :test]} | _]},
        count ->
          {nil, count}

        {{:., _, [{:__aliases__, _, [:Application]}, _]}, _, _} = node, count ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    assert outside == 0
    assert source =~ ~s(@origin "https://notifications.overalls.dev")
  end

  @tag obligation: "marshall.notifications.I2"
  test "Susan receives only signed ciphertext that the device alone can open" do
    {device, private} = device_fixture()
    delivery = delivery_fixture(device)
    test = self()

    Req.Test.stub(Susan, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:poke, body, Plug.Conn.get_req_header(conn, SusanPoke.key_header()),
         Plug.Conn.get_req_header(conn, SusanPoke.signature_header())}
      )

      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = perform(delivery, 1)
    assert_received {:poke, body, [key], [signature]}
    assert :ok = SusanPoke.verify(body, key, signature)
    assert {:ok, request} = SusanPoke.decode(body)
    refute body =~ "threads"
    refute body =~ "7a1c0e44"

    assert {:ok, %{kind: :needs_input, route: @route}} =
             PushPoke.open(request.ciphertext, private, request.deployment)

    {_, stranger} = PushPoke.generate_key_pair()
    assert {:error, :authentication} = PushPoke.open(request.ciphertext, stranger, request.deployment)
  end

  @tag obligation: "marshall.notifications.I3"
  test "503, 503, 200 sends once successfully; 410 invalidates the device" do
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)
    {:ok, script} = Agent.start_link(fn -> [503, 503, 200, 410] end)
    test = self()

    Req.Test.stub(Susan, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      status = Agent.get_and_update(script, fn [head | tail] -> {head, tail} end)
      {:ok, %{delivery_id: id}} = SusanPoke.decode(body)
      send(test, {:sent, id, status})
      Plug.Conn.send_resp(conn, status, "")
    end)

    for attempt <- 1..3, do: perform(delivery, attempt)
    assert [%{state: :delivered}] = Ledger.read!(Delivery, id: delivery.id)
    sent =
      for _ <- 1..3 do
        receive do
          {:sent, _, _} = message -> message
        after
          0 -> flunk("missing Susan request")
        end
      end
    assert Enum.map(sent, &elem(&1, 1)) |> Enum.uniq() == [delivery.id]
    assert Enum.count(sent, &(elem(&1, 2) in 200..299)) == 1

    gone = delivery_fixture(device, "needs_input:gone")
    assert :ok = perform(gone, 1)
    assert_received {:sent, gone_id, 410}
    assert gone_id == gone.id
    assert [%{state: :invalidated}] = Ledger.read!(Device, id: device.id)
    assert [%{state: :dropped, drop_reason: :device_inactive}] = Ledger.read!(Delivery, id: gone.id)
    later = delivery_fixture(device, "needs_input:later")
    assert :ok = perform(later, 1)
    refute_received {:sent, _, _}
  end

  @tag obligation: "marshall.notifications.I4"
  test "the operator switch refuses registration and silences the producer" do
    host_fixture()
    owner = user()
    {device, _} = device_fixture(owner)
    Application.put_env(:marshall, :notifications_enabled, false)

    {public, _} = PushPoke.generate_key_pair()
    [key] = Ledger.read!(SSH.Key, user_id: owner.id)

    assert {:error, %{errors: [%{reason: :push_disabled}]}} =
             Notifications.register_device(
               %{
                 platform: :ios,
                 push_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
                 enc_public_key: Base.url_encode64(public, padding: false),
                 key_id: key.id
               },
               actor: owner
             )

    {:ok, vm} = Compute.provision(request(), actor: owner)
    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)

    {:ok, _} =
      Ledger.transaction(fn ->
        turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: thread.id,
            actor_id: owner.id,
            request_key: Ash.UUID.generate(),
            ordinal: 1,
            prompt: "Plan.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        thread = Ledger.update!(thread, :advance, %{active_turn_id: turn.id})
        thread = Ledger.update!(thread, :set_context, %{collaboration_mode: :plan})
        Planning.request_questions_locked!(thread, turn, question_call())
      end)

    assert [] == Ledger.read!(Delivery, device_id: device.id)
  end

  @tag obligation: "marshall.notifications.I5"
  test "SSH key removal and account retirement revoke bound devices" do
    owner = user()
    {device, _} = device_fixture(owner)
    [key] = Ledger.read!(SSH.Key, user_id: owner.id)
    {:ok, _} = SSH.remove_key(%{id: key.id}, actor: owner)
    assert [%{state: :revoked, state_reason: :key_revoked}] = Ledger.read!(Device, id: device.id)

    Req.Test.stub(Susan, fn conn -> flunk("revoked device contacted Susan: #{conn.request_path}") end)
    delivery = delivery_fixture(device)
    assert :ok = perform(delivery, 1)
    assert [%{state: :dropped, drop_reason: :device_inactive}] = Ledger.read!(Delivery, id: delivery.id)

    other = user()
    {second, _} = device_fixture(other)
    {:ok, 1} = Ledger.transaction(fn -> Notifications.revoke_for_user!(other.id, :account_retired) end)
    assert [%{state: :revoked, state_reason: :account_retired}] = Ledger.read!(Device, id: second.id)
  end

  @tag obligation: "marshall.notifications.I6"
  test "device versions and registration receipts keep only the push-key digest" do
    owner = user()
    raw = :crypto.strong_rand_bytes(32)
    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, raw::binary>>)
    {:ok, _} = SSH.add_key(%{public_key: public_key}, actor: owner)
    {gateway, _} = SSH.Token.issue(:gateway)
    {:ok, _} = SSH.configure_gateway(%{name: "contract", token: gateway}, actor: SystemActor.compute())

    {:ok, session} =
      SSH.open_session(%{gateway_token: gateway, public_key: public_key}, actor: SystemActor.compute())

    {enc, _} = PushPoke.generate_key_pair()
    push_key = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)

    {:ok, command} =
      OverallsProtocol.SSHCommand.parse(
        "device register --platform ios --push-key - --enc-pubkey #{Base.url_encode64(enc, padding: false)}"
      )

    {:ok, command} = OverallsProtocol.SSHCommand.put_stdin_secret(command, push_key)

    assert {:ok, reply} =
             SSH.execute(
               %{
                 gateway_token: gateway,
                 session_token: session.session_token,
                 command: command |> Jason.encode!() |> Jason.decode!()
               },
               actor: SystemActor.compute()
             )

    refute inspect(reply) =~ push_key
    [request] = Ledger.read!(SSH.Request, user_id: owner.id)
    refute inspect(request) =~ push_key
    [device] = Ledger.read!(Device, user_id: owner.id)

    versions =
      Device.Version
      |> Ash.Query.filter(version_source_id == ^device.id)
      |> Ash.read!(actor: SystemActor.compute())

    assert versions != []
    refute inspect(versions) =~ push_key
    assert Enum.all?(versions, &(not Map.has_key?(&1.changes || %{}, "encrypted_push_key")))
  end

  defp device_fixture(actor \\ user()) do
    raw = :crypto.strong_rand_bytes(32)
    blob = <<11::32, "ssh-ed25519", 32::32, raw::binary>>
    {:ok, key} = SSH.add_key(%{public_key: "ssh-ed25519 " <> Base.encode64(blob)}, actor: actor)
    {public, private} = PushPoke.generate_key_pair()

    {:ok, view} =
      Notifications.register_device(
        %{
          platform: :ios,
          push_key: Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false),
          enc_public_key: Base.url_encode64(public, padding: false),
          key_id: key.id
        },
        actor: actor
      )

    [device] = Ledger.read!(Device, id: view.id)
    {device, private}
  end

  defp delivery_fixture(device, collapse_key \\ "needs_input:thread") do
    Ledger.create!(Delivery, :enqueue, %{
      device_id: device.id,
      user_id: device.user_id,
      kind: :needs_input,
      collapse_key: collapse_key,
      route: @route,
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })
  end

  defp perform(delivery, attempt) do
    DeliveryWorker.perform(%Oban.Job{
      args: %{"delivery_id" => delivery.id},
      attempt: attempt,
      max_attempts: 8
    })
  end

  defp question_call do
    %{
      id: "contract-call",
      arguments: %{
        "questions" => [
          %{
            "id" => "approach",
            "header" => "Approach",
            "question" => "Which approach?",
            "options" => [
              %{"label" => "First", "description" => "One."},
              %{"label" => "Second", "description" => "Two."}
            ]
          }
        ]
      }
    }
  end
end
