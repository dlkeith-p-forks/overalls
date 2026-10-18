defmodule OverallsProtocol.SSHCommand do
  @moduledoc "Porsche v1 command catalog and bounded, shell-independent parser."
  @maximum 8192
  @commands %{
    "help" => {0, 2, [], "help [COMMAND]", "Show command help."},
    "whoami" => {0, 0, [], "whoami", "Show the authenticated account."},
    "images" => {0, 0, [], "images", "List available images."},
    "ls" => {0, 0, ["after"], "ls [--after CURSOR]", "List machines you can access."},
    "show" => {1, 1, [], "show MACHINE", "Inspect a machine by name or UUID."},
    "new" =>
      {0, 0, ["name", "image", "profile", "cpu", "memory", "disk", "team", "source"],
       "new [--name NAME] [--image DIGEST] [--profile PROFILE] [--cpu N] [--memory MIB] [--disk GIB] [--team TEAM] [--source GITHUB_URL]",
       "Create a machine. Disk maximum: 500 GiB. --source clones a public GitHub, GitLab, Codeberg or Bitbucket repository in the guest."},
    "clone" =>
      {1, 1, ["name"], "clone MACHINE [--name NAME]",
       "Queue an independent full-disk copy of a machine."},
    "relocate" =>
      {1, 1, [], "relocate MACHINE", "Move a machine to an automatically selected host."},
    "resize" =>
      {1, 1, ["cpu", "memory", "disk"], "resize MACHINE [--cpu N] [--memory MIB] [--disk GIB]",
       "Change a machine's CPU and memory; disk may only grow. A running machine stops and restarts."},
    "request retry" =>
      {1, 1, [], "request retry REQUEST_ID", "Retry a failed clone or relocation request."},
    "request cancel" =>
      {1, 1, [], "request cancel REQUEST_ID",
       "Cancel an unpublished clone or uncommitted relocation request."},
    "start" => {1, 1, [], "start MACHINE", "Start a machine."},
    "pause" => {1, 1, [], "pause MACHINE", "Suspend a machine, preserving its memory and disk."},
    "resume" =>
      {1, 1, [], "resume MACHINE", "Resume preserved memory, waiting for capacity or relocation."},
    "unpause" => {1, 1, [], "unpause MACHINE", "Resume a suspended machine's preserved memory."},
    "stop" =>
      {1, 1, [], "stop MACHINE",
       "Stop a machine, retaining its disk and discarding suspended memory."},
    "rm" =>
      {1, 1, [], "rm MACHINE",
       "Delete a machine and its disk. Refused while its owner has it pinned."},
    "pin" =>
      {1, 1, [], "pin MACHINE",
       "Pin a machine to the top of your lists. Your owner pin wakes it, prevents automatic suspension, and prevents deletion."},
    "unpin" => {1, 1, [], "unpin MACHINE", "Remove your pin from a machine."},
    "share show" =>
      {1, 1, ["after"], "share show MACHINE [--after CURSOR]", "List access grants."},
    "share add" =>
      {3, 3, [], "share add MACHINE EMAIL ROLE", "Grant viewer, operator or manager access."},
    "share remove" =>
      {2, 2, [], "share remove MACHINE EMAIL", "Revoke an account's shared access."},
    "ssh-key list" => {0, 0, [], "ssh-key list", "List your SSH keys."},
    "ssh-key remove" => {1, 1, [], "ssh-key remove UUID", "Revoke one of your SSH keys."},
    "integration add" =>
      {1, 1,
       [
         "target",
         "header",
         "bearer",
         "basic",
         "strip-prefix",
         "peer",
         "peer-vm",
         "team",
         "attach"
       ],
       "integration add NAME --target URL [--header NAME:VALUE] [--bearer TOKEN] [--basic USER:PASS] [--strip-prefix PATH] [--peer --peer-vm MACHINE] [--team TEAM] [--attach MACHINE]",
       "Create or replace a named integration at https://NAME.integration.internal."},
    "integration rm" => {1, 1, [], "integration rm NAME", "Remove a named integration."},
    "integration list" =>
      {0, 0, ["after"], "integration list [--after CURSOR]", "List your integrations."},
    "integration show" =>
      {1, 1, [], "integration show NAME", "Inspect an integration without secrets."},
    "integration attach" =>
      {2, 2, [], "integration attach NAME MACHINE", "Make an integration available to a machine."},
    "integration detach" =>
      {2, 2, [], "integration detach NAME MACHINE", "Remove a machine's explicit availability."},
    "team create" => {1, 1, [], "team create NAME", "Create a team you own."},
    "team list" => {0, 0, ["after"], "team list [--after CURSOR]", "List your teams and roles."},
    "team show" => {1, 1, [], "team show TEAM", "List a team's members."},
    "team member add" =>
      {3, 3, [], "team member add TEAM EMAIL ROLE", "Add or change an admin or member."},
    "team member remove" =>
      {2, 2, [], "team member remove TEAM EMAIL", "Remove an account's membership."},
    "team transfer offer" =>
      {2, 2, [], "team transfer offer TEAM EMAIL", "Offer team ownership to an admin."},
    "team transfer accept" =>
      {1, 1, [], "team transfer accept TRANSFER_ID", "Accept a pending ownership offer."},
    "team transfer decline" =>
      {1, 1, [], "team transfer decline TRANSFER_ID", "Decline a pending ownership offer."},
    "team transfer cancel" =>
      {1, 1, [], "team transfer cancel TRANSFER_ID", "Cancel your pending ownership offer."},
    "request show" =>
      {1, 1, [], "request show REQUEST_ID", "Inspect a previously accepted request."},
    "exit" => {0, 0, [], "exit", "Close this interactive channel."}
  }
  @physical [
    "new",
    "start",
    "pause",
    "resume",
    "unpause",
    "stop",
    "rm",
    "clone",
    "relocate",
    "resize",
    "request retry",
    "request cancel"
  ]

  # Pins are durable mutations with no physical operation: no receipt wait.
  @mutations @physical ++
               [
                 "pin",
                 "unpin",
                 "share add",
                 "share remove",
                 "ssh-key remove",
                 "integration add",
                 "integration rm",
                 "integration attach",
                 "integration detach",
                 "team create",
                 "team member add",
                 "team member remove",
                 "team transfer offer",
                 "team transfer accept",
                 "team transfer decline",
                 "team transfer cancel"
               ]
  # @cc [owner:ghuntley,label:protocol] ssh-peer-flag-no-value
  # The advertised integration --peer flag MUST parse without consuming the
  # next argument. Boolean parsing MUST NOT permit flags outside a command's catalog.
  @booleans ["json", "no-wait", "peer"]
  @type t :: %{version: 1, command: binary(), arguments: [binary()], options: map()}
  @type error :: :invalid_command | :command_too_large

  @spec catalog() :: [map()]
  def catalog do
    @commands
    |> Enum.sort()
    |> Enum.map(fn {name, {_, _, _, usage, summary}} ->
      %{
        name: name,
        usage: usage,
        summary: summary,
        options: options(name),
        mutation: name in @mutations
      }
    end)
  end

  @spec mutation?(binary()) :: boolean()
  def mutation?(name), do: name in @mutations
  @spec physical?(binary()) :: boolean()
  def physical?(name), do: name in @physical

  # @cc [owner:ghuntley,label:security] command-parser-no-shell
  # Parsing MUST never invoke a shell, evaluate substitutions or create atoms from
  # client text. Exec and interactive input MUST use this same bounded grammar.
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(text) when is_binary(text) and byte_size(text) > @maximum,
    do: {:error, :command_too_large}

  def parse(text) when is_binary(text) do
    with true <- String.valid?(text),
         false <- String.contains?(text, [<<0>>, "\n", "\r"]),
         {:ok, tokens} <- lex(text, :plain, false, [], [], false),
         {:ok, name, rest} <- command(tokens),
         {:ok, arguments, options} <- arguments(rest, [], %{}, false) do
      validate(%{
        "version" => 1,
        "command" => name,
        "arguments" => arguments,
        "options" => options
      })
    else
      _ -> {:error, :invalid_command}
    end
  end

  def parse(_), do: {:error, :invalid_command}

  # @cc [owner:ghuntley,label:protocol] ssh-command-closed-version
  # Gateway wire commands MUST use the exact v1 envelope, finite command/option
  # catalog and bounded values. Parsing success MUST NOT imply authorization.

  # @cc [owner:ghuntley,label:security;capacity] ssh-relocation-has-no-placement-input
  # `relocate` MUST accept exactly one machine reference plus generic mutation/wait
  # options. It MUST NOT accept a destination, placement or transfer strategy.
  @spec validate(term()) :: {:ok, t()} | {:error, error()}
  def validate(
        %{"version" => 1, "command" => name, "arguments" => args, "options" => opts} = wire
      )
      when map_size(wire) == 4 and is_binary(name) and is_list(args) and is_map(opts) do
    with {minimum, maximum, _, _, _} <- Map.get(@commands, name),
         true <- bounded_arguments?(args, minimum, maximum),
         true <- map_size(opts) <= 12,
         true <-
           Enum.all?(Map.to_list(opts), fn {key, value} ->
             key in options(name) and option?(key, value)
           end),
         true <- command_options_valid?(name, opts),
         true <- arguments_valid?(name, args) do
      {:ok, %{version: 1, command: name, arguments: args, options: opts}}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def validate(_), do: {:error, :invalid_command}

  defp bounded_arguments?([], minimum, _maximum), do: minimum <= 0

  defp bounded_arguments?([value | rest], minimum, maximum) when maximum > 0,
    do: text?(value) and bounded_arguments?(rest, minimum - 1, maximum - 1)

  defp bounded_arguments?(_, _, _), do: false

  @spec name?(term()) :: boolean()
  def name?(name), do: OverallsProtocol.MachineName.valid?(name)

  defp options(name) do
    {_, _, extra, _, _} = Map.fetch!(@commands, name)

    ["json" | extra] ++
      if(name in @mutations, do: ["request-id"], else: []) ++
      if(name in @physical, do: ["timeout", "no-wait"], else: [])
  end

  defp command(["team", sub, sub2 | rest]) when sub in ["member", "transfer"],
    do: {:ok, "team " <> sub <> " " <> sub2, rest}

  defp command([group, sub | rest])
       when group in ["share", "ssh-key", "request", "integration", "team"],
       do: {:ok, group <> " " <> sub, rest}

  defp command([name | rest]), do: {:ok, name, rest}
  defp command(_), do: :error

  defp arguments([], args, opts, _), do: {:ok, Enum.reverse(args), opts}
  defp arguments(["--" | rest], args, opts, false), do: arguments(rest, args, opts, true)

  defp arguments(["--" <> flag | rest], args, opts, false) do
    case String.split(flag, "=", parts: 2) do
      [key, value] ->
        put_option(rest, args, opts, key, value)

      [key] when key in @booleans ->
        put_option(rest, args, opts, key, true)

      [key] ->
        case rest do
          [value | tail] -> put_option(tail, args, opts, key, value)
          _ -> :error
        end
    end
  end

  defp arguments([arg | rest], args, opts, positional),
    do: arguments(rest, [arg | args], opts, positional)

  defp put_option(rest, args, opts, key, value) do
    cond do
      Map.has_key?(opts, key) and key != "header" ->
        :error

      key == "header" ->
        updated =
          case opts do
            %{"header" => [_ | _] = previous} -> %{"header" => previous ++ [value]}
            %{"header" => single} -> %{"header" => [single, value]}
            _ -> %{"header" => value}
          end

        arguments(rest, args, Map.merge(opts, updated), false)

      true ->
        arguments(rest, args, Map.put(opts, key, value), false)
    end
  end

  defp option?(key, value) when key in @booleans, do: is_boolean(value)
  defp option?("name", value), do: name?(value)
  defp option?("after", value), do: OverallsProtocol.uuid?(value)

  defp option?("target", value) when is_binary(value),
    do: match?({:ok, _}, OverallsProtocol.Integration.target(value))

  defp option?("target", _), do: false

  defp option?("header", value) when is_binary(value), do: header?(value)
  defp option?("header", values) when is_list(values), do: Enum.all?(values, &header?/1)

  defp option?("header", _), do: false

  defp option?("bearer", "-"), do: true

  defp option?("bearer", value),
    do: match?({:ok, _}, OverallsProtocol.Integration.bearer_credential(value))

  defp option?("basic", "-"), do: true

  defp option?("basic", value),
    do: match?({:ok, _}, OverallsProtocol.Integration.basic_credential(value))

  defp option?("strip-prefix", value) when is_binary(value),
    do: match?({:ok, _}, OverallsProtocol.Integration.strip_prefix(value))

  defp option?("strip-prefix", _), do: false
  defp option?("peer", value), do: is_boolean(value)
  defp option?("peer-vm", value), do: machine?(value)

  defp option?("team", value) when is_binary(value),
    do:
      byte_size(value) in 1..63 and
        Regex.match?(~r/\A[a-z][a-z0-9-]{0,61}[a-z0-9]\z|\A[a-z]\z/, value)

  defp option?("team", _), do: false
  defp option?("attach", value), do: machine?(value)

  defp option?("image", value) when is_binary(value),
    do: byte_size(value) == 71 and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp option?("profile", value), do: value in ["customer", "standard", "oss", "inception"]

  defp option?("source", value),
    do: match?({:ok, _}, OverallsProtocol.WorkspaceSource.parse_url(value))

  defp option?("request-id", value), do: request_id?(value)
  defp option?("timeout", value), do: positive?(value, 3600)

  # @cc [owner:ghuntley,label:product] ssh-disk-limit
  # Explicit disk options MUST reject sizes above the shared 500 GiB VM limit.
  defp option?("disk", value), do: positive?(value, OverallsProtocol.VMShape.maximum_disk_gib())

  defp option?(key, value) when key in ["cpu", "memory"],
    do: positive?(value, 2_147_483_647)

  defp option?(_, _), do: false

  defp command_options_valid?("integration add", options),
    do: not (Map.has_key?(options, "bearer") and Map.has_key?(options, "basic"))

  defp command_options_valid?(_, _), do: true

  defp positive?(value, maximum) when is_binary(value) and byte_size(value) in 1..10 do
    case Integer.parse(value) do
      {n, ""} -> n > 0 and n <= maximum and Integer.to_string(n) == value
      _ -> false
    end
  end

  defp positive?(_, _), do: false

  defp text?(value) when is_binary(value) and byte_size(value) in 1..4096,
    do:
      String.valid?(value) and String.printable?(value) and
        not String.contains?(value, ["\n", "\r"])

  defp text?(_), do: false

  defp request_id?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, value)

  defp request_id?(_), do: false

  defp header?(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [name, header_value] ->
        match?({:ok, _}, OverallsProtocol.Integration.static_header([name, header_value]))

      _ ->
        false
    end
  end

  defp header?(_), do: false

  defp machine?(value), do: name?(value) or OverallsProtocol.uuid?(value)

  # @cc [owner:ghuntley,label:security;protocol] ssh-command-stdin-secret
  # Only an integration-add bearer/basic value of `-` may request stdin. Exactly
  # one marker is allowed, and replacement MUST validate the bounded secret
  # through the shared integration credential constraint before dispatch.
  @spec stdin_secret?(t()) :: boolean()
  def stdin_secret?(%{command: "integration add", options: options}) do
    Enum.count([options["bearer"], options["basic"]], &(&1 == "-")) == 1
  end

  def stdin_secret?(_), do: false

  @spec put_stdin_secret(t(), term()) :: {:ok, t()} | {:error, :invalid_command}
  def put_stdin_secret(%{command: "integration add", options: options} = command, secret)
      when is_binary(secret) do
    with true <- stdin_secret?(command),
         {kind, "-"} <- Enum.find(options, fn {_key, value} -> value == "-" end),
         true <- stdin_credential?(kind, secret) do
      validate(%{
        "version" => command.version,
        "command" => command.command,
        "arguments" => command.arguments,
        "options" => Map.put(options, kind, secret)
      })
    else
      _ -> {:error, :invalid_command}
    end
  end

  def put_stdin_secret(_, _), do: {:error, :invalid_command}

  defp stdin_credential?("bearer", value),
    do: match?({:ok, _}, OverallsProtocol.Integration.bearer_credential(value))

  defp stdin_credential?("basic", value),
    do: match?({:ok, _}, OverallsProtocol.Integration.basic_credential(value))

  defp arguments_valid?(name, [machine])
       when name in [
              "show",
              "start",
              "pause",
              "resume",
              "unpause",
              "stop",
              "rm",
              "pin",
              "unpin",
              "clone",
              "relocate",
              "resize",
              "share show"
            ],
       do: machine?(machine)

  defp arguments_valid?("share add", [machine, email, role]),
    do:
      machine?(machine) and byte_size(email) <= 320 and role in ["viewer", "operator", "manager"]

  defp arguments_valid?("share remove", [machine, email]),
    do: machine?(machine) and byte_size(email) <= 320

  defp arguments_valid?("ssh-key remove", [id]), do: OverallsProtocol.uuid?(id)

  defp arguments_valid?("integration add", [name]),
    do: OverallsProtocol.Integration.name?(name)

  defp arguments_valid?(name, [name_arg])
       when name in ["integration rm", "integration show", "team create", "team show"] do
    if String.starts_with?(name, "integration"),
      do: OverallsProtocol.Integration.name?(name_arg),
      else: byte_size(name_arg) in 1..63
  end

  defp arguments_valid?(name, [machine, machine2])
       when name in ["integration attach", "integration detach"],
       do: OverallsProtocol.Integration.name?(machine) and machine?(machine2)

  defp arguments_valid?("team member add", [team, email, role]),
    do: byte_size(team) in 1..63 and byte_size(email) <= 320 and role in ["admin", "member"]

  defp arguments_valid?(name, [team, email])
       when name in ["team member remove", "team transfer offer"],
       do: byte_size(team) in 1..63 and byte_size(email) <= 320

  defp arguments_valid?(name, [id])
       when name in ["team transfer accept", "team transfer decline", "team transfer cancel"],
       do: OverallsProtocol.uuid?(id)

  defp arguments_valid?(name, [id])
       when name in ["request show", "request retry", "request cancel"], do: request_id?(id)

  defp arguments_valid?("help", []), do: true
  defp arguments_valid?("help", args), do: Map.has_key?(@commands, Enum.join(args, " "))
  defp arguments_valid?(_, []), do: true
  defp arguments_valid?(_, _), do: false

  defp lex(_, _, _, _, tokens, _) when length(tokens) > 32, do: :error

  defp lex(<<>>, :plain, started, current, tokens, false),
    do: {:ok, Enum.reverse(finish(started, current, tokens))}

  defp lex(<<>>, _, _, _, _, _), do: :error

  defp lex(<<byte, rest::binary>>, mode, _, current, tokens, true),
    do: lex(rest, mode, true, [byte | current], tokens, false)

  defp lex(<<?\\, rest::binary>>, mode, _, current, tokens, false) when mode != :single,
    do: lex(rest, mode, true, current, tokens, true)

  defp lex(<<?', rest::binary>>, :plain, _, current, tokens, false),
    do: lex(rest, :single, true, current, tokens, false)

  defp lex(<<?', rest::binary>>, :single, _, current, tokens, false),
    do: lex(rest, :plain, true, current, tokens, false)

  defp lex(<<?", rest::binary>>, :plain, _, current, tokens, false),
    do: lex(rest, :double, true, current, tokens, false)

  defp lex(<<?", rest::binary>>, :double, _, current, tokens, false),
    do: lex(rest, :plain, true, current, tokens, false)

  defp lex(<<byte, rest::binary>>, :plain, started, current, tokens, false) when byte in [32, 9],
    do: lex(rest, :plain, false, [], finish(started, current, tokens), false)

  defp lex(<<byte, rest::binary>>, mode, _, current, tokens, false),
    do: lex(rest, mode, true, [byte | current], tokens, false)

  defp finish(false, _, tokens), do: tokens

  defp finish(true, current, tokens),
    do: [current |> Enum.reverse() |> :erlang.list_to_binary() | tokens]
end
