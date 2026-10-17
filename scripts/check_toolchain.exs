# @cc [owner:ghuntley,label:build] exact-runtime-gate
# Runtime validation MUST compare both Elixir and the full OTP patch version to
# .tool-versions and fail before project verification on either mismatch.
versions =
  Path.expand("../.tool-versions", __DIR__)
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Map.new(fn line ->
    [name, version] = String.split(line)
    {name, version}
  end)

expected_elixir = versions["elixir"] |> String.split("-otp-", parts: 2) |> hd()
expected_otp = Map.fetch!(versions, "erlang")
otp_major = :erlang.system_info(:otp_release) |> List.to_string()

actual_otp =
  [:code.root_dir() |> List.to_string(), "releases", otp_major, "OTP_VERSION"]
  |> Path.join()
  |> File.read!()
  |> String.trim()

unless System.version() == expected_elixir and actual_otp == expected_otp do
  raise "Expected Elixir #{expected_elixir}/OTP #{expected_otp}, " <>
          "got Elixir #{System.version()}/OTP #{actual_otp}. Enter `devenv shell` first."
end

IO.puts("Toolchain check passed (Elixir #{expected_elixir}, OTP #{actual_otp}).")
