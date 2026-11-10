// [plugin-pages] Builds the page plugin host into App/Resources/PluginHost/:
//   plugin-host.js   React + ReactDOM (production) + host.jsx, one minified IIFE
//   plugin-host.css  host.css as is (Tailwind compiles it in the page)
//   tailwind.js      @tailwindcss/browser, which compiles a plugin's utility classes in the page
// Usage: cd scripts/plugin-host && npm ci && node build.mjs
// (No node on PATH? The Hermes install has one: ~/.hermes/tools/node-*/bin/node.)

import { build } from "esbuild";
import { copyFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "../../App/Resources/PluginHost");
mkdirSync(out, { recursive: true });

const versions = ["react", "react-dom", "@tailwindcss/browser"].map((name) => {
  const pkg = JSON.parse(readFileSync(join(here, "node_modules", name, "package.json"), "utf8"));
  return `${name} ${pkg.version}`;
});

await build({
  entryPoints: [join(here, "host.jsx")],
  outfile: join(out, "plugin-host.js"),
  bundle: true,
  format: "iife",
  minify: true,
  target: ["safari16"],
  jsx: "transform",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "eof",
  banner: { js: `/* Hermes HQ page plugin host (scripts/plugin-host). Bundles ${versions.join(", ")}; MIT licensed. */` },
});

copyFileSync(join(here, "host.css"), join(out, "plugin-host.css"));
copyFileSync(join(here, "node_modules/@tailwindcss/browser/dist/index.global.js"), join(out, "tailwind.js"));
console.log(`built ${out} (${versions.join(", ")})`);
