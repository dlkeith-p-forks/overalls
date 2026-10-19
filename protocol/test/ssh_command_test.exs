defmodule OverallsProtocol.SSHCommandTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.SSHCommand

  property "memory lifecycle commands are bounded physical mutations with stable request identity",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_026_101_801 do
    name = draw("name", member_of(["pause", "resume", "unpause"]))
    suffix = draw("suffix", integer(1..999_999))
    machine = "machine-#{suffix}"
    key = "memory-#{suffix}"

    assert {:ok, command} =
             SSHCommand.parse("#{name} #{machine} --request-id #{key} --no-wait --json")

    assert command.command == name
    assert command.arguments == [machine]
    assert command.options["request-id"] == key
    assert SSHCommand.mutation?(name)
    assert SSHCommand.physical?(name)

    assert {:ok, ^command} =
             SSHCommand.validate(%{
               "version" => command.version,
               "command" => command.command,
               "arguments" => command.arguments,
               "options" => command.options
             })

    assert {:error, :invalid_command} = SSHCommand.parse("#{name}")
    assert {:error, :invalid_command} = SSHCommand.parse("#{name} #{machine} extra")
    assert {:error, :invalid_command} = SSHCommand.parse("#{name} #{machine} --source nope")
  end

  property "advertised peer flag parses as a boolean regardless of option ordering",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_142_110_225 do
    suffix = draw("suffix", integer(1..999_999))
    peer_first? = draw("peer_first?", boolean())
    machine = "vm-#{suffix}"

    options =
      if peer_first? do
        "--peer --peer-vm #{machine}"
      else
        "--peer-vm #{machine} --peer"
      end

    assert {:ok, command} = SSHCommand.parse("integration add peer-api #{options} --json")
    assert command.options["peer"] == true
    assert command.options["peer-vm"] == machine

    assert {:ok, ^command} =
             SSHCommand.validate(%{
               "version" => command.version,
               "command" => command.command,
               "arguments" => command.arguments,
               "options" => command.options
             })

    assert {:error, :invalid_command} = SSHCommand.parse("new --peer")

    assert {:error, :invalid_command} =
             SSHCommand.parse("integration add peer-api --peer=false")
  end

  property "quoted machine names and option ordering preserve command meaning",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 246_578_205 do
    suffix =
      draw(
        "suffix",
        OverallsProtocol.TestGenerators.string(:alphanumeric, min_length: 1, max_length: 30)
      )

    cpu = draw("cpu", integer(1..256))
    name = "vm-" <> String.downcase(suffix)
    assert {:ok, expected} = SSHCommand.parse("new --name #{name} --cpu #{cpu} --json")
    assert {:ok, ^expected} = SSHCommand.parse("new --json --cpu=#{cpu} --name '#{name}'")

    assert {:ok, ^expected} =
             SSHCommand.validate(%{
               "version" => expected.version,
               "command" => expected.command,
               "arguments" => expected.arguments,
               "options" => expected.options
             })
  end

  test "new accepts closed sources from all four providers" do
    for url <- [
          "https://github.com/tastejs/todomvc",
          "https://github.com/o/r/tree/feature/x",
          "https://github.com/o/r/commit/abc1234",
          "https://github.com/o/r/pull/7",
          "https://gitlab.com/group/sub/r/-/tree/main",
          "https://codeberg.org/o/r/pulls/7",
          "https://bitbucket.org/o/r/src/main"
        ] do
      assert {:ok, %{command: "new", options: %{"source" => ^url}}} =
               SSHCommand.parse("new --source #{url} --json")
    end

    for url <- ["https://evil.test/o/r", "https://github.com/o/r/tree/-x", "-o"] do
      assert {:error, :invalid_command} = SSHCommand.parse("new --source '#{url}'")
    end

    assert {:error, :invalid_command} =
             SSHCommand.parse("clone vm-a --source https://github.com/o/r")
  end

  property "arbitrary input never raises or produces a command outside the catalog",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_360_564_909 do
    names = Enum.map(SSHCommand.catalog(), & &1.name)

    (
      value =
        draw(
          "value",
          one_of([OverallsProtocol.TestGenerators.peer_term(), binary(max_length: 9000)])
        )

      case SSHCommand.parse(value) do
        {:ok, command} -> assert command.command in names
        {:error, reason} -> assert reason in [:invalid_command, :command_too_large]
      end

      case SSHCommand.validate(value) do
        {:ok, command} -> assert command.command in names
        {:error, :invalid_command} -> :ok
      end
    )
  end

  test "disk limit applies to text commands and structured API commands" do
    assert {:ok, command} = SSHCommand.parse("new --disk 500")
    assert {:error, :invalid_command} = SSHCommand.parse("new --disk 501")

    assert {:error, :invalid_command} =
             SSHCommand.validate(%{
               "version" => command.version,
               "command" => command.command,
               "arguments" => command.arguments,
               "options" => %{"disk" => "501"}
             })
  end

  test "machine creation accepts a bounded team selector" do
    assert {:ok, %{options: %{"team" => "platform-team"}}} =
             SSHCommand.parse("new --team platform-team")

    assert {:error, :invalid_command} = SSHCommand.parse("new --team Platform")
  end

  test "malformed quoting, unsupported flags, roles, versions and duplicate options fail" do
    for invalid <- [
          "new --name 'unterminated",
          "new --name x --name y",
          "ls --cpu 1",
          "new --cpu -1",
          "new --cpu 01",
          "new --timeout 3601",
          "new --json=false",
          "new --name $(id)",
          "ls; id",
          "ls\nwhoami",
          "share add vm a@example.test root",
          "ssh-key remove nope",
          "help unknown",
          "new --image nonsense",
          "start"
        ] do
      assert SSHCommand.parse(invalid) == {:error, :invalid_command}
    end

    assert SSHCommand.parse(String.duplicate("x", 8193)) == {:error, :command_too_large}

    assert SSHCommand.validate(%{
             "version" => 2,
             "command" => "ls",
             "arguments" => [],
             "options" => %{}
           }) == {:error, :invalid_command}
  end

  test "request IDs and synchronous sharing commands are preserved" do
    assert {:ok,
            %{
              command: "share add",
              arguments: ["vm-one", "a@example.test", "viewer"],
              options: %{"request-id" => "job-17", "json" => true}
            }} =
             SSHCommand.parse(
               "share add vm-one 'a@example.test' viewer --request-id job-17 --json"
             )

    assert {:ok, %{command: "help", arguments: ["share", "add"]}} =
             SSHCommand.parse("help share add")
  end

  test "relocation accepts only a machine and generic physical-operation options" do
    assert {:ok,
            %{
              command: "relocate",
              arguments: ["vm-one"],
              options: %{
                "request-id" => "move-17",
                "timeout" => "300",
                "no-wait" => true,
                "json" => true
              }
            }} =
             SSHCommand.parse(
               "relocate vm-one --request-id move-17 --timeout 300 --no-wait --json"
             )

    assert SSHCommand.physical?("relocate")
    assert SSHCommand.mutation?("relocate")

    for option <- ["--destination host-two", "--host host-two", "--strategy full"] do
      assert {:error, :invalid_command} = SSHCommand.parse("relocate vm-one #{option}")
    end
  end

  test "resize accepts a machine, size options and generic physical-operation options" do
    assert {:ok,
            %{
              command: "resize",
              arguments: ["vm-one"],
              options: %{
                "cpu" => "2",
                "memory" => "2048",
                "disk" => "10",
                "request-id" => "grow-1",
                "no-wait" => true
              }
            }} =
             SSHCommand.parse(
               "resize vm-one --cpu 2 --memory 2048 --disk 10 --request-id grow-1 --no-wait"
             )

    assert {:ok, %{command: "resize", options: %{"cpu" => "4"}}} =
             SSHCommand.parse("resize vm-one --cpu 4")

    assert SSHCommand.physical?("resize")
    assert SSHCommand.mutation?("resize")

    for option <- ["--name bigger", "--disk 501", "--cpu 0", "--profile customer"] do
      assert {:error, :invalid_command} = SSHCommand.parse("resize vm-one #{option}")
    end
  end

  test "pin and unpin take one machine and the generic mutation options only" do
    for name <- ["pin", "unpin"] do
      assert {:ok, %{command: ^name, arguments: ["vm-one"], options: %{"request-id" => "pin-1"}}} =
               SSHCommand.parse("#{name} vm-one --request-id pin-1 --json")

      assert SSHCommand.mutation?(name)
      refute SSHCommand.physical?(name)

      for text <- ["#{name}", "#{name} vm-one vm-two", "#{name} vm-one --timeout 5"] do
        assert {:error, :invalid_command} = SSHCommand.parse(text)
      end
    end

    assert {:error, :invalid_command} = SSHCommand.parse("lock vm-one")
  end

  test "device commands require their options, stdin push keys and canonical identifiers" do
    key = Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
    id = "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b"

    assert {:ok, command} =
             SSHCommand.parse(
               "device register --platform ios --push-key - --enc-pubkey #{key} --label phone --json"
             )

    assert command.command == "device register"
    assert SSHCommand.mutation?("device register")
    refute SSHCommand.physical?("device register")
    assert SSHCommand.stdin_secret?(command)
    push_key = String.duplicate("Ab_-", 8)
    assert {:ok, replaced} = SSHCommand.put_stdin_secret(command, push_key)
    assert replaced.options["push-key"] == push_key
    refute SSHCommand.stdin_secret?(replaced)

    for bad <- ["", "short", "has space in it.......", String.duplicate("A", 701)] do
      assert {:error, :invalid_command} = SSHCommand.put_stdin_secret(command, bad)
    end

    for text <- [
          "device register --platform ios --push-key -",
          "device register --platform windows --push-key - --enc-pubkey #{key}",
          "device register --platform ios --push-key - --enc-pubkey AAAA",
          "device register --platform ios --push-key - --enc-pubkey #{key}=",
          "device register extra --platform ios --push-key - --enc-pubkey #{key}",
          "device ls #{id}",
          "device rm not-a-uuid",
          "device prefs #{id}",
          "device prefs #{id} --enabled yes",
          "device wipe #{id}"
        ] do
      assert {:error, :invalid_command} = SSHCommand.parse(text), text
    end

    assert {:ok, %{command: "device ls"}} = SSHCommand.parse("device ls --json")
    refute SSHCommand.mutation?("device ls")
    assert {:ok, %{arguments: [^id]}} = SSHCommand.parse("device rm #{id}")
    assert SSHCommand.mutation?("device rm")

    assert {:ok, %{options: %{"enabled" => "false"}}} =
             SSHCommand.parse("device prefs #{id} --enabled false")

    assert SSHCommand.mutation?("device prefs")
    assert SSHCommand.device_public_key?(key)
    refute SSHCommand.device_public_key?(nil)

    # The shared Mila fixture's example commands stay valid catalog commands.
    fixture =
      Path.expand("fixtures/porsche_device_results.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    for {name, %{"command" => text, "response" => response}} <- fixture["commands"] do
      assert {:ok, %{command: ^name}} = SSHCommand.parse(text), text
      refute inspect(response) =~ "enc-pubkey"
    end

    for %{"command" => text} <- fixture["refusals"], do: assert({:ok, _} = SSHCommand.parse(text))
  end

  test "integration stdin credential markers are replaced only through shared validation" do
    assert {:ok, command} =
             SSHCommand.parse("integration add api --target https://api.test --bearer -")

    assert SSHCommand.stdin_secret?(command)
    assert {:ok, replaced} = SSHCommand.put_stdin_secret(command, "secret-token")
    assert replaced.options["bearer"] == "secret-token"
    refute SSHCommand.stdin_secret?(replaced)

    assert {:ok, basic} =
             SSHCommand.parse("integration add api --target https://api.test --basic -")

    assert {:ok, replaced} = SSHCommand.put_stdin_secret(basic, "alice:hunter2")
    assert replaced.options["basic"] == "alice:hunter2"
    assert {:error, :invalid_command} = SSHCommand.put_stdin_secret(basic, "missing-colon")

    assert {:error, :invalid_command} =
             SSHCommand.parse(
               "integration add api --target https://api.test --bearer - --basic -"
             )
  end

  test "non-JSON Erlang structures also fail without raising" do
    base = %{"version" => 1, "command" => "show", "arguments" => ["vm"], "options" => %{}}

    assert SSHCommand.validate(%{base | "arguments" => ["vm" | :improper]}) ==
             {:error, :invalid_command}

    assert SSHCommand.validate(%{base | "options" => %URI{}}) == {:error, :invalid_command}
  end
end
