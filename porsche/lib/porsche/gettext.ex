defmodule Porsche.Gettext do
  @moduledoc "Translation backend for Porsche human-facing terminal output."
  use Gettext.Backend,
    otp_app: :porsche,
    interpolation: Porsche.GettextInterpolation,
    plural_forms: Porsche.GettextPlural
end
