defmodule PorscheTerminalContractTest do
  use Covenant.Case, component: "porsche.terminal"
  alias Porsche.Terminal.Credit

  @tag obligation: "porsche.terminal.I1"
  test "declared modules compile and remain loadable" do
    assert Enum.all?(
             [Porsche.Terminal.Attachment, Porsche.Terminal.Credit],
             &Code.ensure_loaded?/1
           )
  end

  @tag obligation: "porsche.terminal.I2"
  test "read-only attachments discard input and writable grants release it in order" do
    assert {:ok, ro, 5} = Credit.push(Credit.new(true), "hello")
    assert {[], _} = Credit.take(ro)

    {:ok, pending, 0} = Credit.push(Credit.new(false), "queued")
    assert {_, 6} = Credit.grant(pending, :ro)

    {rw, 0} = Credit.grant(pending, :rw)
    assert {["queued"], rw} = Credit.take(rw)
    assert rw.window.sent_frames == 1 and rw.window.sent_bytes == 6
  end

  @tag obligation: "porsche.terminal.I3"
  test "output receipts advance per delivered frame" do
    {credit, first} = Credit.delivered(Credit.new(false), 10)
    {_credit, second} = Credit.delivered(credit, 0)
    assert first == %{frames: 1, bytes: 10}
    assert second == %{frames: 2, bytes: 10}
  end
end
