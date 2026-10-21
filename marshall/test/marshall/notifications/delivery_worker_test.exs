defmodule Marshall.Notifications.DeliveryWorkerTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Notifications, SSH}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  alias Marshall.Notifications.{
    Delivery,
    DeliveryWorker,
    Device,
    Reconciler,
    Retention,
    Retry,
    Susan
  }

  alias OverallsProtocol.{PushPoke, SusanPoke}
  require Ash.Query
  require Ecto.Query
  @moduletag capture_log: true

  @route "/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"

  setup do
    {:ok, counter} = Agent.start_link(fn -> [] end)
    on_exit(fn -> Application.delete_env(:marshall, :notifications_enabled) end)
    %{requests: counter}
  end

  test "503 twice then 200 delivers once, with ciphertext-only signed bodies", c do
    {device, private} = device_fixture()
    delivery = delivery_fixture(device)
    script(c, [503, 503, 200])

    assert {:error, :server_error} = perform(delivery, 1)
    assert [%{state: :retry_wait, attempts: 1, last_status: 503}] = rows(delivery)
    assert {:error, :server_error} = perform(delivery, 2)
    assert :ok = perform(delivery, 3)
    assert [%{state: :delivered, attempts: 3, last_status: 200}] = rows(delivery)
    # A late duplicate job does not resend a terminal delivery.
    assert :ok = perform(delivery, 4)

    requests = requests(c)
    assert length(requests) == 3
    assert Enum.count(requests, &(&1.status in 200..299)) == 1

    for request <- requests do
      assert request.path == "/api/push/v1/poke"
      assert :ok = SusanPoke.verify(request.body, request.key, request.signature)
      assert {:ok, decoded} = SusanPoke.decode(request.body)
      assert decoded.delivery_id == delivery.id
      assert decoded.deployment == DeliveryWorker.deployment_host()
      refute request.body =~ @route
      refute request.body =~ "threads"

      assert {:ok, %{kind: :needs_input, route: @route}} =
               PushPoke.open(decoded.ciphertext, private, decoded.deployment)
    end

    # Every attempt carries the same idempotency key and install identity.
    assert requests |> Enum.map(& &1.key) |> Enum.uniq() |> length() == 1

    assert requests
           |> Enum.map(&SusanPoke.decode(&1.body))
           |> Enum.map(fn {:ok, d} -> d.delivery_id end)
           |> Enum.uniq() == [delivery.id]
  end

  test "410 invalidates the device and drops the delivery", c do
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)
    script(c, [410])
    assert :ok = perform(delivery, 1)
    assert [%{state: :dropped, drop_reason: :device_inactive, last_status: 410}] = rows(delivery)

    assert [%{state: :invalidated, state_reason: :provider_unregistered}] =
             Ledger.read!(Device, id: device.id)

    # Later deliveries for an invalidated device never reach Susan.
    later = delivery_fixture(device, "needs_input:other")
    assert :ok = perform(later, 1)
    assert [%{state: :dropped, drop_reason: :device_inactive}] = rows(later)
    assert length(requests(c)) == 1
  end

  test "404 also invalidates, other 4xx are permanent and 429 honours Retry-After", c do
    {device, _} = device_fixture()
    script(c, [{429, "17"}, 400])
    delivery = delivery_fixture(device)
    assert {:snooze, 17} = perform(delivery, 1)

    assert [%{state: :retry_wait, failure_reason: :rate_limited, next_attempt_at: next}] =
             rows(delivery)

    assert next
    assert :ok = perform(delivery, 2)

    assert [%{state: :failed_permanent, failure_reason: :rejected, last_status: 400}] =
             rows(delivery)

    {other, _} = device_fixture()
    script(c, [404])
    gone = delivery_fixture(other)
    assert :ok = perform(gone, 1)
    assert [%{state: :invalidated}] = Ledger.read!(Device, id: other.id)
  end

  test "the final attempt of a retryable failure is permanent as exhausted", c do
    {device, _} = device_fixture()
    script(c, [500])
    delivery = delivery_fixture(device)
    assert :ok = perform(delivery, 8)
    assert [%{state: :failed_permanent, failure_reason: :exhausted}] = rows(delivery)
  end

  test "transport failures retry without a status", c do
    {device, _} = device_fixture()
    script(c, [:transport])
    delivery = delivery_fixture(device)
    assert {:error, :transport} = perform(delivery, 1)
    assert [%{state: :retry_wait, failure_reason: :transport}] = rows(delivery)
  end

  test "expired, preference-off, disabled and revoked deliveries drop without contacting Susan",
       c do
    script(c, [])
    {device, _} = device_fixture()
    expired = delivery_fixture(device, "needs_input:a", -1)
    assert :ok = perform(expired, 1)
    assert [%{state: :dropped, drop_reason: :expired}] = rows(expired)

    {:ok, _} =
      Notifications.set_device_preference(%{id: device.id, enabled: false}, actor: owner(device))

    off = delivery_fixture(device, "needs_input:b")
    assert :ok = perform(off, 1)
    assert [%{state: :dropped, drop_reason: :preference_off}] = rows(off)

    {:ok, _} =
      Notifications.set_device_preference(%{id: device.id, enabled: true}, actor: owner(device))

    Application.put_env(:marshall, :notifications_enabled, false)
    disabled = delivery_fixture(device, "needs_input:c")
    assert :ok = perform(disabled, 1)
    assert [%{state: :dropped, drop_reason: :preference_off}] = rows(disabled)
    Application.delete_env(:marshall, :notifications_enabled)

    {:ok, _} = Notifications.remove_device(%{id: device.id}, actor: owner(device))
    revoked = delivery_fixture(device, "needs_input:d")
    assert :ok = perform(revoked, 1)
    assert [%{state: :dropped, drop_reason: :device_inactive}] = rows(revoked)
    assert requests(c) == []
  end

  test "a delivery stuck in sending is reconciled and resent under the same id", c do
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)

    stuck =
      Ledger.update!(delivery, :begin_send, %{
        attempts: 1,
        sending_started_at: DateTime.add(DateTime.utc_now(), -600, :second)
      })

    assert stuck.state == :sending
    assert {:ok, count} = Reconciler.run(nil, [], %{actor: SystemActor.compute()})
    assert count >= 1

    assert [%Oban.Job{args: %{"delivery_id" => id}}] =
             Oban.Job
             |> Ecto.Query.where(worker: "Marshall.Notifications.DeliveryWorker")
             |> Marshall.Repo.all()

    assert id == delivery.id

    script(c, [200])
    assert :ok = perform(delivery, 2)
    assert [%{state: :delivered, attempts: 2}] = rows(delivery)
  end

  test "reconciler expiry logs only committed payload-free transitions" do
    {device, _} = device_fixture()
    delivery = delivery_fixture(device, "needs_input:expired-private", -600)
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    metadata = [:event, :delivery_id, :device_id, :state, :reason]

    rolled_back =
      ExUnit.CaptureLog.capture_log([metadata: metadata], fn ->
        assert {:error, :test_rollback} =
                 Ledger.transaction(fn ->
                   assert {:ok, _} = Reconciler.run(nil, [], %{actor: SystemActor.compute()})
                   Ledger.rollback(:test_rollback)
                 end)
      end)

    refute rolled_back =~ "notifications.delivery_transition"
    assert [%{state: :queued}] = rows(delivery)

    committed =
      ExUnit.CaptureLog.capture_log([metadata: metadata], fn ->
        assert {:ok, _} = Reconciler.run(nil, [], %{actor: SystemActor.compute()})
        assert {:ok, _} = Reconciler.run(nil, [], %{actor: SystemActor.compute()})
      end)

    assert [%{state: :dropped, drop_reason: :expired}] = rows(delivery)
    assert length(Regex.scan(~r/event=notifications.delivery_transition/, committed)) == 1
    assert committed =~ "delivery_id=#{delivery.id}"
    assert committed =~ "reason=expired"
    refute committed =~ @route
    refute committed =~ "needs_input:expired-private"
  end

  test "a stale outcome from a superseded attempt does not overwrite the row" do
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)
    test = self()

    # While attempt 1 is in flight, the reconciler hands the row to attempt 2.
    Req.Test.stub(Susan, fn conn ->
      [row] = rows(delivery)
      row = Ledger.update!(row, :retry_later, %{failure_reason: :transport})
      Ledger.update!(row, :begin_send, %{attempts: 2, sending_started_at: DateTime.utc_now()})
      send(test, :superseded)
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = perform(delivery, 1)
    assert_received :superseded
    assert [%{state: :sending, attempts: 2}] = rows(delivery)
  end

  test "pruning removes only terminal deliveries older than seven days with their versions", c do
    script(c, [200])
    {device, _} = device_fixture()
    old = delivery_fixture(device, "needs_input:old")
    assert :ok = perform(old, 1)
    open = delivery_fixture(device, "needs_input:open")

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE notification_deliveries SET finished_at = now() - interval '8 days', inserted_at = now() - interval '8 days' WHERE id = $1",
      [Ecto.UUID.dump!(old.id)]
    )

    assert {:ok, 1} = Retention.run(nil, [], %{actor: SystemActor.compute()})
    assert [] == Ledger.read!(Delivery, id: old.id)
    assert [_] = Ledger.read!(Delivery, id: open.id)

    assert [] ==
             Delivery.Version
             |> Ash.Query.filter(version_source_id == ^old.id)
             |> Ash.read!(actor: SystemActor.compute())

    assert {:error, _} = Retention.run(nil, [], %{actor: nil})
  end

  test "terminal transitions alone enter the audit trail, without routes", c do
    script(c, [503, 200])
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)
    perform(delivery, 1)
    perform(delivery, 2)

    versions =
      Delivery.Version
      |> Ash.Query.filter(version_source_id == ^delivery.id)
      |> Ash.read!(actor: SystemActor.compute())

    assert Enum.map(versions, & &1.version_action_name) == [:deliver]
    refute inspect(versions) =~ @route
  end

  test "the Susan origin is the compiled production constant outside tests" do
    assert Susan.production_origin() == "https://notifications.overalls.dev"
    assert Susan.origin() == "https://susan.test"
  end

  test "an enqueued job drains through the notifications queue", c do
    script(c, [200])
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)
    %{delivery_id: delivery.id} |> DeliveryWorker.new() |> Oban.insert!()
    assert %{success: 1} = Oban.drain_queue(queue: :notifications)
    assert [%{state: :delivered}] = rows(delivery)
  end

  property "the retry mapping matches the ADR-0225 table", test_cases: 200 do
    status = draw("status", integer(100, 599))
    final? = draw("final", boolean())
    retry_after = draw("retry_after", one_of([constant(nil), integer(0, 3600)]))

    outcome =
      Susan.classify(
        {:ok,
         %Req.Response{
           status: status,
           headers:
             if(retry_after, do: %{"retry-after" => [Integer.to_string(retry_after)]}, else: %{})
         }}
      )

    decision = Retry.decide(outcome, final?)

    cond do
      status in 200..299 ->
        assert decision == :delivered

      status in [404, 410] ->
        assert decision == :invalidate

      (status == 429 or status in 500..599) and final? ->
        assert decision == {:permanent, :exhausted}

      status == 429 ->
        assert decision == {:retry, :rate_limited, retry_after}

      status in 500..599 ->
        assert decision == {:retry, :server_error, retry_after}

      true ->
        assert decision == {:permanent, :rejected}
    end
  end

  property "backoff is jittered, positive and bounded", test_cases: 200 do
    attempt = draw("attempt", integer(1, 64))
    jitter = draw("jitter", float(0.0, 1.0))
    seconds = Retry.backoff(attempt, jitter)
    assert seconds >= 1 and seconds <= Retry.cap()
    assert Retry.backoff(attempt, 0.0) <= seconds and seconds <= Retry.backoff(attempt, 1.0)
  end

  # Any Susan response sequence drives the delivery state machine to the
  # model's outcome: at most one success, terminal states final, invalidation
  # only on 404/410, and never more attempts than Oban allows.
  property "delivery state machine follows the model for arbitrary Susan responses",
    test_cases: 30 do
    responses =
      draw(
        "responses",
        list_of(member_of([200, 202, 400, 401, 404, 410, 429, 500, 503, :transport]),
          min_length: 1,
          max_length: 8
        )
      )

    {:ok, counter} = Agent.start_link(fn -> [] end)
    script(%{requests: counter}, responses)
    {device, _} = device_fixture()
    delivery = delivery_fixture(device)

    expected =
      Enum.reduce_while(Enum.with_index(responses, 1), :retry_wait, fn {response, attempt}, _ ->
        final? = attempt == 8

        case response do
          status when status in [200, 202] -> {:halt, :delivered}
          status when status in [404, 410] -> {:halt, :dropped}
          status when status in [400, 401] -> {:halt, :failed_permanent}
          _ when final? -> {:halt, :failed_permanent}
          _ -> {:cont, :retry_wait}
        end
      end)

    Enum.reduce_while(1..length(responses), nil, fn attempt, _ ->
      perform(delivery, attempt)

      case rows(delivery) do
        [%{state: state}] when state in [:delivered, :dropped, :failed_permanent] ->
          {:halt, state}

        _ ->
          {:cont, nil}
      end
    end)

    [row] = rows(delivery)
    assert row.state == expected
    sent = Agent.get(counter, & &1)
    assert Enum.count(sent, &(&1.status in 200..299)) <= 1
    assert row.attempts == length(sent)

    [current] = Ledger.read!(Device, id: device.id)
    assert current.state == :invalidated == (row.state == :dropped)
    Agent.stop(counter)
  end

  # Fixtures

  defp device_fixture do
    actor = user()
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

  defp delivery_fixture(device, collapse_key \\ "needs_input:thread", expires_in \\ 3600) do
    Ledger.create!(Delivery, :enqueue, %{
      device_id: device.id,
      user_id: device.user_id,
      kind: :needs_input,
      collapse_key: collapse_key,
      route: @route,
      expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
    })
  end

  defp owner(device), do: Marshall.Accounts.Security.current(device.user_id)

  defp perform(delivery, attempt) do
    DeliveryWorker.perform(%Oban.Job{
      args: %{"delivery_id" => delivery.id},
      attempt: attempt,
      max_attempts: 8
    })
  end

  defp rows(delivery), do: Ledger.read!(Delivery, id: delivery.id)

  defp requests(c), do: Agent.get(c.requests, &Enum.reverse/1)

  # Scripts Susan's responses in order; each call records what was sent.
  defp script(c, responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    requests = c.requests

    Req.Test.stub(Susan, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      response =
        Agent.get_and_update(queue, fn
          [head | tail] -> {head, tail}
          [] -> {200, []}
        end)

      case response do
        :transport ->
          Agent.update(
            requests,
            &[
              %{
                status: 0,
                body: body,
                path: conn.request_path,
                key: header(conn, SusanPoke.key_header()),
                signature: header(conn, SusanPoke.signature_header())
              }
              | &1
            ]
          )

          Req.Test.transport_error(conn, :econnrefused)

        {status, retry_after} ->
          record(requests, conn, body, status)

          conn
          |> Plug.Conn.put_resp_header("retry-after", retry_after)
          |> Plug.Conn.send_resp(status, "")

        status ->
          record(requests, conn, body, status)
          Plug.Conn.send_resp(conn, status, "")
      end
    end)
  end

  defp record(requests, conn, body, status) do
    Agent.update(requests, fn sent ->
      [
        %{
          status: status,
          body: body,
          path: conn.request_path,
          key: header(conn, SusanPoke.key_header()),
          signature: header(conn, SusanPoke.signature_header())
        }
        | sent
      ]
    end)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()
end
