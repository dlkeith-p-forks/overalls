defmodule Marshall.EditorPublicationTest do
  use Marshall.DataCase, async: false
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.EditorFixture, as: F

  setup context do
    previous = Application.get_env(:marshall, :ingress_editor_releases)
    Application.put_env(:marshall, :ingress_editor_releases, F.releases())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :ingress_editor_releases, previous),
        else: Application.delete_env(:marshall, :ingress_editor_releases)
    end)

    c = F.new(Map.get(context, :profile, :standard), Map.get(context, :platform, :linux))
    certificate = Marshall.IngressHistoryFixture.certificate(String.duplicate("c", 64), 1)

    {:ok, _} =
      Marshall.Ingress.acknowledge_fleet_certificate(
        %{
          service_token: c.service_token,
          generation: certificate.generation,
          fingerprint: certificate.fingerprint
        },
        actor: SystemActor.compute()
      )

    {:ok, _} =
      Marshall.Ingress.report_ready_route(
        %{
          service_token: c.service_token,
          service_generation: c.service.generation,
          vm_id: c.vm.id,
          placement_id: c.vm.current_placement_id,
          execution_epoch: c.vm.execution_epoch,
          generation: c.vm.generation,
          certificate_fingerprint: certificate.fingerprint,
          certificate_expires_at: certificate.expires_at
        },
        actor: SystemActor.compute()
      )

    {dns_token, _} = Marshall.Ingress.Token.issue()

    {:ok, _} =
      Marshall.Ingress.configure_service(
        %{name: "editor-dns-" <> Ash.UUID.generate(), role: :dns, token: dns_token},
        actor: SystemActor.compute()
      )

    Map.put(c, :dns_token, dns_token)
  end

  @tag profile: :customer
  test "Customer editor DNS and neutral webviews require live attested assets", c do
    assert {:ok, before} = publish(c)
    refute Enum.any?(before.routes, &(&1.label in [owner(c), "webview"]))
    assert {:ok, result} = ready(c)
    assert result.editor_release == c.descriptor["release"]
    assert {:ok, after_ready} = publish(c)

    assert Enum.any?(
             after_ready.routes,
             &(&1.label == owner(c) and &1.addresses == ["192.0.2.9"])
           )

    assert Enum.any?(
             after_ready.routes,
             &(&1.label == "webview" and &1.addresses == ["192.0.2.9"])
           )

    [receipt] = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    Ledger.update!(receipt, :refresh, %{expires_at: DateTime.add(Ledger.now(), -1)})
    assert {:ok, expired} = publish(c)
    refute Enum.any?(expired.routes, &(&1.label in [owner(c), "webview"]))
  end

  test "wrong package, non-gateway and stale service credentials cannot attest assets", c do
    assert {:error, _} = ready(c, %{editor_release: String.duplicate("d", 64)})
    assert {:error, _} = ready(c, %{service_token: c.dns_token})
    assert Ledger.read!(Marshall.Ingress.EditorAssetsReceipt) == []
    assert {:ok, _} = ready(c)
    [receipt] = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    assert receipt.session_id == c.connection.session_id
    assert receipt.service_generation == c.service.generation
    [service] = Ledger.read!(Marshall.Ingress.Service, id: c.service.id)

    Ledger.update!(service, :rotate, %{
      enabled: false,
      generation: service.generation + 1,
      ssh_host_key: nil
    })

    assert {:error, _} = ready(c)
    assert {:ok, snapshot} = publish(c)
    refute Enum.any?(snapshot.routes, &(&1.label in [owner(c), "webview"]))
  end

  test "refresh preserves receipt and audit identities and extends only its deadline", c do
    assert {:ok, _} = ready(c)
    [first] = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    count = length(Ledger.read!(Marshall.Ingress.EditorAssetsReceipt.Version))
    assert {:ok, _} = ready(c)
    assert [second] = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    assert second.id == first.id

    assert Map.drop(Map.from_struct(second), [:expires_at]) ==
             Map.drop(Map.from_struct(first), [:expires_at])

    assert length(Ledger.read!(Marshall.Ingress.EditorAssetsReceipt.Version)) == count
  end

  # @cc [owner:ghuntley,label:verification;security] editor-publication-complete-release-set
  # A gateway MUST keep distinct release receipts for one current session.
  # Publication MUST require all configured releases and expire when any one
  # receipt expires; one target's receipt MUST NOT replace or refresh another.
  test "distinct release receipts coexist and publication requires their complete fresh set", c do
    Application.put_env(:marshall, :ingress_editor_releases, both_releases())
    assert {:ok, _} = ready(c)
    [linux] = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    assert {:ok, incomplete} = publish(c)
    refute Enum.any?(incomplete.routes, &(&1.label in [owner(c), "webview"]))

    assert {:ok, _} = ready(c, descriptor_fields(F.descriptor(:windows)))
    receipts = Ledger.read!(Marshall.Ingress.EditorAssetsReceipt)
    assert length(receipts) == 2
    windows = Enum.find(receipts, &(&1.editor_release == F.descriptor(:windows)["release"]))
    assert windows.id != linux.id
    assert Enum.find(receipts, &(&1.id == linux.id)).expires_at == linux.expires_at
    assert {:ok, complete} = publish(c)
    assert Enum.any?(complete.routes, &(&1.label == owner(c)))
    assert Enum.any?(complete.routes, &(&1.label == "webview"))

    Ledger.update!(windows, :refresh, %{expires_at: DateTime.add(Ledger.now(), -1)})
    assert {:ok, expired} = publish(c)
    refute Enum.any?(expired.routes, &(&1.label in [owner(c), "webview"]))
  end

  @tag platform: :windows
  test "v7 Windows editor publication matches only its target's exact approved release", c do
    Application.put_env(:marshall, :ingress_editor_releases, both_releases())
    assert {:ok, _} = ready(c)
    assert {:ok, _} = ready(c, descriptor_fields(F.descriptor()))
    assert {:ok, snapshot} = publish(c)
    assert Enum.any?(snapshot.routes, &(&1.label == owner(c)))
    assert Enum.any?(snapshot.routes, &(&1.label == "webview"))

    Application.put_env(:marshall, :ingress_editor_releases, %{
      "version" => 1,
      "targets" => %{"linux-x64" => F.descriptor(:windows), "win32-x64" => F.descriptor()}
    })

    assert {:ok, wrong_target} = publish(c)
    refute Enum.any?(wrong_target.routes, &(&1.label == owner(c)))
    assert Enum.any?(wrong_target.routes, &(&1.label == "webview"))
  end

  @spec both_releases() :: map()
  defp both_releases,
    do: %{
      "version" => 1,
      "targets" => %{"linux-x64" => F.descriptor(), "win32-x64" => F.descriptor(:windows)}
    }

  @spec descriptor_fields(map()) :: map()
  defp descriptor_fields(descriptor),
    do: %{
      editor_protocol: descriptor["protocol"],
      editor_commit: descriptor["commit"],
      editor_release: descriptor["release"]
    }

  @spec ready(map(), map()) :: {:ok, map()} | {:error, term()}
  defp ready(c, overrides \\ %{}),
    do:
      Marshall.Ingress.report_editor_assets(
        Map.merge(
          %{
            service_token: c.service_token,
            editor_protocol: 1,
            editor_commit: c.descriptor["commit"],
            editor_release: c.descriptor["release"]
          },
          overrides
        ),
        actor: SystemActor.compute()
      )

  @spec publish(map()) :: {:ok, map()} | {:error, term()}
  defp publish(c),
    do:
      Marshall.Ingress.dns_snapshot(
        %{token: c.dns_token, zone: Application.fetch_env!(:marshall, :ingress_zone)},
        actor: SystemActor.compute()
      )

  @spec owner(map()) :: String.t()
  defp owner(c), do: "editor-" <> String.replace(c.vm.id, "-", "")
end
