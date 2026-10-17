# Mermaid

Mermaid 11.12.0, MIT. Bundled with esbuild 0.25.5 from the npm integrity-pinned
package-lock.json in this directory. The bundle includes upstream license notices.
Reproduce in a temporary directory with this lock and a package.json declaring
exact dependencies mermaid 11.12.0 and esbuild 0.25.5, then `npm ci --ignore-scripts`:

```
node_modules/.bin/esbuild node_modules/mermaid/dist/mermaid.esm.mjs --bundle --minify --format=esm --supported:template-literal=false --outfile=mermaid.mjs --legal-comments=eof
sed -i 's/[[:blank:]]*$//' mermaid.mjs
```

No runtime CDN or network dependency. Application policy belongs in js/handbook.js.
