# Shared localization catalogs

`generate_catalogs.py` converts Marshall's canonical Gettext catalogs into a
stable, platform-neutral JSON intermediate consumed by native client build
steps. Message identity preserves domain, context, source id, and plural forms.

```sh
python3 mila/localization/generate_catalogs.py \
  --source marshall/priv/gettext --output build/mila-localization
```

The generator sorts locales, domains, and messages and writes a schema-versioned
`manifest.json`; rerunning it with the same catalogs is byte-for-byte identical.
It validates duplicate identities and interpolation placeholders while preserving
empty source fallback forms for the existing catalog completeness gate.
