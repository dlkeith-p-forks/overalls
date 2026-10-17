defmodule Lilly.Control.Client do
  @moduledoc """
  Lilly's requests to Marshall over the control WebSocket (ADR-0142): bounded,
  never retried or queued, with closed error classes and no credential-bearing
  errors. The struct names the `OverallsProtocol.Control.Client` that
  `Lilly.Control.Link` owns.
  """
  require Lilly.Events
  alias OverallsProtocol.Execution
  @derive {Inspect, except: [:token]}
  @deadline 5_000
  @enforce_keys [:base_url, :host_id, :token]
  defstruct [
    :base_url,
    :host_id,
    :token,
    :cacertfile,
    :machine_id,
    protocol_version: 4,
    allow_insecure_loopback: false,
    control: Lilly.ControlClient
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          host_id: String.t(),
          token: String.t(),
          cacertfile: String.t() | nil,
          machine_id: String.t() | nil,
          protocol_version: 4,
          allow_insecure_loopback: boolean(),
          control: GenServer.server()
        }
  @type session :: %{
          required(:session_id) => OverallsProtocol.uuid(),
          required(:epoch) => pos_integer(),
          required(:pools) => [map()]
        }
  @type error ::
          :invalid_configuration
          | :transport_error
          | :message_too_large
          | :invalid_message
          | :unauthorized
          | :stale_connection
          | :stale_report
          | :invalid_report
          | :invalid_acknowledgement
          | :reconciliation_required
          | :unsupported_version
          | :temporarily_unavailable
          | :http_error
          | :machine_identity_mismatch
          | :invalid_outcome
          | :outcome_conflict

  # @cc [owner:ghuntley,label:security] authenticated-origin-configuration
  # new/4 MUST require an HTTPS origin without userinfo, query, fragment or application path;
  # plain HTTP is permitted only for explicitly enabled literal IPv4 loopback test origins.
  # IPv6 literals MUST be rejected and outbound transport MUST disable IPv6.
  @spec new(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_configuration}
  def new(base_url, host_id, token, options \\ []) do
    with true <- is_binary(base_url) and is_binary(token) and byte_size(token) == 80,
         {:ok, uri} <- URI.new(base_url),
         true <-
           is_binary(uri.host) and uri.host != "" and not String.contains?(uri.host, ":") and
             uri.userinfo == nil and uri.query == nil and
             uri.fragment == nil and uri.path in [nil, "/"],
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host == "127.0.0.1" and
                Keyword.get(options, :allow_insecure_loopback, false)),
         true <- OverallsProtocol.uuid?(host_id),
         cert = Keyword.get(options, :cacertfile),
         true <- is_nil(cert) or is_binary(cert),
         version = Keyword.get(options, :protocol_version, 4),
         machine = Keyword.get(options, :machine_id),
         allow_insecure_loopback = Keyword.get(options, :allow_insecure_loopback, false),
         true <- is_boolean(allow_insecure_loopback),
         control = Keyword.get(options, :control, Lilly.ControlClient),
         true <- is_atom(control),
         true <-
           version == 4 and Execution.machine_id?(machine) do
      {:ok,
       %__MODULE__{
         base_url: String.trim_trailing(base_url, "/"),
         host_id: host_id,
         token: token,
         cacertfile: cert,
         protocol_version: version,
         machine_id: machine,
         allow_insecure_loopback: allow_insecure_loopback,
         control: control
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  @spec exchange_inception(t(), session(), OverallsProtocol.Execution.command(), map() | nil) ::
          {:ok, map()} | {:error, error()}
  def exchange_inception(client, session, command, result) do
    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "vm_id" => command.vm_id,
      "placement_id" => command.placement_id,
      "execution_epoch" => command.execution_epoch,
      "generation" => command.generation,
      "result" => result
    }

    started = System.monotonic_time(:millisecond)

    with {:ok, _} <- OverallsProtocol.InceptionControl.request(message),
         {:ok, response} <- request(client, "inception", message),
         {:ok, offer} <- OverallsProtocol.InceptionControl.offer(response),
         true <-
           offer.host_id == client.host_id and offer.session_id == session.session_id and
             offer.epoch == session.epoch and offer.vm_id == command.vm_id and
             offer.placement_id == command.placement_id and
             offer.execution_epoch == command.execution_epoch and
             offer.generation == command.generation,
         true <- System.monotonic_time(:millisecond) < started + offer.ttl_ms do
      {:ok, Map.put(offer, :deadline, started + offer.ttl_ms)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  @spec exchange_clone(t(), session(), [map()]) :: {:ok, map()} | {:error, error()}
  def exchange_clone(client, session, results) do
    message = %{
      "version" => 5,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => results
    }

    with {:ok, _} <- OverallsProtocol.CloneControl.exchange(message),
         {:ok, response} <- request(client, "clone", message),
         %{
           "version" => 5,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- OverallsProtocol.CloneControl.commands(commands),
         true <- Enum.all?(commands, &(&1["host_id"] == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1["id"] == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  end

  @spec open(t(), OverallsProtocol.uuid()) :: {:ok, session()} | {:error, error()}
  def open(client, session_id) do
    version = client.protocol_version

    message = %{
      "version" => version,
      "session_id" => session_id,
      "machine_id" => client.machine_id
    }

    with {:ok, _} <- Execution.session(message),
         {:ok, response} <- request(client, "sessions", message),
         %{
           "version" => ^version,
           "host_id" => host,
           "session_id" => ^session_id,
           "epoch" => epoch,
           "pools" => pools,
           "report_interval_ms" => 1000
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and valid_epoch?(epoch) and valid_pools?(pools) do
      {:ok, %{session_id: session_id, epoch: epoch, pools: pools}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  # @cc [owner:ghuntley,label:protocol] execution-response-correlated
  # exchange_execution/5 MUST validate the response host/session/epoch and every command host
  # before returning commands; outcome acknowledgements must be distinct, bounded and drawn only
  # from the outcomes sent in this request.
  @spec exchange_execution(
          t(),
          session(),
          OverallsProtocol.report() | nil,
          [OverallsProtocol.uuid()],
          [Execution.outcome()]
        ) ::
          {:ok,
           %{commands: [Execution.command()], outcome_acknowledgements: [OverallsProtocol.uuid()]}}
          | {:error, error()}
  def exchange_execution(
        %{protocol_version: 4} = client,
        session,
        report,
        acknowledgements,
        outcomes
      ) do
    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "report" => OverallsProtocol.encode_report(report),
      "acknowledgements" => acknowledgements,
      "outcomes" => Enum.map(outcomes, &Execution.encode_outcome/1)
    }

    with {:ok, _} <- Execution.exchange(message |> JSON.encode!() |> JSON.decode!()),
         {:ok, response} <- request(client, "exchange", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "outcome_acknowledgements" => accepted
         } <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- Execution.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == client.host_id)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(outcomes, &(&1.id == id)) end) do
      {:ok, %{commands: commands, outcome_acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  end

  def exchange_execution(_, _, _, _, _), do: {:error, :unsupported_version}

  # @cc [owner:ghuntley,label:security;protocol] relocation-revocation-response-correlated
  # Source revocation MUST match the authenticated host/session/epoch and every
  # command host. Acknowledgements MUST be unique and drawn only from submitted
  # results. The closed schema never carries private key material or local paths.
  @spec exchange_relocation_revocation(t(), session(), [
          OverallsProtocol.RelocationRevocation.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationRevocation.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_revocation(client, session, results) do
    codec = OverallsProtocol.RelocationRevocation

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_revocation", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] destination-revocation-response-correlated
  # Destination revocation MUST match the authenticated host/session/epoch and every
  # command host. Acknowledgements MUST be unique and drawn only from submitted
  # results. The closed schema never carries private key material or local paths.
  @spec exchange_relocation_destination_revocation(t(), session(), [
          OverallsProtocol.RelocationDestinationRevocation.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationDestinationRevocation.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_destination_revocation(client, session, results) do
    codec = OverallsProtocol.RelocationDestinationRevocation

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_destination_revocation", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] destination-cleanup-response-correlated
  # Destination cleanup MUST match the authenticated host/session/epoch and every
  # command host. Acknowledgements MUST be unique and drawn only from submitted
  # results. The closed schema never carries private key material or local paths.
  @spec exchange_relocation_destination_cleanup(t(), session(), [
          OverallsProtocol.RelocationDestinationCleanup.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationDestinationCleanup.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_destination_cleanup(client, session, results) do
    codec = OverallsProtocol.RelocationDestinationCleanup

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_destination_cleanup", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.intent.destination.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] relocation-snapshot-cleanup-response-correlated
  # Source snapshot cleanup MUST match the authenticated host/session/epoch and every
  # command host. Acknowledgements MUST be unique and drawn only from submitted
  # results. The closed schema never carries private key material or local paths.
  @spec exchange_relocation_snapshot_cleanup(t(), session(), [
          OverallsProtocol.RelocationSnapshotCleanup.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationSnapshotCleanup.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_snapshot_cleanup(client, session, results) do
    codec = OverallsProtocol.RelocationSnapshotCleanup

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_snapshot_cleanup", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] relocation-key-response-correlated
  # Key retirement MUST match the authenticated host/session/epoch and every
  # command host. Acknowledgements MUST be unique and drawn only from submitted
  # results. The closed schema never carries private key material or local paths.
  @spec exchange_relocation_key_retirement(t(), session(), [
          OverallsProtocol.RelocationKeyRetirement.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationKeyRetirement.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_key_retirement(client, session, results) do
    codec = OverallsProtocol.RelocationKeyRetirement

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_key_retirement", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] relocation-key-preparation-response-correlated
  # Key preparation responses MUST match the authenticated host/session/epoch
  # and each command's destination host. Acknowledgements MUST be unique and refer
  # only to submitted request IDs. Unknown fields reject the entire response.
  @spec exchange_relocation_keys(t(), session(), [OverallsProtocol.RelocationKeys.result()]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationKeys.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_keys(client, session, results) do
    codec = OverallsProtocol.RelocationKeys

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_keys", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end) do
      {:ok, %{commands: commands, acknowledgements: accepted}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_message}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] source-response-correlated
  # Key preparation responses MUST match the authenticated host/session/epoch
  # and each command's destination host. Acknowledgements MUST be unique and refer
  # only to submitted request IDs. Unknown fields reject the entire response.
  @spec exchange_relocation_source(t(), session(), [OverallsProtocol.RelocationSource.result()]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationSource.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_source(client, session, results) do
    codec = OverallsProtocol.RelocationSource

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_source", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.intent.source.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] probe-response-correlated
  # Probe responses MUST match the authenticated host/session/epoch and select
  # the source for grants or destination for probes. Acknowledgements MUST be unique and refer
  # only to submitted request IDs. Unknown fields reject the entire response.
  @spec exchange_relocation_probe(t(), session(), [OverallsProtocol.RelocationProbe.result()]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationProbe.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_probe(client, session, results) do
    codec = OverallsProtocol.RelocationProbe

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_probe", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <-
           Enum.all?(commands, fn command ->
             endpoint =
               if command.phase == :grant,
                 do: command.intent.source,
                 else: command.intent.destination

             endpoint.host_id == host
           end),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] receive-response-correlated
  # Receive responses MUST match the current host/session/epoch and destination
  # host in every descriptor. Acknowledgements MUST be unique submitted IDs;
  # malformed responses MUST NOT start or extend a native receive.
  @spec exchange_relocation_receive(
          t(),
          session(),
          [OverallsProtocol.RelocationReceive.result()]
        ) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationReceive.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_receive(client, session, results) do
    codec = OverallsProtocol.RelocationReceive

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_receive", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.descriptor.destination.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] import-response-correlated
  # Import responses MUST match the current host/session/epoch and destination
  # host in every descriptor. Acknowledgements MUST be unique submitted IDs;
  # malformed responses MUST NOT start or extend a native adoption.
  @spec exchange_relocation_import(t(), session(), [OverallsProtocol.RelocationImport.result()]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationImport.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_import(client, session, results) do
    codec = OverallsProtocol.RelocationImport

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_import", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.descriptor.destination.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] readiness-response-correlated
  # Readiness responses MUST match the current host/session/epoch and destination
  # host in every descriptor. Acknowledgements MUST be unique submitted IDs;
  # malformed responses MUST NOT start or extend a guest probe.
  @spec exchange_relocation_readiness(t(), session(), [
          OverallsProtocol.RelocationReadiness.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationReadiness.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_readiness(client, session, results) do
    codec = OverallsProtocol.RelocationReadiness

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_readiness", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.descriptor.destination.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;protocol] cleanup-response-correlated
  # Cleanup replies MUST match host/session/epoch and the source in every
  # descriptor. Acknowledgements MUST be unique submitted IDs; malformed replies
  # MUST NOT authorize source destruction.
  @spec exchange_relocation_cleanup(t(), session(), [
          OverallsProtocol.RelocationCleanup.result()
        ]) ::
          {:ok,
           %{
             commands: [OverallsProtocol.RelocationCleanup.command()],
             acknowledgements: [String.t()]
           }}
          | {:error, error()}
  def exchange_relocation_cleanup(client, session, results) do
    codec = OverallsProtocol.RelocationCleanup

    message = %{
      "version" => 4,
      "session_id" => session.session_id,
      "epoch" => session.epoch,
      "results" => Enum.map(results, &codec.encode_result/1)
    }

    with {:ok, _} <- codec.exchange(message),
         {:ok, response} <- request(client, "relocation_cleanup", message),
         %{
           "version" => 4,
           "host_id" => host,
           "session_id" => id,
           "epoch" => epoch,
           "commands" => commands,
           "acknowledgements" => accepted
         }
         when map_size(response) == 6 <- response,
         true <- host == client.host_id and id == session.session_id and epoch == session.epoch,
         {:ok, commands} <- codec.commands(commands),
         true <- Enum.all?(commands, &(&1.descriptor.source.host_id == host)),
         true <- is_list(accepted) and length(accepted) <= 16 and Enum.uniq(accepted) == accepted,
         true <- Enum.all?(accepted, fn id -> Enum.any?(results, &(&1.id == id)) end),
         do: {:ok, %{commands: commands, acknowledgements: accepted}},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :invalid_message}
         )
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  # @cc [owner:ghuntley,label:security;recovery] https-request-no-hidden-redelivery
  # request/3 MUST send each authenticated exchange once over the verified
  # control socket, never retried or queued (a dropped socket is unproven), and
  # bound request bodies to the protocol maximum. Credentials MUST NOT be
  # exposed through transport errors.

  # @cc [owner:ghuntley,label:security;observability] exchange-failure-diagnostics-closed
  # Failed exchanges MUST report only the fixed utility atom, host UUID and a
  # closed reason atom. Bodies, tokens, URLs and transport payloads MUST NOT
  # enter diagnostics; transient transport reasons stay silent because the
  # callers' bounded retry loops already own their deduped availability events.
  defp request(client, action, message) do
    result =
      if byte_size(JSON.encode!(message)) > OverallsProtocol.max_body() do
        {:error, :message_too_large}
      else
        client.control
        |> OverallsProtocol.Control.Client.request("lilly." <> action, message, @deadline)
        |> response(client)
      end

    reported(result, client, action)
  catch
    :exit, _ -> reported({:error, :transport_error}, client, action)
  end

  defp reported({:error, :transport_error} = result, _, _), do: result
  defp reported({:error, :temporarily_unavailable} = result, _, _), do: result

  defp reported({:error, reason} = result, client, action) when is_atom(reason) do
    Lilly.Events.emit("lilly.control_exchange_failed",
      host_id: client.host_id,
      utility: utility(action),
      reason: reason
    )

    result
  end

  defp reported(result, _, _), do: result

  defp utility("sessions"), do: :session
  defp utility("exchange"), do: :execution
  defp utility("clone"), do: :clone
  defp utility("relocation_keys"), do: :relocation_keys
  defp utility("relocation_key_retirement"), do: :relocation_key_retirement
  defp utility("relocation_source"), do: :relocation_source
  defp utility("relocation_probe"), do: :relocation_probe
  defp utility("relocation_receive"), do: :relocation_receive
  defp utility("relocation_import"), do: :relocation_import
  defp utility("relocation_readiness"), do: :relocation_readiness
  defp utility("relocation_cleanup"), do: :relocation_cleanup
  defp utility("relocation_revocation"), do: :relocation_revocation
  defp utility("relocation_destination_revocation"), do: :relocation_destination_revocation
  defp utility("relocation_destination_cleanup"), do: :relocation_destination_cleanup
  defp utility("relocation_snapshot_cleanup"), do: :relocation_snapshot_cleanup
  defp utility(_), do: :unknown

  @refusals ~w(unauthorized machine_identity_mismatch message_too_large unsupported_version
               temporarily_unavailable stale_connection stale_report outcome_conflict
               reconciliation_required invalid_report invalid_outcome invalid_acknowledgement)

  # @cc [owner:ghuntley,label:security;recovery] lilly-control-error-classes
  # Marshall's closed refusal names MUST map to the same atoms the HTTPS
  # statuses produced; any other name is an http_error with a closed reason.
  # A dropped, timed-out or busy socket is a transport_error, except a version
  # refusal at upgrade or close, which keeps unsupported_version.
  @spec response({:ok, map()} | {:error, OverallsProtocol.Control.Client.request_error()}, t()) ::
          {:ok, map()} | {:error, error()}
  defp response({:ok, value}, _client) when is_map(value) do
    if byte_size(JSON.encode!(value)) <= OverallsProtocol.max_body(),
      do: {:ok, value},
      else: {:error, :message_too_large}
  end

  defp response({:error, name}, _client) when name in @refusals,
    do: {:error, String.to_existing_atom(name)}

  defp response({:error, name}, _client) when is_binary(name) do
    Lilly.Events.emit("lilly.control_request_refused", reason: safe_response_reason(name))
    {:error, :http_error}
  end

  # @cc [owner:ghuntley,label:protocol;recovery] lilly-pending-terminal-version-refusal
  # Already-dispatched work retired as unproven MUST preserve unsupported_version
  # when its current owner holds that terminal refusal. Other loss MUST remain
  # transport_error; classification MUST NOT retry or establish a domain outcome.
  defp response({:error, reason}, client) when reason in [:disconnected, :unproven] do
    case OverallsProtocol.Control.Client.status(client.control) do
      {:disconnected, :unsupported_version} -> {:error, :unsupported_version}
      _ -> {:error, :transport_error}
    end
  end

  defp response({:error, _reason}, _client), do: {:error, :transport_error}

  defp safe_response_reason("invalid_request"), do: :invalid_request
  defp safe_response_reason("invalid_message"), do: :invalid_message
  defp safe_response_reason("transaction_failed"), do: :transaction_failed
  defp safe_response_reason(_name), do: :unknown

  defp valid_epoch?(epoch), do: is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807

  defp valid_pools?(pools) when is_list(pools) and length(pools) <= 64 do
    Enum.all?(pools, fn
      %{"id" => id, "name" => name, "filesystem_id" => fs} = pool ->
        OverallsProtocol.uuid?(id) and is_binary(name) and byte_size(name) in 1..128 and
          is_binary(fs) and byte_size(fs) in 1..256 and valid_storage?(pool)

      _ ->
        false
    end) and length(Enum.uniq_by(pools, & &1["id"])) == length(pools)
  end

  defp valid_pools?(_), do: false

  # Session pool descriptors carry exactly id, name, filesystem_id and storage.
  defp valid_storage?(%{"storage" => storage, "filesystem_id" => fs} = pool)
       when map_size(pool) == 4 do
    with {:ok, identity} <- OverallsProtocol.Storage.identity(storage),
         do: OverallsProtocol.Storage.filesystem_id(identity) == fs,
         else: (_ -> false)
  end

  defp valid_storage?(_), do: false
end
