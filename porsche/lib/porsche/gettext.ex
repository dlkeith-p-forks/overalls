defmodule Porsche.Gettext do
  @moduledoc "Translation backend for Porsche human-facing terminal output."
  use Gettext.Backend, otp_app: :porsche
end
