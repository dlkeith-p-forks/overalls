defmodule Lilly.EventsCatalogTest do
  use ExUnit.Case, async: false

  @metadata [
    :event,
    :host_id,
    :vm_id,
    :placement_id,
    :source,
    :method,
    :template_record_id,
    :template_incarnation,
    :execution_epoch,
    :generation,
    :reason
  ]
  @vm "11111111-1111-4111-8111-111111111111"
  @placement "22222222-2222-4222-8222-222222222222"
  @host "33333333-3333-4333-8333-333333333333"
  @template_record "44444444-4444-4444-8444-444444444444"
  @template_incarnation "55555555-5555-4555-8555-555555555555"

  test "materialization source correlates only a leased template record" do
    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        require Lilly.Events

        Lilly.Events.emit("vm.image_materialized",
          placement_id: @placement,
          method: :reflink,
          bytes: 1024,
          source: :template,
          template_record_id: @template_record,
          template_incarnation: @template_incarnation
        )
      end)

    assert log =~ "source=template"
    assert log =~ "template_record_id=#{@template_record}"
    assert log =~ "template_incarnation=#{@template_incarnation}"

    verified =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        require Lilly.Events

        Lilly.Events.emit("vm.image_materialized",
          placement_id: @placement,
          method: :copy,
          bytes: 1024,
          source: :verified,
          template_record_id: nil,
          template_incarnation: nil
        )
      end)

    assert verified =~ "source=verified"
    refute verified =~ "template_record_id="
    refute verified =~ "template_incarnation="
  end

  test "vm.launched carries the full correlation identity" do
    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        require Lilly.Events

        Lilly.Events.emit("vm.launched",
          vm_id: @vm,
          placement_id: @placement,
          execution_epoch: 3,
          generation: 4
        )
      end)

    assert log =~ "vm.launched"
    assert log =~ "VM launched"
    assert log =~ "vm_id=#{@vm}"
    assert log =~ "placement_id=#{@placement}"
    assert log =~ "execution_epoch=3"
    assert log =~ "generation=4"
  end

  test "control fencing carries its reason as metadata" do
    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        require Lilly.Events

        Lilly.Events.emit("lilly.control_fenced",
          host_id: @host,
          reason: :pool_identity_mismatch
        )
      end)

    assert log =~ "lilly.control_fenced"
    assert log =~ "host_id=#{@host}"
    assert log =~ "reason=pool_identity_mismatch"
    refute log =~ ":pool_identity_mismatch"
  end

  test "ownership acquisition diagnostics stay payload-free" do
    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        require Lilly.Events

        Lilly.Events.emit("lilly.ownership_unconfirmed", reason: :host_identity_mismatch)
        Lilly.Events.emit("lilly.ownership_acquired", [])
      end)

    assert log =~ "lilly.ownership_unconfirmed"
    assert log =~ "reason=host_identity_mismatch"
    assert log =~ "lilly.ownership_acquired"
  end
end
