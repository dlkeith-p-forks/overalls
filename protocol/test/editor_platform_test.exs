defmodule OverallsProtocol.EditorPlatformTest do
  use ExUnit.Case, async: true

  alias OverallsProtocol.{EditorPlatform, GuestAgents}

  @release %{
    "protocol" => 1,
    "commit" => String.duplicate("a", 40),
    "release" => String.duplicate("b", 64)
  }

  for {os, service_manager, expected_os} <- [
        {"linux", "systemd", :linux},
        {"windows", "windows-service", :windows},
        {"freebsd", "rc.d", :freebsd},
        {"illumos", "smf", :illumos}
      ] do
    test "round trips the closed #{os} platform descriptor" do
      descriptor = %{
        "version" => 1,
        "os" => unquote(os),
        "architecture" => "x86_64",
        "service_manager" => unquote(service_manager),
        "release" => @release
      }

      assert {:ok, decoded} = EditorPlatform.decode(descriptor)
      assert decoded.version == 1
      assert decoded.os == unquote(expected_os)
      assert decoded.architecture == :x86_64
      assert EditorPlatform.encode(decoded) == descriptor
    end
  end

  test "rejects unsupported versions, fields, targets and release identities" do
    descriptor = %{
      "version" => 1,
      "os" => "windows",
      "architecture" => "x86_64",
      "service_manager" => "windows-service",
      "release" => @release
    }

    for invalid <- [
          Map.put(descriptor, "version", 2),
          Map.put(descriptor, "unknown", true),
          Map.put(descriptor, "os", "solaris"),
          Map.put(descriptor, "os", :windows),
          Map.put(descriptor, "architecture", "aarch64"),
          Map.put(descriptor, "service_manager", "systemd"),
          Map.put(descriptor, "service_manager", :windows_service),
          Map.put(descriptor, "release", Map.put(@release, "unknown", true)),
          Map.put(descriptor, "release", nil)
        ] do
      assert {:error, :invalid_editor_platform} = EditorPlatform.decode(invalid)
    end
  end

  test "descriptor validation does not widen current non-Linux capability rows" do
    assert {:ok, _} =
             EditorPlatform.decode(%{
               "version" => 1,
               "os" => "windows",
               "architecture" => "x86_64",
               "service_manager" => "windows-service",
               "release" => @release
             })

    refute GuestAgents.capabilities(:windows_v1).editor
    refute GuestAgents.capabilities(:freebsd_v1).editor
    refute GuestAgents.capabilities(:illumos_v1).editor
  end
end
