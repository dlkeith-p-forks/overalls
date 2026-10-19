defmodule MarshallWeb.Admin.AuditLabelsTest do
  use ExUnit.Case, async: true

  alias MarshallWeb.Admin.AuditLabels

  test "all account authority audit kinds have explicit human labels" do
    kinds =
      Marshall.Accounts.AdminEvent
      |> Ash.Resource.Info.attribute(:kind)
      |> Map.fetch!(:constraints)
      |> Keyword.fetch!(:one_of)

    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      for kind <- kinds do
        refute AuditLabels.action(kind) == "Unknown", inspect(kind)
        assert AuditLabels.action(kind) == AuditLabels.action(Atom.to_string(kind))
      end

      assert AuditLabels.action(:ssh_key_revoke) == "SSH key revoked"
      assert AuditLabels.action(:editor_lease) == "Editor lease"
      assert AuditLabels.action(:account) == "ACME account"
    end)
  end

  test "certificate action names and installation receipts have human labels" do
    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      for resource <- [
            Marshall.Ingress.FleetCertificate,
            Marshall.Ingress.FleetCertificateAccount
          ],
          action <- Ash.Resource.Info.actions(resource),
          action.type in [:create, :update, :destroy] do
        refute AuditLabels.action(action.name) == "Unknown", inspect(action.name)
      end

      assert AuditLabels.action(:installed) == "Installed"
      assert AuditLabels.action(:fail_unknown_order) == "Uncertain certificate order failed"
    end)
  end

  test "lifecycle source actions remain covered independently of label implementation" do
    resources = [
      Marshall.Compute.CloneRequest,
      Marshall.Compute.Evacuation,
      Marshall.Compute.Relocation,
      Marshall.Compute.Operation,
      Marshall.Compute.HostDrain,
      Marshall.Compute.ReadinessRequest,
      Marshall.Compute.SourcePermitRequest,
      Marshall.Compute.EvacuationItem,
      Marshall.Compute.CleanupRequest,
      Marshall.Compute.ResizeRequest,
      Marshall.Compute.ProbeRequest,
      Marshall.Compute.VirtualMachine,
      Marshall.Compute.CloneEffect
    ]

    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      for resource <- resources,
          action <- Ash.Resource.Info.actions(resource),
          action.type in [:create, :update, :destroy] do
        refute AuditLabels.action(action.name) == "Unknown", inspect({resource, action.name})
      end
    end)
  end

  test "states use reviewed labels and unknown technical identifiers stay outside catalogs" do
    Gettext.with_locale(MarshallWeb.Gettext, "en", fn ->
      assert AuditLabels.state("created") == "Created"
      assert AuditLabels.state("stopping_source") == "Stopping source"
      assert AuditLabels.state(:readiness_failed) == "Readiness failed"
      assert AuditLabels.state(nil) == "—"
      assert AuditLabels.state("new_unreviewed_state") == "Unknown"
      assert AuditLabels.action("new_unreviewed_action") == "Unknown"
    end)
  end
end
