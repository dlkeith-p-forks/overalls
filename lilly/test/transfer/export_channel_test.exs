defmodule Lilly.Transfer.ExportChannelTest do
  use ExUnit.Case, async: true

  # @cc [owner:ghuntley,label:verification] export-channel-tests-unprivileged
  # The native channel suite MUST use the actual packaged helper and isolated
  # current-user sockets. Its synthetic workers prove framing, descriptor/status
  # separation and process cleanup, not installed SSH or native ZFS acceptance.
  test "native export channel authenticates local peers and separates data from completion" do
    helper = System.find_executable("lilly-export-channel") || raise("missing export channel")
    python = System.find_executable("python3") || raise("missing Python fixture runtime")

    {output, status} =
      System.cmd(python, [Path.join(__DIR__, "native_channel.py"), helper],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
