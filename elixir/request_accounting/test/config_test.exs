defmodule Overalls.RequestAccounting.ConfigTest do
  use ExUnit.Case, async: false

  alias Overalls.RequestAccounting.{Config, Producer}

  setup do
    previous =
      for key <- [
            "OVERALLS_REQUEST_ACCOUNTING_SOCKET",
            "OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY",
            "OVERALLS_REQUEST_ACCOUNTING_SOCKET_SECOND",
            "OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY_SECOND"
          ],
          into: %{} do
        {key, System.get_env(key)}
      end

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    System.delete_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET")
    System.delete_env("OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY")
    System.delete_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET_SECOND")
    System.delete_env("OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY_SECOND")
    :ok
  end

  test "suffixed sources read only their own variables" do
    System.put_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET", "/run/first/recorder.sock")
    System.put_env("OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY", "/var/lib/first/marker")
    assert Config.from_environment(SecondProducer, "_SECOND") == :ignore

    System.put_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET_SECOND", "/run/second/recorder.sock")

    assert {:error, :invalid_measurement_configuration} =
             Config.from_environment(SecondProducer, "_SECOND")

    System.put_env(
      "OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY_SECOND",
      "/var/lib/second/marker"
    )

    assert {:ok,
            %Config{socket: "/run/second/recorder.sock", directory: "/var/lib/second/marker"}} =
             Config.from_environment(SecondProducer, "_SECOND")

    assert {:ok, %Config{socket: "/run/first/recorder.sock"}} =
             Config.from_environment(FirstProducer)

    for suffix <- ["SECOND", "_second", "_A B", "_"] do
      assert_raise ArgumentError, fn -> Config.from_environment(SecondProducer, suffix) end
    end
  end

  test "validates explicit configuration before supervision" do
    assert {:ok, %Config{name: TestProducer, socket: "/tmp/socket", directory: "/tmp/marker"}} =
             Config.new(name: TestProducer, socket: "/tmp/socket", directory: "/tmp/marker")

    assert_raise ArgumentError, fn ->
      Config.new!(name: TestProducer, socket: nil, directory: "/tmp/marker")
    end

    assert {:error, :invalid_measurement_configuration} =
             Config.new(name: TestProducer, socket: "socket", directory: "/tmp/marker")

    assert {:error, :invalid_measurement_configuration} =
             Config.new(name: TestProducer, socket: "/tmp/socket", directory: "marker")
  end

  test "rejects incomplete, unknown and duplicate options" do
    assert {:error, :invalid_measurement_configuration} =
             Config.new(name: TestProducer, socket: "/tmp/socket")

    assert {:error, :invalid_measurement_configuration} =
             Config.new(
               name: TestProducer,
               socket: "/tmp/socket",
               directory: "/tmp/marker",
               extra: true
             )

    assert {:error, :invalid_measurement_configuration} =
             Config.new(
               name: TestProducer,
               name: OtherProducer,
               socket: "/tmp/socket",
               directory: "/tmp/marker"
             )
  end

  test "environment discovery omits only fully disabled producers" do
    assert :ignore = Config.from_environment(TestProducer)
    assert [] = Producer.children(TestProducer)

    System.put_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET", "/tmp/socket")

    assert {:error, :invalid_measurement_configuration} = Config.from_environment(TestProducer)
    assert_raise ArgumentError, fn -> Producer.children(TestProducer) end

    System.put_env("OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY", "/tmp/marker")

    assert {:ok, config} = Config.from_environment(TestProducer)
    assert [{Producer, ^config}] = Producer.children(TestProducer)

    assert %{id: TestProducer, start: {Producer, :start_link, [^config]}, shutdown: 10_000} =
             Producer.child_spec(config)
  end
end
