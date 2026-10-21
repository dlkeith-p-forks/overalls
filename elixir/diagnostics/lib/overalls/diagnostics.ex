defmodule Overalls.Diagnostics do
  @moduledoc """
  Shared, reviewed diagnostics infrastructure for the Overalls applications.

  Producers use the concern-specific modules under this namespace. Event names
  and metadata remain owned by each application's `Events` catalog.
  """

  @type service ::
          :marshall
          | :lilly
          | :audi
          | :porsche
          | :brady
          | :ziggy
          | :enrico
          | :galileo
          | :susan
          | :peach
  @type metadata :: %{optional(atom()) => atom() | binary() | integer() | nil} | keyword()
  @type custody :: :ok | {:error, :invalid | :unavailable | :refused}
end
