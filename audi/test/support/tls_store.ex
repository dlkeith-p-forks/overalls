defmodule Audi.Test.TLSStore do
  @moduledoc "Starts an isolated, uniquely named TLS store with its read view."

  @doc "Starts the view and store under the test supervisor; returns the store name."
  @spec start!(keyword()) :: atom()
  def start!(options), do: Audi.Test.Writer.start!(Audi.TLS.Store, options)
end

defmodule Audi.Test.DNSDirectory do
  @moduledoc "Starts an isolated, uniquely named DNS directory with its read view."

  @doc "Starts the view and directory under the test supervisor; returns the name."
  @spec start!(keyword()) :: atom()
  def start!(options \\ []), do: Audi.Test.Writer.start!(Audi.DNS.Directory, options)
end

defmodule Audi.Test.Writer do
  @moduledoc "Starts a named single-writer module and its view (`module.children/1`)."
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @spec start!(module(), keyword()) :: atom()
  def start!(module, options) do
    name = :"audi_writer_#{System.unique_integer([:positive])}"

    for child <- module.children(Keyword.put(options, :name, name)) do
      spec = Supervisor.child_spec(child, [])
      start_supervised!(Supervisor.child_spec(spec, id: {spec.id, name}))
    end

    name
  end

  @doc "Kills a started writer and waits until its view has dropped every row."
  @spec stop!(atom(), module()) :: :ok
  def stop!(name, module \\ Audi.DNS.Directory) do
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end

    # The view processes the writer's DOWN asynchronously; a synchronous call
    # after it returns only once that DOWN has been handled.
    _ = :sys.get_state(module.view(name))
    :ok
  end
end
