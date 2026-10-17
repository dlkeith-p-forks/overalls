# xterm.js addons

Vendored from the official scoped npm packages (MIT), matching the vendored
xterm.js 6.0.0 runtime:

| File | Package | Version | Verified tarball integrity |
|---|---|---|---|
| `addon-fit.mjs` | `@xterm/addon-fit` | 0.11.0 | `sha512-jYcgT6xtVYhnhgxh3QgYDnnNMYTcf8ElbxxFzX0IZo+vabQqSPAjC3c1wJrKB5E19VwQei89QCiZZP86DCPF7g==` |
| `addon-unicode11.mjs` | `@xterm/addon-unicode11` | 0.9.0 | `sha512-FxDnYcyuXhNl+XSqGZL/t0U9eiNb/q3EWT5rYkQT/zuig8Gz/VagnQANKHdDWFM2lTMk9ly0EFQxxxtZUoRetw==` |
| `addon-search.mjs` | `@xterm/addon-search` | 0.16.0 | `sha512-9OeuBFu0/uZJPu+9AHKY6g/w0Czyb/Ut0A5t79I4ULoU4IfU5BEpPFVGQxP4zTTMdfZEYkVIRYbHBX1xWwjeSA==` |
| `addon-image.mjs` | `@xterm/addon-image` | 0.9.0 | `sha512-oYWA8/QAr5/Emwl1xL7WCoOqeG3IZfpzEz/OVq1j4Oi9934TQmHiyubClikRf0D/jL3JNiNuz/Lsqx0kXQ02BA==` |

Only the compiled ESM is included; source-map comments are removed because
their maps are not shipped. Import these files through the existing app
bundles. Review upstream security changes, verify new tarballs against npm
integrity and rerun the browser terminal checks when updating.
