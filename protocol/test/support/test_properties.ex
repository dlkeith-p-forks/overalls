defmodule OverallsProtocol.TestProperties do
  @moduledoc false

  # @cc [owner:ghuntley,label:security] protocol-property-draw-redaction
  # Property draw diagnostics MUST record only a literal label and a redaction
  # marker. Generated terminal bytes, credentials and payloads MUST NOT enter
  # Hegel's replay printer. Drawing MUST retain native shrinking and exceptions.
  @spec draw(Macro.t(), Macro.t()) :: Macro.t()
  defmacro draw(label, generator) when is_binary(label) do
    quote do
      test_case = :hegel.current_test_case()
      :hegel.note(test_case, unquote(label) <> " = <redacted>")
      :hegel.draw_silent(test_case, unquote(generator))
    end
  end
end
