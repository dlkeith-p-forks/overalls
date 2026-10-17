# @cc [owner:ghuntley,label:capacity] inception-enable-after-native-report
# The inner host MUST remain disabled until production enrollment readiness
# accepts a fresh native report. No fabricated inventory may enable it.
Application.put_env(:marshall, :operator_mode, true)
{:ok, _} = Application.ensure_all_started(:marshall)
%{"host_id" => host} = "/var/lib/inception/lilly.json" |> File.read!() |> JSON.decode!()

case Marshall.Compute.Enrollment.set_enabled(host, true) do
  {:ok, _} -> Code.eval_file(Path.join(__DIR__, "ziggy.exs"))
  _ -> System.halt(1)
end
