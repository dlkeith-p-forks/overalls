# noVNC 1.7.0

Vendored from https://github.com/novnc/noVNC at commit
`63107bd06d9e1f6136ff21aeda8cd62cbf0d433e` (tag `v1.7.0`).
All files under `core/`, `vendor/pako/`, `docs/LICENSE.*`, and `LICENSE.txt`
are unmodified upstream files. The incoming 43 core/license files matched this
release byte for byte. The Pako ES-module adaptation is the version included by
this exact noVNC release, based on Pako 1.0.3; its MIT license is included.
`upstream.json` records SHA-256 integrity for every vendored upstream file.

To reproduce, check out that exact commit from the repository above and copy
`core/`, `vendor/pako/`, `docs/LICENSE.*`, and `LICENSE.txt` into this directory.
Verify each file against `upstream.json`; review hooks and rebuild the application
bundles before changing the pin. Keep upstream notices and license texts intact.

Marshall imports `core/rfb.js` through its application bundle. noVNC performs
asynchronous codec detection with top-level await, so the esbuild output uses
ES modules and the root layout loads the application with `type="module"`.
The client and its compression dependency are served from the application origin;
there are no runtime CDN imports or local patches to upstream source.
