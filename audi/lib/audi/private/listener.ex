defmodule Audi.Private.Listener do
  @moduledoc "Bounded private TLS listener, separate from public VM ACME subjects."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Bandit.start_link(
      plug: {Audi.Private.Front, opts},
      scheme: :https,
      ip: {169, 254, 254, 1},
      port: 443,
      startup_log: false,
      certfile: opts[:certificate],
      keyfile: opts[:key],
      thousand_island_options: [
        transport_module: Audi.HTTP.TLSTransport,
        num_acceptors: 16,
        num_connections: 128,
        read_timeout: 30_000,
        transport_options: [
          versions: [:"tlsv1.3", :"tlsv1.2"],
          session_tickets: :disabled,
          reuse_sessions: false,
          send_timeout: 5000,
          send_timeout_close: true
        ]
      ],
      http_options: [
        compress: false,
        log_exceptions_with_status_codes: [],
        log_protocol_errors: false,
        log_client_closures: false
      ],
      http_1_options: [
        max_request_line_length: 8192,
        max_header_length: 8192,
        max_header_count: 64,
        max_requests: 100,
        log_unknown_messages: false
      ],
      http_2_options: [enabled: false],
      websocket_options: [enabled: false]
    )
  end
end
