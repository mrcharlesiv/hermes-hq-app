// Writes latest.json, the look installed desktop themes switch to on their own (see LATEST_URL in the theme), from
// App/Resources/DesktopTheme/hermes-hq-theme.js. Usage: node scripts/desktop-theme-latest.mjs <out.json>
// Publish it beside the theme in hermes-hq-public (desktop-plugin/hermes-hq-theme/latest.json) after bumping VERSION.
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const source = fileURLToPath(new URL('../App/Resources/DesktopTheme/hermes-hq-theme.js', import.meta.url))
const { VERSION, THEME, NOUS_HIGH_CONTRAST, readLook } = await import(source)

const out = process.argv[2]
if (!out) {
  console.error('usage: node scripts/desktop-theme-latest.mjs <out.json>')
  process.exit(2)
}

const look = readLook({ version: VERSION, themes: [THEME, NOUS_HIGH_CONTRAST] })
if (!look) {
  console.error('the theme would not pass its own check (a CSS url(), @import or @font-face, or a malformed palette)')
  process.exit(1)
}
writeFileSync(out, JSON.stringify(look, null, 1) + '\n')
console.log(`wrote ${out}: version ${look.version}, ${look.themes.map(t => t.name).join(', ')}`)
