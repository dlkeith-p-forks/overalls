defmodule MarshallWeb.RepositoryLaunchHistoryTest do
  use MarshallWeb.ConnCase, async: false
  @moduletag :capture_log
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias OverallsProtocol.{Execution, WorkspaceSource}

  alias Marshall.Compute.{
    HostReports,
    Ledger,
    Operation,
    Reservation,
    VirtualMachine
  }

  alias Marshall.Compute.WorkspaceSource, as: StoredSource
  alias MarshallWeb.{PendingLaunch, RepositoryLaunchController}

  @valid_sources [
    "https://github.com/tastejs/todomvc",
    "https://github.com/tastejs/todomvc/",
    "https://github.com/tastejs/todomvc.git",
    "https://github.com/elixir-lang/elixir/tree/main",
    "https://github.com/elixir-lang/elixir/tree/release/v1.18",
    "https://github.com/phoenixframework/phoenix/commit/0123456789abcdef0123456789abcdef01234567",
    "https://github.com/phoenixframework/phoenix/commit/ABCDEF1",
    "https://github.com/ash-project/ash/pull/42",
    "https://github.com/ash-project/ash/pull/42/files",
    "https://gitlab.com/group/nested/project/-/tree/main",
    "https://codeberg.org/forgejo/forgejo/src/branch/main",
    "https://bitbucket.org/atlassian/python-bitbucket/pull-requests/2"
  ]

  @invalid_sources [
    "https://example.test/tastejs/todomvc",
    "http://github.com/tastejs/todomvc",
    "https://github.com:443/tastejs/todomvc",
    "https://user@github.com/tastejs/todomvc",
    "https://github.com/-bad/todomvc",
    "https://github.com/tastejs/todomvc/tree/..",
    "https://github.com/tastejs/todomvc/tree/%2e%2e",
    "https://github.com/tastejs/todomvc/pull/0",
    "https://github.com/tastejs",
    "not a url"
  ]

  @type nonce :: String.t()
  @type pair :: {String.t(), nonce()}
  @type command ::
          {:visit, String.t(), nonce()}
          | :reload
          | {:revisit_same, nonce()}
          | :back
          | {:invalid_url, String.t(), nonce()}
          | {:invalid_visit, String.t()}
          | :anonymous_visit
          | :plain_root

  @type model :: %{
          vms: %{pair() => String.t()},
          sources: %{String.t() => WorkspaceSource.t()},
          last: pair() | nil
        }

  # @cc [owner:ghuntley,label:verification;product] repository-launch-history-oracle
  # Generated browser histories of visits, reloads, back navigation, fresh
  # revisits, invalid links, anonymous visits and plain roots MUST leave exactly
  # one OSS machine with a matching stored source and pinned provision command per
  # distinct signed-in (canonical source, visit nonce) pair, and nothing else.
  @tag :hegel
  test "repository launch visits dedupe per visit across generated histories", %{
    conn: conn
  } do
    check all(
            commands <- list_of(command(), min_length: 1, max_length: 10),
            test_cases: 12
          ) do
      fixture = roomy_host()
      owner = user()
      signed = signed_in(conn, owner)
      baseline = global_counts()

      Enum.reduce(commands, {%{vms: %{}, sources: %{}, last: nil}, fixture}, fn command,
                                                                                {model, fixture} ->
        fixture = refresh(fixture)
        model = run(command, model, signed, owner)
        assert_invariants(model, owner, baseline)
        {model, fixture}
      end)
    end
  end

  test "a launch pins the encoded source on the OSS provision command", %{conn: conn} do
    roomy_host()
    owner = user()
    signed = signed_in(conn, owner)
    visit = String.duplicate("ab", 16)
    model = launch(%{vms: %{}, sources: %{}, last: nil}, signed, @valid_sources |> hd(), visit)
    [{_, vm_id}] = Map.to_list(model.vms)
    [operation] = Ledger.read!(Operation, vm_id: vm_id)

    assert operation.command_snapshot["workspace_source"] == %{
             "version" => 2,
             "provider" => "github",
             "namespace" => ["tastejs"],
             "repository" => "todomvc",
             "revision" => %{"kind" => "default"}
           }

    assert {:ok, %{workspace_source: %{namespace: ["tastejs"]}, kind: :provision, profile: :oss}} =
             Execution.command(operation.command_snapshot)
  end

  # Regression: host inventory observations are transient. A replayed visit MUST
  # size itself from the durable image record, or it would drift to generic
  # minima and be refused as an idempotency conflict.
  test "a revisit returns the same machine after the catalog stops listing its image",
       %{conn: conn} do
    fixture = roomy_host()

    manifest =
      Map.merge(image_manifest(), %{
        "boot_args" => "console=ttyS0 quiet",
        "minimum_memory_bytes" => 1_073_741_824,
        "minimum_disk_bytes" => 4_294_967_296
      })

    {:ok, image} = Marshall.Compute.Images.register(manifest, "launch-sizing-image")
    listed = %{fixture.report.inventory | "images" => [image_id(), image.id]}
    fixture = refresh(put_in(fixture, [:report, :inventory], listed))
    previous = Application.get_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image.id)
    on_exit(fn -> Application.put_env(:marshall, :default_image_id, previous) end)

    owner = user()
    signed = signed_in(conn, owner)
    visit = String.duplicate("cd", 16)
    url = hd(@valid_sources)
    model = launch(%{vms: %{}, sources: %{}, last: nil}, signed, url, visit)
    [{_, vm_id}] = Map.to_list(model.vms)
    [vm] = Ledger.read!(VirtualMachine, id: vm_id)
    assert vm.memory_bytes == 1_073_741_824 and vm.disk_bytes == 4_294_967_296

    unlisted = %{fixture.report.inventory | "images" => [image_id()]}
    refresh(put_in(fixture, [:report, :inventory], unlisted))

    refute image.id in Enum.map(
             elem(Marshall.Compute.catalog(%{}, actor: owner), 1).images,
             & &1.id
           )

    replayed = launch(model, signed, url, visit)
    assert replayed.vms == model.vms
    assert length(Ledger.read!(VirtualMachine, owner_id: owner.id)) == 1
  end

  test "an invalid link refuses public capture without creating a machine", %{conn: conn} do
    owner = user()

    response =
      stage(signed_in(conn, owner), %{
        "source" => "https://example.test/a/b",
        "visit" => String.duplicate("0", 32)
      })

    assert response.status == 422
    refute get_session(response, PendingLaunch.key())
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []
  end

  test "failed admission retains pending input for a later retry", %{conn: conn} do
    owner = user()
    previous = Application.get_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, "unavailable-fixture-image")
    on_exit(fn -> Application.put_env(:marshall, :default_image_id, previous) end)
    signed = signed_in(conn, owner)

    staged =
      stage(signed, %{"source" => hd(@valid_sources), "visit" => String.duplicate("a", 32)})

    pending = get_session(staged, PendingLaunch.key())
    {:ok, view, _} = live(put_session(signed, PendingLaunch.key(), pending), "/launch")
    assert has_element?(view, "#launch-error")
    assert get_session(staged, PendingLaunch.key()) == pending
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []
  end

  test "revocation after admission refuses completion without clearing pending input", %{
    conn: conn
  } do
    roomy_host()
    owner = user()
    signed = signed_in(conn, owner)

    staged =
      stage(signed, %{"source" => hd(@valid_sources), "visit" => String.duplicate("a", 32)})

    pending = get_session(staged, PendingLaunch.key())
    signed = put_session(signed, PendingLaunch.key(), pending)
    {:ok, view, _} = live(signed, "/launch")
    assert_push_event(view, "repository-launch-complete", %{receipt: receipt}, 5_000)
    :ok = Marshall.Accounts.AccountLifecycle.revoke_tokens!(owner.id)
    refused = RepositoryLaunchController.clear(signed, %{"receipt" => receipt})
    assert refused.status == 403
    assert get_session(refused, PendingLaunch.key()) == pending
    assert [_] = Ledger.read!(VirtualMachine, owner_id: owner.id)
  end

  @spec command() :: Hegel.Gen.t(command())
  defp command do
    one_of([
      tuple({constant(:visit), member_of(@valid_sources), nonce()}),
      constant(:reload),
      tuple({constant(:revisit_same), nonce()}),
      constant(:back),
      tuple({constant(:invalid_url), member_of(@invalid_sources), nonce()}),
      tuple({constant(:invalid_visit), member_of(@valid_sources)}),
      constant(:anonymous_visit),
      constant(:plain_root)
    ])
  end

  @spec nonce() :: Hegel.Gen.t(nonce())
  defp nonce, do: map(binary(length: 16), &Base.encode16(&1, case: :lower))

  @spec run(command(), model(), Plug.Conn.t(), Marshall.Accounts.User.t()) :: model()
  defp run({:visit, url, visit}, model, conn, _owner), do: launch(model, conn, url, visit)

  # Reload and back replay the stored visit nonce of the tab's last launch.
  defp run(replay, %{last: {url, visit}} = model, conn, _owner)
       when replay in [:reload, :back],
       do: launch(model, conn, url, visit)

  defp run({:revisit_same, visit}, %{last: {url, _}} = model, conn, _owner),
    do: launch(model, conn, url, visit)

  defp run({:invalid_url, url, visit}, model, conn, _owner) do
    assert stage(conn, %{"source" => url, "visit" => visit}).status == 422
    model
  end

  defp run({:invalid_visit, url}, model, conn, _owner) do
    assert stage(conn, %{"source" => url, "visit" => "not-a-visit"}).status == 422
    model
  end

  defp run(:anonymous_visit, model, _conn, _owner) do
    anonymous = build_conn()
    assert redirected_to(get(anonymous, ~p"/")) == ~p"/launch/entry"

    pending =
      stage(anonymous |> init_test_session(%{}), %{
        "source" => hd(@valid_sources),
        "visit" => String.duplicate("a", 32)
      })

    assert PendingLaunch.read(get_session(pending))
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(anonymous, ~p"/launch")
    model
  end

  # With no fragment (plain root, or reload/back before any launch) the hook is idle.
  defp run(_idle, model, conn, _owner) do
    assert redirected_to(get(conn, ~p"/")) == ~p"/launch/entry"
    assert {:error, {:live_redirect, %{to: "/overview"}}} = live(conn, ~p"/launch")
    model
  end

  @spec launch(model(), Plug.Conn.t(), String.t(), nonce()) :: model()
  defp launch(model, conn, url, visit) do
    {:ok, source} = WorkspaceSource.parse_url(url)
    pair = {WorkspaceSource.to_url(source), visit}
    staged = stage(conn, %{"source" => url, "visit" => visit})
    assert redirected_to(staged) == "/launch"

    {:ok, view, _} =
      live(
        put_session(conn, PendingLaunch.key(), get_session(staged, PendingLaunch.key())),
        ~p"/launch"
      )

    assert_push_event(view, "repository-launch-complete", %{receipt: receipt}, 5_000)
    {:ok, %{vm_id: vm_id}} = PendingLaunch.verify_receipt(receipt)

    invalid =
      conn
      |> put_session(PendingLaunch.key(), get_session(staged, PendingLaunch.key()))
      |> RepositoryLaunchController.clear(%{"receipt" => receipt <> "x"})

    assert invalid.status == 403
    assert get_session(invalid, PendingLaunch.key())

    foreign =
      signed_in(build_conn(), user()) |> RepositoryLaunchController.clear(%{"receipt" => receipt})

    assert foreign.status == 403

    completed =
      conn
      |> put_session(PendingLaunch.key(), get_session(staged, PendingLaunch.key()))
      |> RepositoryLaunchController.clear(%{"receipt" => receipt})

    assert redirected_to(completed) == "/machines/" <> vm_id
    refute get_session(completed, PendingLaunch.key())

    newer = %{get_session(staged, PendingLaunch.key()) | visit: String.duplicate("e", 32)}

    preserved =
      conn
      |> put_session(PendingLaunch.key(), newer)
      |> RepositoryLaunchController.clear(%{"receipt" => receipt})

    assert get_session(preserved, PendingLaunch.key()) == newer

    case model.vms do
      %{^pair => expected} -> assert vm_id == expected
      vms -> refute vm_id in Map.values(vms)
    end

    %{
      model
      | vms: Map.put(model.vms, pair, vm_id),
        sources: Map.put(model.sources, vm_id, source),
        last: {url, visit}
    }
  end

  @spec stage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  defp stage(conn, params) do
    conn
    |> fetch_session()
    |> RepositoryLaunchController.stage(params)
  end

  @spec assert_invariants(model(), Marshall.Accounts.User.t(), map()) :: :ok
  defp assert_invariants(model, owner, baseline) do
    vms = Ledger.read!(VirtualMachine, owner_id: owner.id)
    assert length(vms) == map_size(model.vms)
    assert Enum.sort(Enum.map(vms, & &1.id)) == Enum.sort(Map.values(model.vms))

    for vm <- vms do
      assert vm.profile == :oss
      expected = Map.fetch!(model.sources, vm.id)
      assert [stored] = Ledger.read!(StoredSource, vm_id: vm.id)
      assert StoredSource.protocol(stored) == expected
      assert [operation] = Ledger.read!(Operation, vm_id: vm.id)
      assert operation.command_snapshot["workspace_source"] == WorkspaceSource.encode(expected)
      assert {:ok, %{workspace_source: ^expected}} = Execution.command(operation.command_snapshot)
      assert [_] = Ledger.read!(Reservation, vm_id: vm.id)
    end

    counts = global_counts()
    added = map_size(model.vms)

    assert counts == %{
             vms: baseline.vms + added,
             operations: baseline.operations + added,
             reservations: baseline.reservations + added,
             sources: baseline.sources + added
           }

    :ok
  end

  @spec global_counts() :: map()
  defp global_counts,
    do: %{
      vms: length(Ledger.read!(VirtualMachine)),
      operations: length(Ledger.read!(Operation)),
      reservations: length(Ledger.read!(Reservation)),
      sources: length(Ledger.read!(StoredSource))
    }

  @big 1_099_511_627_776

  @spec roomy_host() :: map()
  defp roomy_host do
    fixture = host_fixture()
    refresh(Map.put(fixture, :sequence, 1))
  end

  # Re-reports generous capacity so the five-second freshness window never
  # turns a generated launch into a capacity refusal.
  @spec refresh(map()) :: map()
  defp refresh(fixture) do
    sequence = Map.get(fixture, :sequence, 1) + 1
    [pool] = fixture.report.pools

    report = %{
      fixture.report
      | sequence: sequence,
        sampled_at: Ledger.now(),
        effective_cores: 64,
        effective_memory_bytes: 274_877_906_944,
        capacity: capacity(64, 274_877_906_944),
        pools: [
          %{
            pool
            | total_bytes: @big,
              free_bytes: @big,
              storage: storage_observation(fixture.pool, @big, @big)
          }
        ]
    }

    {:ok, :ok} = HostReports.ingest(fixture.host.id, fixture.epoch, report)
    Map.put(fixture, :sequence, sequence)
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
    |> assign(:current_user, user)
  end
end
