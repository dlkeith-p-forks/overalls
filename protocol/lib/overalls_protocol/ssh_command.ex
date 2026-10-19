defmodule OverallsProtocol.SSHCommand do
  @moduledoc "Porsche v1 command catalog and bounded, shell-independent parser."
  @maximum 8192
  @commands %{
    "help" => {0, 3, [], "help [COMMAND]", "Show command help."},
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
    "thread ls" =>
      {0, 0, ["machine", "after"], "thread ls [--machine MACHINE] [--after CURSOR]",
       "List agent threads you can read, with unread counts."},
    "thread show" =>
      {1, 1, [], "thread show THREAD", "Inspect a thread, its pending question and latest plan."},
    "thread turns" =>
      {1, 1, ["after"], "thread turns THREAD [--after SEQUENCE]",
       "List a thread's transcript events after a sequence number."},
    "thread prompt" =>
      {2, 2, [], "thread prompt THREAD -", "Send a prompt read from standard input to a thread."},
    "thread answer" =>
      {3, 3, [], "thread answer THREAD QUESTION -",
       "Answer a thread's pending question with JSON read from standard input."},
    "thread plan approve" =>
      {2, 2, [], "thread plan approve THREAD PLAN",
       "Approve a thread's latest plan and start implementing it."},
    "thread plan revise" =>
      {3, 3, [], "thread plan revise THREAD PLAN -",
       "Ask for a revised plan, reading the feedback from standard input."},
    "thread mode" =>
      {2, 2, [], "thread mode THREAD plan|work",
       "Switch a thread between plan and work collaboration."},
    "thread read" =>
      {2, 2, [], "thread read THREAD SEQUENCE",
       "Mark a thread read up to a transcript sequence number."},
    "terminal ls" =>
      {1, 1, [], "terminal ls MACHINE", "List a machine's terminal sessions you can open."},
    "terminal new" =>
      {1, 1, [], "terminal new MACHINE", "Open your personal terminal session on a machine."},
    "terminal kill" =>
      {2, 2, [], "terminal kill MACHINE SESSION",
       "Close one of your terminal sessions on a machine."},
    "web show" =>
      {1, 1, [], "web show MACHINE", "Show a machine's web endpoint, port and visibility."},
    "web set" =>
      {1, 1, ["port", "public", "private", "revision"],
       "web set MACHINE [--port N] [--public|--private] [--revision R]",
       "Change a machine's web port or visibility, optionally at an expected revision."},
    "watch" =>
      {0, 0, ["machine", "thread", "session"],
       "watch [--machine MACHINE]... [--thread THREAD]... [--session]",
       "Stream JSON change notices for machines, threads and this session."},
    "device register" =>
      {0, 0, ["platform", "push-key", "enc-pubkey", "label"],
       "device register --platform ios|android --push-key - --enc-pubkey KEY [--label LABEL]",
       "Register this device for push notifications. The push key is read from stdin."},
    "device ls" => {0, 0, [], "device ls", "List your push notification devices."},
    "device rm" => {1, 1, [], "device rm DEVICE_ID", "Revoke a push notification device."},
    "device prefs" =>
      {1, 1, ["enabled"], "device prefs DEVICE_ID --enabled true|false",
       "Turn push notifications on or off for one device."},
    "exit" => {0, 0, [], "exit", "Close this interactive channel."},
    "terminal attach" =>
      {2, 2, ["cursor", "read-only"],
       "terminal attach MACHINE SESSION [--cursor N] [--read-only]",
       "Attach this SSH terminal to a shared terminal session; needs ssh -t."}
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
                 "team transfer cancel",
                 "device register",
                 "device rm",
                 "device prefs",
                 "thread prompt",
                 "thread answer",
                 "thread plan approve",
                 "thread plan revise",
                 "thread mode",
                 "thread read",
                 "terminal new",
                 "terminal kill",
                 "web set"
               ]
  # @cc [owner:ghuntley,label:protocol] ssh-peer-flag-no-value
  # The advertised integration --peer flag MUST parse without consuming the
  # next argument. Boolean parsing MUST NOT permit flags outside a command's catalog.
  @booleans ["json", "no-wait", "peer", "public", "private", "read-only", "session"]
  # Options that may repeat; a repeated value collects into a list.
  @repeatable ["header", "machine", "thread"]
  # @cc [owner:ghuntley,label:security;capacity] ssh-command-stdin-payload-bounded
  # Prompt, answer and plan-revision text MUST arrive on stdin (the final `-`
  # argument), at most 64 KiB of valid UTF-8 without NUL, and only through
  # put_stdin_payload/2. A command line MUST NOT carry the payload option itself.
  @payloads %{
    "thread prompt" => {:prompt, 65_536},
    "thread answer" => {:answers, 65_536},
    "thread plan revise" => {:revision, 65_536}
  }
  @secret_limit 4098
  # Watch filters stay small: each names one subscription.
  @watch_filters 16
  @type t :: %{version: 1, command: binary(), arguments: [binary()], options: map()}
  @type error :: :invalid_command | :command_too_large
  @type payload_kind :: :secret | :prompt | :answers | :revision

  @spec catalog() :: [map()]
  def catalog do
    @commands
    |> Enum.sort()
    |> Enum.map(fn {name, {_, _, _, usage, summary}} ->
      %{
        name: name,
        usage: usage,
        summary: summary,
        options: options(name) -- ["stdin"],
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
         {:ok, arguments, options} <- arguments(rest, [], %{}, false),
         false <- Map.has_key?(options, "stdin") do
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

  @doc """
  Formats a validated command as one canonical line that `parse/1` reads back
  to the same command (Mila's encoder uses the same quoting). A command whose
  stdin payload is already supplied has no line form.
  """
  @spec format(t()) :: {:ok, binary()} | {:error, error()}
  def format(%{options: %{"stdin" => _}}), do: {:error, :invalid_command}

  def format(%{version: 1, command: name, arguments: args, options: opts} = command)
      when is_binary(name) and is_list(args) and is_map(opts) do
    with {:ok, ^command} <-
           validate(%{"version" => 1, "command" => name, "arguments" => args, "options" => opts}) do
      flags =
        opts
        |> Enum.sort()
        |> Enum.flat_map(fn
          {key, true} ->
            ["--" <> key]

          {key, values} when is_list(values) ->
            Enum.map(values, &("--" <> key <> "=" <> quote_token(&1)))

          {key, value} ->
            ["--" <> key <> "=" <> quote_token(value)]
        end)

      separator = if Enum.any?(args, &String.starts_with?(&1, "--")), do: ["--"], else: []
      tokens = String.split(name, " ") ++ flags ++ separator ++ Enum.map(args, &quote_token/1)
      line = Enum.join(tokens, " ")

      if length(tokens) <= 32 and byte_size(line) <= @maximum,
        do: {:ok, line},
        else: {:error, :command_too_large}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def format(_), do: {:error, :invalid_command}

  @spec quote_token(binary()) :: binary()
  defp quote_token(token) do
    if Regex.match?(~r/\A[A-Za-z0-9@%+=:,.\/_-]+\z/, token),
      do: token,
      else: "'" <> String.replace(token, "'", "'\\''") <> "'"
  end

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
             key in options(name) and command_option?(name, key, value)
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
      if(Map.has_key?(@payloads, name), do: ["stdin"], else: []) ++
      if(name in @mutations, do: ["request-id"], else: []) ++
      if(name in @physical, do: ["timeout", "no-wait"], else: [])
  end

  defp command(["team", sub, sub2 | rest]) when sub in ["member", "transfer"],
    do: {:ok, "team " <> sub <> " " <> sub2, rest}

  defp command(["thread", "plan", sub | rest]), do: {:ok, "thread plan " <> sub, rest}

  defp command([group, sub | rest])
       when group in [
              "share",
              "ssh-key",
              "request",
              "integration",
              "team",
              "device",
              "thread",
              "terminal",
              "web"
            ],
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
      Map.has_key?(opts, key) and key not in @repeatable ->
        :error

      key in @repeatable ->
        updated =
          case opts do
            %{^key => [_ | _] = previous} -> previous ++ [value]
            %{^key => single} -> [single, value]
            _ -> value
          end

        arguments(rest, args, Map.put(opts, key, updated), false)

      true ->
        arguments(rest, args, Map.put(opts, key, value), false)
    end
  end

  # Option values whose grammar depends on the command; everything else is
  # validated by the shared per-key grammar below.
  @spec command_option?(binary(), binary(), term()) :: boolean()
  defp command_option?("thread turns", "after", value), do: sequence?(value)

  defp command_option?(name, key, value)
       when name != "watch" and key in ["machine", "thread"] and is_list(value),
       do: false

  defp command_option?("thread ls", "machine", value), do: machine?(value)

  defp command_option?("watch", key, values)
       when key in ["machine", "thread"] and is_list(values),
       do:
         length(values) <= @watch_filters and
           Enum.all?(values, &command_option?("watch", key, &1))

  defp command_option?("watch", "machine", value), do: machine?(value)
  defp command_option?("watch", "thread", value), do: OverallsProtocol.uuid?(value)
  defp command_option?("web set", "port", value), do: positive?(value, 65_535)
  defp command_option?("web set", "revision", value), do: positive?(value, 2_147_483_647)
  defp command_option?(name, "stdin", value), do: stdin_text?(name, value)

  defp command_option?(_name, key, value), do: option?(key, value)

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

  # @cc [owner:ghuntley,label:protocol;security] ssh-device-register-options
  # Device registration MUST name a closed platform and a raw 32-byte X25519
  # public key, and SHOULD read the Susan push key from stdin (`-`). A literal
  # push key is accepted only in the opaque Susan key alphabet and bounds.
  defp option?("platform", value), do: value in ["ios", "android"]
  defp option?("push-key", "-"), do: true
  defp option?("push-key", value), do: OverallsProtocol.SusanPoke.push_key?(value)
  defp option?("enc-pubkey", value), do: device_public_key?(value)
  defp option?("enabled", value), do: value in ["true", "false"]

  defp option?("label", value) when is_binary(value),
    do: byte_size(value) in 1..64 and text?(value)

  defp option?("label", _), do: false

  defp option?("request-id", value), do: request_id?(value)
  defp option?("cursor", value), do: cursor?(value)
  defp option?("timeout", value), do: positive?(value, 3600)

  # @cc [owner:ghuntley,label:product] ssh-disk-limit
  # Explicit disk options MUST reject sizes above the shared 500 GiB VM limit.
  defp option?("disk", value), do: positive?(value, OverallsProtocol.VMShape.maximum_disk_gib())

  defp option?(key, value) when key in ["cpu", "memory"],
    do: positive?(value, 2_147_483_647)

  defp option?(_, _), do: false

  defp command_options_valid?("integration add", options),
    do: not (Map.has_key?(options, "bearer") and Map.has_key?(options, "basic"))

  defp command_options_valid?("device register", options),
    do: Enum.all?(["platform", "push-key", "enc-pubkey"], &Map.has_key?(options, &1))

  defp command_options_valid?("device prefs", options), do: Map.has_key?(options, "enabled")

  # A web change names at least one setting and never both visibilities.
  defp command_options_valid?("web set", options),
    do:
      not (Map.has_key?(options, "public") and Map.has_key?(options, "private")) and
        Enum.any?(["port", "public", "private"], &Map.has_key?(options, &1))

  defp command_options_valid?("watch", options),
    do: Enum.any?(["machine", "thread", "session"], &Map.has_key?(options, &1))

  defp command_options_valid?(_, _), do: true

  @doc "True for a base64url (unpadded) raw 32-byte X25519 public key."
  @spec device_public_key?(term()) :: boolean()
  def device_public_key?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<_::binary-size(32)>> = raw} -> Base.url_encode64(raw, padding: false) == value
      _ -> false
    end
  end

  def device_public_key?(_), do: false

  # Transcript sequences start at 1; zero names the position before the first.
  defp sequence?(value) when is_binary(value) and byte_size(value) in 1..10 do
    case Integer.parse(value) do
      {n, ""} -> n >= 0 and n <= 2_147_483_647 and Integer.to_string(n) == value
      _ -> false
    end
  end

  defp sequence?(_), do: false

  defp positive?(value, maximum) when is_binary(value) and byte_size(value) in 1..10 do
    case Integer.parse(value) do
      {n, ""} -> n > 0 and n <= maximum and Integer.to_string(n) == value
      _ -> false
    end
  end

  defp positive?(_, _), do: false

  # A replay cursor is a canonical non-negative signed 64-bit byte offset.
  defp cursor?(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {n, ""} -> n >= 0 and n <= 9_223_372_036_854_775_807 and Integer.to_string(n) == value
      _ -> false
    end
  end

  defp cursor?(_), do: false

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

  # @cc [owner:ghuntley,label:security;protocol] ssh-terminal-attach-not-printed
  # `terminal attach` is a read that returns a single-use terminal ticket
  # (ADR-0223). It MUST NOT be a mutation, so its ticket is never pinned in a
  # receipt, and gateways MUST dispatch it only from a PTY attach channel that
  # consumes the ticket without printing it.
  @spec attach?(t()) :: boolean()
  def attach?(%{command: "terminal attach"}), do: true
  def attach?(_), do: false

  # @cc [owner:ghuntley,label:security;protocol] ssh-command-stdin-secret
  # Only an integration-add bearer/basic value of `-`, or a device-register
  # push key of `-`, may request a stdin secret. Exactly one marker is allowed,
  # and replacement MUST validate the bounded secret through the shared
  # integration credential or Susan push-key constraint before dispatch.
  @spec stdin_secret?(t()) :: boolean()
  def stdin_secret?(command), do: match?({:secret, _}, stdin_payload?(command))

  @doc """
  The stdin payload a validated command still needs, as its kind and byte
  limit, or `false` once supplied (or when the command reads no stdin).
  """
  @spec stdin_payload?(t()) :: {payload_kind(), pos_integer()} | false
  def stdin_payload?(%{command: "integration add", options: options}) do
    if Enum.count([options["bearer"], options["basic"]], &(&1 == "-")) == 1,
      do: {:secret, @secret_limit},
      else: false
  end

  def stdin_payload?(%{command: name, options: options}) when is_map_key(@payloads, name) do
    if Map.has_key?(options, "stdin"), do: false, else: Map.fetch!(@payloads, name)
  end

  def stdin_payload?(%{command: "device register", options: %{"push-key" => "-"}}),
    do: {:secret, @secret_limit}

  def stdin_payload?(_), do: false

  @doc """
  Supplies a command's stdin bytes: a secret replaces its `-` option value;
  other payloads join the options as `stdin` after their grammar and limit
  check. Anything else refuses before dispatch.
  """
  @spec put_stdin_payload(t(), term()) :: {:ok, t()} | {:error, :invalid_command}
  def put_stdin_payload(command, bytes) when is_binary(bytes) do
    case stdin_payload?(command) do
      {:secret, _} ->
        put_stdin_secret(command, bytes)

      {_kind, limit} when byte_size(bytes) <= limit ->
        validate(%{
          "version" => command.version,
          "command" => command.command,
          "arguments" => command.arguments,
          "options" => Map.put(command.options, "stdin", bytes)
        })

      _ ->
        {:error, :invalid_command}
    end
  end

  def put_stdin_payload(_, _), do: {:error, :invalid_command}

  @spec stdin_text?(binary(), term()) :: boolean()
  defp stdin_text?(name, value) when is_binary(value) do
    case Map.fetch(@payloads, name) do
      {:ok, {kind, limit}} ->
        byte_size(value) in 1..limit and String.valid?(value) and
          not String.contains?(value, <<0>>) and payload_grammar?(kind, value)

      :error ->
        false
    end
  end

  defp stdin_text?(_, _), do: false

  # Answers are one JSON object; Marshall validates it against the question.
  defp payload_grammar?(:answers, value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) -> true
      _ -> false
    end
  end

  defp payload_grammar?(_kind, value), do: String.trim(value) != ""

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

  def put_stdin_secret(%{command: "device register", options: options} = command, secret)
      when is_binary(secret) do
    with true <- stdin_secret?(command),
         true <- OverallsProtocol.SusanPoke.push_key?(secret) do
      validate(%{
        "version" => command.version,
        "command" => command.command,
        "arguments" => command.arguments,
        "options" => Map.put(options, "push-key", secret)
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

  defp arguments_valid?(name, [id]) when name in ["device rm", "device prefs"],
    do: OverallsProtocol.uuid?(id)

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

  defp arguments_valid?(name, [thread]) when name in ["thread show", "thread turns"],
    do: OverallsProtocol.uuid?(thread)

  defp arguments_valid?("thread prompt", [thread, "-"]), do: OverallsProtocol.uuid?(thread)

  defp arguments_valid?("thread answer", [thread, question, "-"]),
    do: OverallsProtocol.uuid?(thread) and OverallsProtocol.uuid?(question)

  defp arguments_valid?("thread plan approve", [thread, plan]),
    do: OverallsProtocol.uuid?(thread) and OverallsProtocol.uuid?(plan)

  defp arguments_valid?("thread plan revise", [thread, plan, "-"]),
    do: OverallsProtocol.uuid?(thread) and OverallsProtocol.uuid?(plan)

  defp arguments_valid?("thread mode", [thread, mode]),
    do: OverallsProtocol.uuid?(thread) and mode in ["plan", "work"]

  defp arguments_valid?("thread read", [thread, sequence]),
    do: OverallsProtocol.uuid?(thread) and sequence?(sequence)

  defp arguments_valid?(name, [machine])
       when name in ["terminal ls", "terminal new", "web show", "web set"],
       do: machine?(machine)

  defp arguments_valid?(name, [machine, session])
       when name in ["terminal kill", "terminal attach"],
    do: machine?(machine) and OverallsProtocol.uuid?(session)

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
