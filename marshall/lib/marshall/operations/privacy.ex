defmodule Marshall.Operations.Privacy do
  @moduledoc "Exclude privileged operator payloads from diagnostics and error returns."
  @catalog Marshall.Events

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:marshall_operator_privacy, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, :marshall_operator_privacy}} -> :ok
    end
  end

  # @cc [owner:ghuntley,label:security] operator-tagged-diagnostics-redacted
  # Tagged operator log events MUST replace their message and retain only the
  # explicit public metadata allowlist before any handler sees them. Untagged
  # events MUST remain available to other filters.
  @spec filter(map(), term()) :: map() | :ignore
  def filter(%{meta: %{marshall_operator: true} = metadata} = event, _) do
    selected =
      case Map.get(metadata, :event) do
        name when is_binary(name) ->
          case Overalls.Diagnostics.Events.Catalog.projection(@catalog, name) do
            %{metadata: declared} ->
              Overalls.Diagnostics.Events.Catalog.safe_metadata(declared, metadata)

            _ ->
              %{}
          end

        _ ->
          %{}
      end

    %{
      event
      | msg: {:string, "Operator process diagnostic (payload redacted)"},
        meta:
          metadata
          |> Map.take([:time, :pid, :gl, :domain, :event])
          |> Map.merge(Overalls.Diagnostics.Context.log_context(metadata))
          |> Map.merge(selected)
    }
  end

  def filter(_, _), do: :ignore

  # @cc [owner:ghuntley,label:security] operator-privacy-restores-context
  # Privacy.run MUST sanitize raised/thrown/exited failures to its fixed error and
  # restore the caller's logger metadata on every exit path, without converting
  # ordinary callback results or exposing exception details.
  @spec run((-> result)) :: result | {:error, :operator_operation_failed_verify_output}
        when result: term()
  def run(fun) do
    original = Logger.metadata()
    Logger.metadata(marshall_operator: true)

    try do
      fun.()
    rescue
      _ -> {:error, :operator_operation_failed_verify_output}
    catch
      _, _ -> {:error, :operator_operation_failed_verify_output}
    after
      Logger.reset_metadata(original)
    end
  end
end
