defmodule Porsche.Health do
  @moduledoc "Point-in-time listener and authenticated control-plane readiness."

  # @cc [owner:ghuntley,label:security;recovery] porsche-readiness-live-authority
  # Readiness MUST require the managed SSH daemon before and after a bounded,
  # verified HTTPS gateway readiness request. Only the exact affirmative response
  # may succeed. Failures MUST return false without credentials or remote details;
  # no session creation, retries or local authorization cache may substitute.
  @spec ready?(Porsche.Client.t(), GenServer.server(), keyword()) :: boolean()
  def ready?(client, listener \\ Porsche.Listener, options \\ []) do
    request = Keyword.get(options, :request, &Porsche.Client.request/4)

    Porsche.Listener.ready?(listener) and
      request.(client, "ready", %{"version" => 1}, timeout: 5000) ==
        {:ok, %{"ready" => true}} and Porsche.Listener.ready?(listener)
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
