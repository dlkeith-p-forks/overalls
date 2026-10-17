defmodule Audi.HTTP.Listener do
  @moduledoc "Bounded HTTP/1.1 listener using the repository's pinned Bandit stack."

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  # @cc [owner:ghuntley,label:security] audi-http-listener-bounds
  # Public HTTP parsing MUST have finite header, request-line, connection and
  # idle limits. TLS MUST use the per-VM SNI store without a default certificate
  # or session resumption bypass. Protocol errors MUST NOT log peer input.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    scheme = Keyword.fetch!(options, :scheme)
    store = Keyword.fetch!(options, :store)

    transport =
      case scheme do
        :http ->
          []

        :https ->
          [
            alpn_preferred_protocols: ["http/1.1"],
            sni_fun: &Audi.TLS.Store.sni(store, &1),
            versions: [:"tlsv1.3", :"tlsv1.2"],
            session_tickets: :disabled,
            reuse_sessions: false
          ]
      end

    Bandit.start_link(
      plug:
        {Audi.HTTP.Front,
         store: store,
         https_port: Keyword.get(options, :https_port, 443),
         client: options[:client],
         connector: options[:connector],
         zone: options[:zone],
         browser_origin: options[:browser_origin],
         editor_assets: options[:editor_assets],
         tls_options: transport,
         trusted_proxy_peer: options[:trusted_proxy_peer]},
      scheme: :http,
      ip: Keyword.get(options, :ip, {127, 0, 0, 1}),
      port: Keyword.fetch!(options, :port),
      startup_log: false,
      thousand_island_options: [
        transport_module: ThousandIsland.Transports.TCP,
        handler_module:
          if(scheme == :https, do: Audi.Inception.Front, else: Bandit.DelegatingHandler),
        num_acceptors: 4,
        num_connections: 32,
        read_timeout: 5000,
        shutdown_timeout: 1000,
        transport_options: [send_timeout: 1000, send_timeout_close: true, buffer: 65_536]
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
      websocket_options: [
        enabled: true,
        compress: false,
        max_frame_size: 1_048_576,
        max_fragmented_message_size: 1_048_576,
        validate_text_frames: true,
        log_protocol_errors: false
      ]
    )
  end
end
