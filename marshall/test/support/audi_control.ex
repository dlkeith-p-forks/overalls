defmodule Marshall.AudiControl do
  @moduledoc "Test helper: connects a real Audi control client to a Marshall control endpoint."

  @doc "Starts the client's control link under the test supervisor and waits for its welcome."
  @spec connect(Audi.Control.Client.t()) :: Audi.Control.Client.t()
  def connect(client) do
    client = %{client | control: :"marshall_audi_control_#{System.unique_integer([:positive])}"}
    ExUnit.Callbacks.start_supervised!({Audi.Control.Link, client}, id: client.control)
    wait(client.control, 250)
    client
  end

  @spec wait(atom(), non_neg_integer()) :: :ok
  defp wait(control, 0), do: raise("Audi control client #{control} never connected")

  defp wait(control, attempts) do
    if Process.whereis(control) && OverallsProtocol.Control.Client.ready?(control) do
      :ok
    else
      Process.sleep(20)
      wait(control, attempts - 1)
    end
  end
end

defmodule Marshall.AudiControl.FleetPlug do
  @moduledoc "Test plug: the fleet listener's control upgrade, then the Audi and provisioner HTTPS routes."
  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    Enum.reduce_while(
      [MarshallWeb.ControlAPI, MarshallWeb.IngressAPI, MarshallWeb.ProvisionerAPI],
      conn,
      fn plug, conn ->
        conn = plug.call(conn, [])
        if conn.halted or conn.state != :unset, do: {:halt, conn}, else: {:cont, conn}
      end
    )
  end
end

defmodule Marshall.LillyControl do
  @moduledoc "Test helper: connects a real Lilly control client to a control endpoint."

  @doc """
  Starts the client's control link under the test supervisor and waits up to
  about a second for its welcome; a link that cannot connect (refused upgrade,
  untrusted certificate) is left for the test to observe.
  """
  @spec connect(Lilly.Control.Client.t()) :: Lilly.Control.Client.t()
  def connect(client) do
    client = %{client | control: :"marshall_lilly_control_#{System.unique_integer([:positive])}"}
    ExUnit.Callbacks.start_supervised!({Lilly.Control.Link, client}, id: client.control)
    wait(client.control, 50)
    client
  end

  @spec wait(atom(), non_neg_integer()) :: :ok
  defp wait(_control, 0), do: :ok

  defp wait(control, attempts) do
    if Process.whereis(control) && OverallsProtocol.Control.Client.ready?(control) do
      :ok
    else
      Process.sleep(20)
      wait(control, attempts - 1)
    end
  end
end
