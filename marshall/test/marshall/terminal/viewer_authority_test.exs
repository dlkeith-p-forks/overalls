defmodule Marshall.Terminal.ViewerAuthorityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Terminal.ViewerAuthority

  @backstop ViewerAuthority.backstop_ms()

  @spec result() :: StreamData.t(ViewerAuthority.result())
  defp result do
    one_of([
      constant(:ok),
      constant(:inconclusive),
      map(member_of([:authority_login, :authority_session, :authority_host]), &{:error, &1})
    ])
  end

  # @cc [owner:ghuntley,label:verification;security] viewer-authority-backstop-property
  # For any sequence of recheck results and monotonic gaps, the model MUST
  # refuse exactly at the first conclusive refusal or once an uninterrupted
  # inconclusive episode reaches the backstop, and never otherwise.
  property "only conclusive refusals or an expired inconclusive episode close the viewer" do
    check all(
            steps <- list_of(tuple({result(), integer(0..20_000)}), min_length: 1, max_length: 40)
          ) do
      Enum.reduce_while(steps, {nil, nil, 0}, fn {result, gap}, {since, episode, now} ->
        now = now + gap
        episode = if result == :inconclusive, do: episode || now, else: nil

        expected =
          case result do
            {:error, reason} -> {:refuse, reason}
            :ok -> {:ok, nil}
            :inconclusive when now - episode >= @backstop -> {:refuse, :authority_unconfirmed}
            :inconclusive -> {:ok, episode}
          end

        assert ViewerAuthority.step(since, result, now) == expected

        case expected do
          {:ok, next} -> {:cont, {next, episode, now}}
          {:refuse, _} -> {:halt, :closed}
        end
      end)
    end
  end
end
