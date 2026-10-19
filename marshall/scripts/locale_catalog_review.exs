defmodule Marshall.LocaleCatalogReview do
  @moduledoc "Exact, reviewed exceptions for intentionally invariant translation forms."
  @type identity ::
          {String.t(), String.t(), String.t(), String.t() | nil, String.t(), String.t() | nil,
           non_neg_integer()}
  @type review :: %{reason: String.t(), note: String.t()}
  @type reviews :: %{identity() => review()}
  @type observation :: %{source_equal: boolean(), fuzzy: boolean(), invalid: boolean()}
  @type observations :: %{identity() => observation()}

  @fields ~w(app locale domain context msgid msgid_plural form reason note)
  @reasons ~w(brand unit cognate technical_literal)

  @spec load!(String.t()) :: reviews()
  def load!(path), do: path |> File.read!() |> JSON.decode!() |> parse!()

  # @cc [owner:ghuntley,label:verification] reviewed-source-exact-identity
  # Exceptions MUST identify one application, locale, domain, context, source,
  # plural source and form. Duplicate identities and unspecified fields MUST fail.
  @spec parse!(term()) :: reviews()
  def parse!(records) when is_list(records) do
    Enum.reduce(records, %{}, fn record, acc ->
      unless is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@fields),
        do: raise(ArgumentError, "Invalid reviewed source-equality record fields")

      unless Enum.all?(~w(app locale domain msgid note), fn field ->
               is_binary(record[field]) and String.trim(record[field]) != ""
             end) and
               Enum.all?(~w(context msgid_plural), fn field ->
                 is_nil(record[field]) or is_binary(record[field])
               end) and is_integer(record["form"]) and record["form"] >= 0 and
               record["reason"] in @reasons,
             do: raise(ArgumentError, "Invalid reviewed source-equality record values")

      key =
        {record["app"], record["locale"], record["domain"], record["context"], record["msgid"],
         record["msgid_plural"], record["form"]}

      if Map.has_key?(acc, key),
        do: raise(ArgumentError, "Duplicate reviewed source-equality identity: #{inspect(key)}")

      Map.put(acc, key, %{reason: record["reason"], note: record["note"]})
    end)
  end

  def parse!(_records),
    do: raise(ArgumentError, "Reviewed source-equality records must be a list")

  @spec identity(String.t(), String.t(), String.t(), Expo.Message.t(), non_neg_integer()) ::
          identity()
  def identity(app, locale, domain, message, form) do
    plural =
      case message do
        %Expo.Message.Plural{msgid_plural: plural} -> IO.iodata_to_binary(plural)
        %Expo.Message.Singular{} -> nil
      end

    context = if is_nil(message.msgctxt), do: nil, else: IO.iodata_to_binary(message.msgctxt)
    {app, locale, domain, context, IO.iodata_to_binary(message.msgid), plural, form}
  end

  @spec observe(String.t(), String.t(), String.t(), Expo.Message.t(), boolean()) :: observations()
  def observe(app, locale, domain, message, invalid) do
    {sources, forms} =
      case message do
        %Expo.Message.Plural{} ->
          {[IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgid_plural)],
           message.msgstr}

        %Expo.Message.Singular{} ->
          {[IO.iodata_to_binary(message.msgid)], %{0 => message.msgstr}}
      end

    fuzzy = "fuzzy" in List.flatten(message.flags)

    Map.new(forms, fn {index, value} ->
      value = IO.iodata_to_binary(value)

      {identity(app, locale, domain, message, index),
       %{source_equal: value != "" and value in sources, fuzzy: fuzzy, invalid: invalid}}
    end)
  end

  # @cc [owner:ghuntley,label:verification] reviewed-source-no-gap-bypass
  # Every review MUST match a present nonempty source-equal form with valid
  # structure and no fuzzy flag. Stale reviews MUST fail, never widen coverage.
  @spec validate!(reviews(), observations()) :: :ok
  def validate!(reviews, observations) do
    Enum.each(reviews, fn {key, _review} ->
      case Map.fetch(observations, key) do
        {:ok, %{source_equal: true, fuzzy: false, invalid: false}} -> :ok
        _ -> raise ArgumentError, "Stale or ineligible reviewed source equality: #{inspect(key)}"
      end
    end)
  end

  @spec unreviewed_forms(reviews(), observations()) :: non_neg_integer()
  def unreviewed_forms(reviews, observations) do
    Enum.count(observations, fn {key, status} ->
      status.source_equal and not reviewed?(reviews, key)
    end)
  end

  @spec reviewed?(reviews(), identity()) :: boolean()
  def reviewed?(reviews, key), do: Map.has_key?(reviews, key)
end
