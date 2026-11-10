// Builds the desktop theme's CSS into App/Resources/DesktopTheme/hermes-hq-theme.js from the readable sources in
// scripts/desktop-theme/ (one file per area, loaded in the order of scripts/desktop-theme/ORDER). The bundled file
// carries the CSS minified (comments out, whitespace collapsed, one rule per line), because the phone only installs a
// plugin up to DesktopThemeInstall.maxBytes and older installs only take a published look up to 192 KB of CSS.
// Usage: node scripts/desktop-theme-build.mjs [--src <dir>] [--out <theme.js>] [--check] [--css-out <file.css>]
//   --check  builds into memory and fails if the file on disk differs (nothing is written).
//   --css-out also writes the built CSS on its own (to compare renders).
// After a build: bump VERSION in the theme when the look changed, then update DesktopThemeInstall.sha256 and the byte
// count in Tests/Theme/ThemeTests.swift (both printed below), and copy the file to its published places.
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import path from 'node:path'

const root = fileURLToPath(new URL('..', import.meta.url))
const args = process.argv.slice(2)
const arg = (name, fallback) => (args.includes(name) ? path.resolve(args[args.indexOf(name) + 1]) : fallback)
const src = arg('--src', path.join(root, 'scripts/desktop-theme'))
const out = arg('--out', path.join(root, 'App/Resources/DesktopTheme/hermes-hq-theme.js'))
const CSS_BUDGET = 175000          // minified bytes; older installs refuse a published look over 192 KB of CSS
const FILE_BUDGET = 256 * 1024     // DesktopThemeInstall.maxBytes
const LOADS = /url\s*\(|@import|image-set\s*\(|@font-face|\bsrc\s*\(/i

/** Comments out and whitespace collapsed, strings left exactly as written; a newline after each closing brace. */
export function minify(css) {
  let out = '', i = 0, space = false
  const push = token => {
    if (space && out && !/[{};,\n]$/.test(out) && !/[{};,]/.test(token[0])) out += ' '
    space = false; out += token
  }
  while (i < css.length) {
    const ch = css[i]
    if (ch === '/' && css[i + 1] === '*') { const end = css.indexOf('*/', i + 2); i = end < 0 ? css.length : end + 2; space = true; continue }
    if (ch === '"' || ch === "'") {
      let j = i + 1
      while (j < css.length && css[j] !== ch) j += css[j] === '\\' ? 2 : 1
      push(css.slice(i, j + 1)); i = j + 1; continue
    }
    if (/\s/.test(ch)) { space = true; i++; continue }
    if (ch === '}') { out = out.replace(/;$/, ''); space = false; out += '}\n'; i++; continue }
    push(ch); i++
  }
  return out.trim() + '\n'
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const order = readFileSync(path.join(src, 'ORDER'), 'utf8').split(/\s+/).filter(Boolean)
  let css = ''
  for (const name of order) css += `/* ${name} */\n` + minify(readFileSync(path.join(src, name + '.css'), 'utf8'))
  if (LOADS.test(css)) { console.error('the CSS would load something (url(), @import, image-set(), @font-face or src())'); process.exit(1) }
  const bytes = Buffer.byteLength(css)
  if (args.includes('--css-out')) writeFileSync(arg('--css-out'), css)
  if (bytes > CSS_BUDGET) { console.error(`the CSS is ${bytes} bytes, over the ${CSS_BUDGET} budget`); process.exit(1) }

  const literal = css.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${')
  const before = readFileSync(out, 'utf8')
  const start = before.indexOf('export const CSS = `'), end = before.indexOf('\n`\n', start)
  if (start < 0 || end < 0) { console.error(`no CSS block in ${out}`); process.exit(1) }
  const next = before.slice(0, start) + 'export const CSS = `\n' + literal.trimEnd() + before.slice(end)
  const fileBytes = Buffer.byteLength(next)
  if (fileBytes > FILE_BUDGET) { console.error(`the theme file is ${fileBytes} bytes, over DesktopThemeInstall.maxBytes`); process.exit(1) }
  if (args.includes('--check')) {
    if (next !== before) { console.error(`${out} is out of date: run node scripts/desktop-theme-build.mjs`); process.exit(1) }
  } else writeFileSync(out, next)
  console.log(`CSS ${bytes} bytes from ${order.length} files; ${path.relative(root, out)} ${fileBytes} bytes, sha256 ${createHash('sha256').update(next).digest('hex')}`)
}
