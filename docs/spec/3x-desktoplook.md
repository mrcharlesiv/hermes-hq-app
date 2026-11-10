# 3x — Theme skins, Desktop Look, High Contrast, UI Scale and the desktop theme installer (stream `desktoplook`, run m9)

Status: spec, written 2026-10-12 with the owner asleep. Every choice the web app or the owner's notes did not settle
is marked **DECISION**. Worktree `/Users/me/Projects/hermes-hq-native-wt/m9-desktoplook`, branch
`m9/desktoplook`. Ports 10100–10104 (builders), 10105–10109 (stress tester). Simulators `HQN-m9-desktoplook`
(builders) and `HQN-m9-desktoplook-s` (stress), both "iPhone 17 Pro", runtime iOS 27.0, created by the agent that
uses them.

Abbreviations: `R/` = `/Users/me/Projects/hermes-hq-native-ref240/` (build 240, read only), `V/` =
`R/vendor/hermes/apps/desktop/src/`, `H/` = `/Users/me/.hermes/hermes-agent/` (read only), `MEM/` =
`/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/`, `SP06` =
`docs/spec/06-native-feel-and-design.md`, `SP1S` = `docs/spec/1x-settings.md`.

In scope by the owner's word on 2026-10-11. The older line in `SP1S:68` ("Desktop Look and its options are web-skin
features") was a planner's call, not the owner's, and is superseded by this spec.

---

## 0. What this stream builds, in one page

A **theming layer** under the whole native app, **off by default**, so a phone that never opens Settings › Appearance
› Theme draws exactly what build 250 draws (pixel-identical; §3.6 is the guard). Five user-visible features, shipped
as five builds in this order (one feature per build, each stress tested first):

| Slice | Feature | Rows |
|---|---|---|
| A | Theme skins picker: the 11 bundled skins plus iOS System | L741, L823, L824 |
| B | Desktop Look (v1, v2, v3, the Desktop Look chat, the Nous hand-off, legible colours) | L742, L835, L836, L837, L838, L839 (reply time part), L840 |
| C | High Contrast (a Desktop Look option) | L743, L825, L839 (High Contrast part) |
| D | UI Scale (a Desktop Look option) | L744, L826, L893, L1019, L839 (UI Scale part) |
| E | Hermes HQ Themes for Desktop installer | L131, L745, L841, L842, L1020 |

Slice A must land first (B–D sit on its token layer). E is independent of A–D except that its rows live on the same
Theme page; it can be built in parallel and shipped last.

Wire surface of the whole stream: **two REST calls** (§10.2), both in slice E. Nothing here uses JSON-RPC, the push
relay, or a plugin. No Hermes change is needed.

---

## 1. Sources read

- Web: `R/src/desktop-look.ts` (144 lines), `desktop-look-row.tsx` (42), `phone-ui-desktop.css` (376),
  `phone-ui-contrast.css` (50), `ui-scale.ts` (41), `ui-scale-row.tsx` (22), `ui-kit/ios-theme.ts` (66),
  `desktop-theme-row.tsx` (90), `desktop-theme-install.ts` (53), `build/desktop-look-gates.ts`,
  `ios/App/App/HermesNative.swift:2360-2376` (`installDesktopTheme`), `HermesNative.swift:2389-2412`
  (`accountRequest`), `ios/App/App/HermesViewController.swift:905-916` (`DispatchUIScale`),
  `HermesPlatformExtras.swift:204-210` (`uiScale`), `R/desktop-plugin/hermes-hq-theme/plugin.js` (10,592 bytes).
- Skins: `R/vendor/hermes/apps/shared/src/theme-presets.ts:66-553` (palettes), `V/themes/presets.ts:66-415`
  (labels, descriptions, typography, order), `V/themes/context.tsx:204-222` (mix knobs), `V/styles.css:225-400,585-610`
  (how every `--ui-*` token is mixed from the seeds), `V/i18n/en.ts:1170-1171,1274-1276` (page wording).
- Hermes: `H/hermes_cli/web_routers/files.py:721-728` (mkdir), `:834-880` (write-text), `:114` (8 MiB cap),
  `H/hermes_cli/web_models.py:98-99` (`ManagedDirectoryCreate{path}`), `:176-178` (`FsWriteText{path,content}`).
- Owner notes: `MEM/desktop-look.md`, `MEM/ui-scale-setting.md`, `MEM/high-contrast-option.md`,
  `MEM/desktop-look-reply-time.md`, `MEM/desktop-hq-theme.md`.
- Native: `docs/ARCHITECTURE.md`, `SP06` §1, `SP1S` §3.5, `App/Root/HQPalette.swift`, `App/Chat/ChatPalette.swift`,
  `App/Chat/ChatStyle.swift`, `App/Settings/AppearanceSetting.swift`, `App/Settings/SettingsRootView.swift`,
  `HermesKit/Net/AccountREST.swift`, `HermesKit/Contracts+settings.swift:126-150`, `scripts/fixtures/settings-gateway.py`.

Size of the job, measured on `m9/train` at the start: 175 Swift files in `App/`; 662 palette references in 75 files
(`HQPalette.` / `ChatPalette.` / `.hq…`); 57 direct system-colour references; 351 font call sites; 105 corner-radius
sites; 25 glass sites in 19 files.

---

## 2. Row map

| Row | Text (short) | Section | Slice |
|---|---|---|---|
| §2 L131 | "Add to <computer>" per saved computer, Copy Link, failure words | §10 | E |
| §19 L741 | Theme skin default; Desktop Look switches to "nous" | §4, §5.6 | A, B |
| §19 L742 | Desktop Look, default Off | §5 | B |
| §19 L743 | High Contrast (with Desktop Look), default Off | §6 | C |
| §19 L744 | UI Scale 90/100/110/125/150 (Desktop Look only), default 100 | §7 | D |
| §19 L745 | Hermes HQ Themes for Desktop installer (Copy Link) | §10 | E |
| §20 L823 | iOS System skin as the phone default, with migration | §4.3, §4.4 | A |
| §20 L824 | Bundled theme skins picker | §4, §9 | A |
| §20 L825 | High Contrast look | §6 | C |
| §20 L826 | UI Scale multiplies Dynamic Type; Desktop Look only | §7 | D |
| §21 L835 | Desktop Look v1 | §5.1–5.2 | B |
| §21 L836 | Desktop Look turns iOS System into Nous, and back | §5.6 | B |
| §21 L837 | Legible-colour fix (4.5:1) | §5.5 | B |
| §21 L838 | Desktop Look v2 | §5.3 | B |
| §21 L839 | Desktop Look v3: reply time, High Contrast, UI Scale | §5.4, §6, §7 | B, C, D |
| §21 L840 | Desktop Look chat | §5.4 | B |
| §21 L841 | Desktop theme rows | §10 | E |
| §21 L842 | Install over own connection or with a saved sign-in | §10.2 | E |
| §23 L893 | UI Scale (accessibility table) | §7 | D |
| §27 L1019 | UI Scale setting (native bridge row) | §7 | D |
| §27 L1020 | installDesktopTheme (native bridge row) | §10 | E |

No row is proposed as web-shell-only. Two rows describe WebView bridges (L1019 `uiScale`, L1020
`installDesktopTheme`); the bridge itself has no native counterpart, but the behaviour behind it does, and that is
what gets built.

---

## 3. Architecture: the theming layer

### 3.1 Principle

Today every colour is a dynamic `UIColor` in `HQPalette` / `ChatPalette` (light/dark by trait), every size comes from
Dynamic Type, shapes are constants (`ChatMetrics`), and chrome is system glass. The layer keeps those names and makes
what they return depend on one more input: the **theme state** = (skin, Desktop Look on/off, High Contrast on/off,
UI Scale percent). With the default state (`nous`, off, off, 100) every provider returns what it returns today.

### 3.2 Files

```
HermesKit/Theme/
  Skin.swift            SkinID, SkinSeeds (the palette of theme-presets.ts, light + dark), SkinCatalog (12 skins, order,
                        label, description, sans/mono typeface), default id
  ThemeMath.swift       RGBA, sRGB mix (CSS color-mix in srgb), oklab mix (color-mix in oklab), over(), WCAG luminance
                        and contrast, legibleMix (port of desktop-look.ts:69-105), CIELAB L for the tint floor
  ThemeTokens.swift     ThemeTokens (one resolved colour set for ONE mode), ThemeSet (light + dark + metrics + type),
                        ThemeResolver.resolve(state) -> ThemeSet   (pure, nonisolated, unit tested)
  ThemeState.swift      ThemeState (skin, desktopLook, highContrast, uiScalePercent), ThemeStore (UserDefaults keys,
                        load, save, the Nous hand-off of §5.6, migration of §4.4)
  ThemeTable.swift      nonisolated, lock-protected: generation Int -> ThemeSet; `current`; read by colour providers
                        on any thread (SwiftUI resolves colours off main: see HQPalette.swift:7-9)
App/Theme/
  Theme.swift           @MainActor @Observable `Theme.shared`: state, set(...), applies to every window, posts
                        `Theme.didChange`; `Theme.isDesktop`, `Theme.scale`
  ThemeTrait.swift      UITraitDefinition `ThemeGenerationTrait` (Int, affectsColorAppearance = true) + the SwiftUI
                        bridged environment key
  ThemeFonts.swift      HQFont: the one place fonts are made (UIKit and SwiftUI), §3.4
  ThemeShapes.swift     HQShape: corner radii, row heights, face sizes, gutters, hairlines (§3.5)
  ThemeChrome.swift     bars, tab bar, sheets, glass-or-solid helper (§5.2)
  DesktopTabBar.swift   the docked tab bar of the Desktop Look (§5.3)
App/Settings/Theme/
  ThemeSettingsView.swift, SkinGrid.swift, DesktopThemeSection.swift, DesktopThemeInstaller.swift (§9, §10)
App/Resources/DesktopTheme/hermes-hq-theme.js      byte copy of R/desktop-plugin/hermes-hq-theme/plugin.js (§10.1)
```

### 3.3 How a change repaints the whole app

- `ThemeGenerationTrait` is a custom `UITraitDefinition` with `affectsColorAppearance = true`. `Theme.shared.apply()`
  registers the new `ThemeSet` in `ThemeTable` under a new generation number and sets
  `window.traitOverrides[ThemeGenerationTrait.self] = generation` on every window of every connected scene (and on
  windows created later: `SceneDelegate` and any code that makes a `UIWindow` call `Theme.shared.adopt(window)`,
  next to `AppearanceSetting.apply(to:)`).
- Every palette colour becomes
  `UIColor { @Sendable traits in ThemeTable.tokens(generation: traits[ThemeGenerationTrait.self], dark: traits.userInterfaceStyle == .dark).page }`.
  UIKit re-resolves dynamic colours when a colour-affecting trait changes, so views, layers drawn in
  `draw(_:)`, attributed strings resolved at draw time and SwiftUI `Color(uiColor:)` follow with no per-view code.
  Views that copy a `cgColor` into a layer already listen for `UITraitUserInterfaceStyle`
  (`ChatCells.swift:72,413,681,783`): add `ThemeGenerationTrait.self` to each of those `registerForTraitChanges`
  lists (grep `registerForTraitChanges(\[UITraitUserInterfaceStyle`).
- A generation the table no longer holds (it keeps the last 4) resolves to the current set, never to a crash.
- Things that are not colour: fonts, shapes, chrome and layouts read `Theme.shared` / `ThemeTable.current` when they
  build, and rebuild on `Theme.didChange` (a `NotificationCenter` post on main, after the trait is set):
  - `ChatViewController`: `TextLayout` caches are cleared (`TextLayout.swift:201-203` already has the purge) and the
    table reloads keeping the reading position (same path as a Dynamic Type change, `ChatViewController.swift:494`).
    `TextLayoutKey` gains the theme generation's **layout signature** (an Int hash of look on/off, scale, typeface
    and High Contrast is NOT part of it: High Contrast changes colours only).
  - `ChatStyleCache` keys on `category + layout signature`.
  - Lists (`BotsViewController`, Sessions, pages): `collectionView.reloadData()` after re-applying row metrics.
  - `MainTabController`: swaps the tab bar (§5.3) and bar appearances (§5.2).
  - SwiftUI screens: read `@Environment(\.themeGeneration)` (bridged from the trait) so bodies that pick fonts or
    shapes re-evaluate.
- The change is applied inside `UIView.performWithoutAnimation`, then one 0.2 s cross-dissolve of the window
  (`UIView.transition(with: window, options: .transitionCrossDissolve)`), skipped under Reduce Motion. No screen may
  be torn down: a chat stays open at its offset, a sheet stays up, a draft and the keyboard stay.
- **First frame:** `ThemeStore.load()` is a synchronous `UserDefaults` read done in `SceneDelegate` before the first
  window is made visible (where `AppearanceSetting.apply(to:)` runs today), so the launch screen
  (`LaunchViewController`, page colour) and the first frame are already themed. This is what the web does with its
  pre-paint script (`desktop-look.ts:4`) and what native `DispatchUIScale` exists for
  (`HermesViewController.swift:905-907`).

### 3.4 Fonts (`HQFont`)

One factory, used by UIKit and SwiftUI:

```swift
nonisolated enum HQFont {
    /// What UIFont.preferredFont(forTextStyle:compatibleWith:) returns today when the look is off and the scale is 100.
    static func preferred(_ style: UIFont.TextStyle, compatibleWith traits: UITraitCollection? = nil,
                          weight: UIFont.Weight? = nil, design: Design = .sans) -> UIFont
    static func system(ofSize: CGFloat, weight: UIFont.Weight = .regular, design: Design = .sans) -> UIFont  // fixed sizes
}
extension View { func hqFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: HQFont.Design = .sans) -> some View }
```

- Look off: returns the system font unchanged (`.hqFont(.body)` applies plain `.font(.body)`). **Identity is a hard
  requirement** (§3.6).
- Look on: size = `desktopSize(style) × DynamicTypeRatio(category) × scale`, where `desktopSize` is the table in §5.1,
  `DynamicTypeRatio = preferredFont(.body, category).pointSize / 17` (the web's `--ios-s`,
  `HermesViewController.swift:209`), and `scale = uiScalePercent / 100`. Typeface = the skin's (§4.2).
- All 351 font call sites move to the factory in slice B (a mechanical edit: `UIFont.preferredFont(forTextStyle: x…)` →
  `HQFont.preferred(x…)`, `.font(.body)` → `.hqFont(.body)`, `UIFont.systemFont(ofSize:…)` → `HQFont.system(…)`).
  `Tests/Theme/ThemeLintTests.swift` reads the `App/` sources (path from `#filePath`) and fails on a raw
  `preferredFont(`, `.font(.` or `systemFont(` outside `App/Theme/`, with an allow-list file
  `Tests/Theme/font-allowlist.txt` for sites that must stay fixed (e.g. head drawings, the launch screen), each line
  with its reason.
- **DECISION:** monospace stays the system monospace in every skin. Three skins name web fonts for code (JetBrains
  Mono, IBM Plex Mono: `V/themes/presets.ts:351,362,394`) that the web loads from Google Fonts; the phone does not
  fetch fonts and does not bundle them. Cyberpunk's sans and mono are Courier New (`presets.ts:382-383`), which iOS
  ships, so Cyberpunk in Desktop Look draws in Courier New; every other skin's sans is the system font
  (`presets.ts:45,72,135,335`).

### 3.5 Shapes and metrics (`HQShape`)

`HQShape` holds what `ChatMetrics` and scattered literals hold today, as computed statics reading
`ThemeTable.current.metrics`. Look off: today's values. Look on: §5.1's table. Every `cornerRadius` /
`RoundedRectangle` / `Capsule()` site (105) names a role (`.bubble`, `.card`, `.control`, `.field`, `.capsule`,
`.tile`, `.group`, `.sheet`, `.inline`); a switch and its knob, circular unread badges and round avatars-as-circles
that the web keeps round (`phone-ui-desktop.css:63-64`) use `.round`, which never changes.

### 3.6 The "nothing changed" guard (acceptance for every slice)

With the default state, the app must be pixel-identical to the train before this stream:

1. `Tests/Theme/ThemeIdentityTests`: for the default state, every token of `ThemeResolver` equals the literal it
   replaces (the hex values now in `HQPalette.swift` and `ChatPalette.swift`, copied into the test), every `HQFont`
   call equals the system call it replaces at all 12 Dynamic Type sizes, and every `HQShape` value equals the old
   constant.
2. `UITests/desktoplook/LookOffSnapshotTests`: before the first code change, the builder records screenshots of 12
   screens on `HQN-m9-desktoplook` against the fixture (Bots, Sessions, a chat with a code block and a table, chat
   with keyboard up, Bot Info, More, Settings root, a settings page, Jobs, Kanban or Artifacts, a sheet, sign-in) in
   light and dark into `UITests/desktoplook/baseline/`. After each slice the same tour is taken with the look off
   and compared with `scripts/fixtures/desktoplook-diff.py` (per-pixel; the clock and status bar are masked; the
   allowed difference is 0 px outside the masked bands). A difference is a failure, not a new baseline.

---

## 4. Slice A — theme skins (L741, L823, L824)

### 4.1 What the web does

- Settings › Appearance › Theme lists the desktop's built-in skins: `BUILTIN_THEMES` in this order
  (`V/themes/presets.ts:398-410`): Nous, GitHub, Catppuccin, Everforest, Solarized, Nous Alt, Midnight, Ember, Mono,
  Slate, Cyberpunk. Each has a light and a dark palette (`theme-presets.ts:66-553`); the Color Mode control
  (System / Light / Dark) is applied on top ("Desktop palettes only. The selected mode is applied on top.",
  `V/i18n/en.ts:1275`).
- The skin is stored on the device (`localStorage` `hermes-desktop-theme-v2`, `ios-theme.ts:11`), per profile on the
  desktop (`V/themes/context.tsx:44-50`). It is never written to the gateway by the phone.
- "iOS System" (`ios-theme.ts:20-44`: label "iOS System", description "iOS colours, true black in dark, system
  blue") is the iPhone default only behind the kit flag `IOS_SKIN` (`ios-theme.ts:14-16`), which is **not** in the
  Release list (`R/src/ui-kit/flags.ts:20-38`). `MEM/desktop-look.md`: "iOS System skin is Debug-only (IOS_SKIN off
  in Release), so the Nous hand-off in the row rarely matters". So what the owner sees on build 240 is Nous by
  default, drawn in the iOS look; that is the palette the native app ships (`SP06` §1.1–1.2).
- In the **iOS look** (Desktop Look off) a skin supplies the page colour, the text colours and the accent; cells,
  separators, fills, glass and the bot bubble keep one iOS palette (`phone-ui-desktop.css:3-4`: "where the phone
  otherwise keeps one iOS palette for cells, separators, glass and bubbles (phone-ios-tokens.css)"). In the Desktop
  Look the skin's own surfaces go everywhere (§5).

### 4.2 The catalog (exact)

`SkinCatalog.all`, in display order. Seeds are copied verbatim from `theme-presets.ts` (the builder transcribes all
keys of both modes for each skin: `background, foreground, card, muted, mutedForeground, popover, primary,
secondary, accent, border, input, ring, midground, destructive, sidebarBackground, sidebarBorder, userBubble,
userBubbleBorder` where present); `Tests/Theme/SkinCatalogTests` parses `R/…/theme-presets.ts` when the ref folder
exists (skips otherwise) and compares every seed, so a typo cannot ship.

| id | Label | Description (verbatim) | Sans | Seeds at |
|---|---|---|---|---|
| `nous` | Nous | GitHub chrome, Nous blue accent | system | `theme-presets.ts:125-181` |
| `github` | GitHub | GitHub Light Default and Dark Default | system | `:67-123` |
| `catppuccin` | Catppuccin | Soothing pastels — Latte and Mocha | system | `:183-239` |
| `everforest` | Everforest | Warm, low-contrast forest greens | system | `:241-297` |
| `solarized` | Solarized | Fixed-contrast light and dark | system | `:299-355` |
| `rose-pine` | Rosé Pine | Muted pine, rosé and iris — Dawn and Main | system | the app's own (2026-11-01): `scripts/fixtures/desktop-tokens.py` `APP_ONLY`, from rosepinetheme.com/en/palette; iris accent, and in the iOS look its own surfaces, soft iris box for your message and Rosé Pine code colours (`HermesKit/Theme/SkinOwnLooks.swift`, owner's mockup 2026-11-02) |
| `nous-alt` | Nous Alt | Glass neutrals, cream on mission-blue | system | `:357-411` |
| `midnight` | Midnight | Deep blue-violet with cool accents | system | `:413-439` |
| `ember` | Ember | Warm crimson and bronze — forge vibes | system | `:441-467` |
| `mono` | Mono | Clean grayscale — minimal and focused | system | `:469-495` |
| `slate` | Slate | Cool slate blue — focused developer theme | system | `:525-553` |
| `cyberpunk` | Cyberpunk | Neon green on black — matrix terminal | Courier New | `:497-523` |
| `ios` | iOS System | iOS colours, true black in dark, system blue | system | `R/src/ui-kit/ios-theme.ts:25-43` |

Midnight, Ember, Mono, Slate and Cyberpunk define one (dark) palette on the desktop; the builder must read
`theme-presets.ts:413-553` and `V/themes/context.tsx` (`renderedModeFor`, `:185-201`) and reproduce what the web
does when such a skin is shown in Light mode (the web renders the skin in the mode its background's luminance says:
a dark-only skin stays dark). **DECISION:** a single-palette skin draws its one palette in both modes and the app
forces the matching `overrideUserInterfaceStyle` for it while it is selected (so system materials, the keyboard and
status bar match); Settings › Appearance (System / Light / Dark) stays visible and editable, with the footer
"<Label> has one look, so Light and Dark draw the same." under the Theme row's section while such a skin is on.

### 4.3 Tokens in the iOS look (Desktop Look off)

`ThemeResolver` for look off. For `nous` the output is the existing constants, literally (table in `SP06` §1.2). For
any other skin only these tokens change, each by the formula `SP06` §1.2 already records for Nous:

| Token | Formula (source) |
|---|---|
| `page` | `mix_srgb(background, neutral, w)`: light 92 % background + 8 % `#F3F3F3`; dark 74 % background + 26 % `#0D0D0E` (`V/themes/context.tsx:210-221`) |
| `label`, `label2`, `label3` | `foreground` at 94 %, 74 %, 36 % alpha (`V/styles.css:364-367`; `SP06` §1.2) |
| `tint` | `midground` (falls back to `ring`, `context.tsx` `c.midground ?? c.ring`); in dark, CIELAB L raised to at least 57 (`phone-ios-tokens.css:109`) |
| `tintText` | `tint` passed through §5.5's legibility mix against `page` (the web's fixed `#0040DD` / `#0A84FF` are Nous-only values: keep them for `nous`) |
| `onTint` | white; black when the tint's CIELAB L ≥ 60 (`phone-ios-tokens.css:46`) |
| `meBubble` | light: `tint`; dark: 75 % tint + 25 % black (`phone-ios-tokens.css:51,118`) |
| `meText` | white; black when the fill's L ≥ 55 (`phone-ios-tokens.css:54`) |
| `statusWorking` | light: `tintText`; dark: `label` |
| `grouped` | `sidebarBackground` |

Everything else (bot bubble `#E9E9EB` / `#26282C`, separators, fills, pressed cell, grouped card, code colours,
red / green / orange) stays the iOS palette. For `ios` the builder also applies the skin's own overrides from
`R/src/phone-ios-tokens.css:137-153` (page `#FFFFFF` / `#000000`, label `#000` / `#FFF`, label-2
`rgba(60,60,67,.6)` / `rgba(235,235,245,.6)`, tint `#007AFF` / `#0A84FF`, and the elevated greys in dark), as
`SP06:105-108` summarises.

The builder reads `R/src/phone-ios-tokens.css` end to end before writing the resolver; where that sheet and this
table disagree, the sheet wins and the difference is written into the stream report.

### 4.4 Default and migration (L741, L823)

- **DECISION: the default skin stays `nous`.** Reasons: (1) the web Release build never turned `IOS_SKIN` on
  (`flags.ts:20-38`), so no user of build 240 has iOS System by default, whatever the row's wording says; (2) the
  native app has shipped the Nous palette since build 241 and the owner approved that look ("SO MUCH smoother");
  (3) this stream's rule is "default OFF so the standard look is untouched", and a new default would recolour every
  screen (page `#FEFEFE` → `#FFFFFF`, dark `#0D1015` → `#000000`, tint `#0053FD` → `#007AFF`) for everyone on
  update. iOS System is one tap away in the picker. The default is one constant (`SkinCatalog.defaultID`); whether
  to flip it is put to the owner in `docs/owner-todo/desktoplook.md`. Row L823 is recorded as done once iOS System is
  selectable, the migration below exists and is tested, and this decision is in the report; row L741's "default:
  ios" is recorded as "default: nous, by decision".
- **Migration** (port of `migrateUnchosenSkin`, `ios-theme.ts:46-62`, shaped for native): storage keys (all
  `UserDefaults.standard`, device only, never sent anywhere):

  | Key | Value | Meaning |
  |---|---|---|
  | `hqn.theme.skin` | skin id | absent = default |
  | `hqn.theme.chosen` | `"picked"` \| `"migrated"` | written when the person picks a skin (`markSkinChosen`, `ios-theme.ts:64-66`) or after the one-time migration |
  | `hqn.theme.desktopLook` | Bool | absent = off (`desktop-look.ts:8,28-30`) |
  | `hqn.theme.skinBeforeLook` | skin id | the Nous hand-off's memory (`desktop-look-row.tsx:11`) |
  | `hqn.theme.highContrast` | Bool | absent = off (`desktop-look.ts:16-20`) |
  | `hqn.theme.uiScale` | Int percent | absent = 100; stored only when ≠ 100 (`ui-scale.ts:31-33`) |

  `ThemeStore.migrate(defaultID:)` runs once per launch before the first frame: if `chosen` is absent and the stored
  skin is absent or equals the **old** default (`nous`) while `defaultID` differs, the stored skin is removed (so the
  phone follows the new default) and `chosen = "migrated"`; any explicit pick is left alone; a stored id that is not
  in the catalog (a retired skin, a corrupt value) resolves to the default without being overwritten until the
  person picks. With `defaultID == nous` the migration changes nothing visible; it exists so flipping the default
  later moves only people who never chose.
- Scope: one skin per phone, not per gateway or profile (**DECISION**; the desktop's per-profile assignment,
  `context.tsx:44-50`, is a desktop feature, and the phone web app stores one global value in practice). Sign-out,
  gateway switch and "Reset to Defaults…" (which resets the gateway's config) do not touch it.

### 4.5 Acceptance (slice A)

- A1 Picking each of the 12 skins recolours Bots, Sessions, an open chat, Settings and a sheet at once, in light and
  dark, with no relaunch; screenshots looked at for all 12 × 2.
- A2 The pick survives a relaunch and is on the first frame (launch screen page colour matches the skin).
- A3 `nous` is selected on a fresh install; with it selected the look-off baseline (§3.6) passes.
- A4 `ThemeStoreTests`: migration table (never chose + old default → follows new default; picked → kept; unknown id →
  default, not overwritten); `SkinCatalogTests` seeds equal the reference.
- A5 Contrast: for every skin and mode, `label` on `page` ≥ 4.5:1 and `tintText` on `page` ≥ 4.5:1 (unit test over
  the resolver).
- A6 VoiceOver reads each card as "<Label>, <description>", selected state announced.

---

## 5. Slice B — Desktop Look (L742, L835–L840)

Owner, 2026-10-02 (`MEM/desktop-look.md`): "theme the ENTIRE app like the desktop Hermes Agent app"; picked option A
(colours + shapes + solid chrome). On build 93: "not happy with the quality" — cause: "iOS structure in desktop
colours", built without looking at the desktop. Lesson recorded there: "for look-matching work, get the real
reference on screen first; judge in the owner's theme (Midnight), not Nous." The builder therefore judges every
screen in **Midnight dark** first, then Nous light, against the reference shots in
`R/artifacts/desktop-look-demo` and `R/artifacts/desktop-hq-theme` if present, and against the CSS below.

### 5.1 v1 — colours, corners, type (L835)

Web: `phone-ui-desktop.css:14-137`. Native tokens with the look on (per mode; `ui.*` are the desktop's own mixes,
`V/styles.css:239-240,297-399`, with the mix knobs of `V/themes/context.tsx:214-220`):

Derived desktop values the resolver computes first (all sRGB mixes unless said):

| Name | Formula |
|---|---|
| `base` | `foreground`; `accent` = `midground ?? ring` |
| `chrome` | light 92 % `background` + 8 % `#F3F3F3`; dark 74 % `background` + 26 % `#0D0D0E` (`styles.css:297-301`, `context.tsx:210-216`) |
| `sidebar` | `sidebarBackground` (mix 100 %, `context.tsx:216`) |
| `editor` | `card` mixed with the neutral card (`#161618` dark; light value at `styles.css` `--theme-neutral-card`, read it) at light 22 % / dark 38 % seed (`styles.css:307`, `context.tsx:217`) |
| `elevated` | elevated seed at light 28 % / dark 46 % with the neutral card (`styles.css:308-312`, `context.tsx:218`; read `styles.css:180-225` for the seed) |
| `textPrimary / Secondary / Tertiary / Quaternary` | `base` at 94 / 74 / 54 / 36 % alpha (`styles.css:364-367`) |
| `strokePrimary / Secondary / Tertiary` | `accent` at 24 / 16 / 10 % mixed into (`base` at 10 / 7 / 5 % alpha) (`styles.css:377-391`, `:230-233`; restored by the look, `phone-ui-desktop.css:46-49`) |
| `bgTertiary`, `bgQuaternary`, `bgCard` | `styles.css:313,325-334` |
| `rowActive` | `accent` 8 % mixed into (`base` at 5 % alpha) (`styles.css:345-349`, `:235`) |
| `userBubble`, `userBubbleBorder` | the skin's seeds, bubble mix light 0 % / dark 46 % (`context.tsx:219`; read `styles.css` `--dt-user-bubble` for the mix partner) |

The builder ports these from `V/styles.css` line by line and proves them with `Tests/Theme/DesktopTokensTests`,
whose expected values come from `scripts/fixtures/desktop-tokens.py` (a small script that evaluates the same CSS
formulas for all 12 skins × 2 modes and prints hex; its output is committed as
`Tests/Theme/Fixtures/desktop-tokens.json`).

App tokens with the look on (`phone-ui-desktop.css:16-58,116-131`):

| Native token | Desktop Look value |
|---|---|
| `page`, grouped page, `cell` | `chrome` |
| `cellPressed` | `rowActive` |
| `elevated` (sheets' page, menus' page) | `sidebar`; `elevatedCell` / `groupedCard` / `codeFill` = `editor` |
| `label`, `label2`, `label3`, `label4` | `textPrimary`, legible(`textSecondary`) (§5.5), `textTertiary`, `textQuaternary` |
| `separator` | `strokeSecondary`; opaque separator = `border` seed |
| `fill1` | `bgQuaternary`; `fill2`, `fill3` = `bgTertiary`; `fill4`, card fill = `bgCard` |
| `tint`, `tintText` | legible(`accent`) (§5.5) |
| glass / material | none: `elevated` solid, no blur, no rim (`:39-43`) |
| dim behind sheets | black 24 % light, 48 % dark (`:44,130`) |
| `botBubble` (group rooms only) | `editor`, border `userBubbleBorder` (`:50-52`) |
| `meBubble` / its border / text / time | `userBubble` / `userBubbleBorder` / `textPrimary` / `textTertiary` (`:53-58`) |

Corners (`:59-66`): inline 2, control 3, card 4, bubble 4, field 4, capsule 4, icon tile 3, group 4, sheet 8, alert 6,
menu 4; switch and knob stay round. Native `UIMenu` and `UIAlertController` keep iOS's own shape (the web note says
the same: "native UIMenus, alerts, keyboard are iOS's own").

Type (`:67-113`; all × Dynamic Type ratio × UI Scale; weights top out at semibold; the skin's sans):

| Text style | pt | Weight / leading |
|---|---|---|
| largeTitle | 22 | 600 / 1.3 |
| title1 | 20 | 600 / 1.3 |
| title2 | 18 | 600 / 1.3 |
| title3 | 16 | 600 / 1.35 |
| headline | 15 | 600 / 1.4 |
| body | 15 | 400 / 1.45 |
| callout | 14 | 400 / 1.45 |
| subheadline | 13.5 | 400 / 1.4 |
| footnote | 12.5 | 400 / 1.4 |
| caption1 | 12 | 400 / 1.35 |
| caption2 | 11 | 400 / 1.3 |
| bar title | 14 | 600 / 1.3 |
| the desktop label ("SESSIONS", "BOTS", "WORK 3") | 11 | 600 / 1.3, uppercase, tracking 0.08 em |
| chat message text | 15 | leading 1.6 (replies), 1.5 (your box) |
| chat title | 13 | 600, uppercase, tracking 0.06 em |
| tab root title | 12 | 600, uppercase, tracking 0.08 em, colour `label2` |
| text fields | max(16, 15 × ratio × scale) | — (the web's zoom guard; keep the floor so fields stay finger-sized) |

Gutter: 20 pt on every list and sheet (`:349-351`; today 16).

### 5.2 v1 — solid chrome (L835)

Web: `desktop-look.ts:42-44` (the Reduce Transparency path), `native-glass.ts` sends no glass items.

Native rule from the owner: "native Liquid Glass only; never fake glass with blur plus tint". In the Desktop Look
there is **no glass and no imitation of it**: surfaces are opaque fills with a 1 pt stroke. Implementation
(`ThemeChrome`):

- A helper `HQSurface.apply(to: UIVisualEffectView / view, role:)` and SwiftUI `.hqSurface(role)`: look off → today's
  `UIGlassEffect` / `.glassEffect()` exactly as written now; look on → `effect = nil`, `backgroundColor = editor`
  (or `elevated` for floating panels), `layer.borderWidth = 1 / displayScale… 1 pt`, `borderColor = strokeSecondary`,
  radius from `HQShape`. All 25 glass sites in 19 files route through it (lint test: no `UIGlassEffect(` or
  `.glassEffect(` outside `App/Theme/`).
- Navigation bars: look on → `UINavigationBarAppearance.configureWithOpaqueBackground()`, `backgroundColor = page`,
  `shadowColor = .clear` for standard, scroll-edge and compact (one surface, no hairline: owner 2026-10-03 "lines at
  top/bottom/above composer removed"). `ListBarAppearance.apply` (`HQPalette.swift:48-60`) gets the look branch. Bar
  button items: `hidesSharedBackground = true` and a plain tint of `label2` (`:187`), prominent ones `onTint` on
  `tint` (`:189`); a press shows `rowActive` in a 4 pt box, no scale (`:184,188`).
- Sheets: opaque `elevated` page, `preferredCornerRadius = 8`, no side or foot line (`:372-375`; the web's fix for
  "sheets' edges go off at the iPhone's rounded bottom corners").
- Scroll edge effects under bars: `.hard` style or none, so no soft glass fade appears (verify on the simulator).
- The keyboard, system menus, alerts, share sheet, photo picker and Control Center stay iOS's own.

### 5.3 v2 — one surface, docked tab bar, desktop rows, labels, outlined controls (L838)

Web: `phone-ui-desktop.css:139-229,268-370`. Owner on v2/v3 (`MEM/desktop-look.md`): Midnight reference = "dense
13–14 px type, tracked small-caps labels, accent underline tabs, compact rows with 32 px square faces, one-box
composer"; v3 feedback: "lines at top/bottom/above composer removed; selected tab = accent (rule collided with
badge); Bots vs Sessions rows unified (60 pt…); press = inset rounded ::before over whole row; Kanban chips outlined
(white inverted chip in dark was the bug); 20 pt gutter everywhere; Edit Bot fields outlined, labels like Bot Info
headers"; build 103: "the shadow when you click things isn't right" → flat outlined lift, one press language;
tab bar: "owner picked raised panel".

- **Tab bar (`DesktopTabBar`).** iOS 26's `UITabBar` is a floating glass capsule and cannot be drawn docked and
  solid through appearance alone. **DECISION:** with the look on, `MainTabController` hides the system bar
  (`setTabBarHidden(true, animated: false)`) and shows `DesktopTabBar`, a plain view pinned to the bottom edge:
  height 50 pt + bottom safe area, background light = `sidebar`, dark = `elevated` (`:219-221`, "raised panel"), no
  top line, no lens. One button per tab (same order, same SF Symbols at 19 pt × scale, stroke-weight regular):
  icon over label, gap 3 pt, label in the desktop label style at the tab label size, tracking 0.06 em, uppercase;
  unselected `textTertiary` (High Contrast: `label2`, §6), selected `tintText` (`:225-228`). Badges keep their red
  count at the icon's top trailing corner. Children get `additionalSafeAreaInsets.bottom = 50` so every scroll view
  and the chat composer clear it; the bar hides when a pushed page sets `hidesBottomBarWhenPushed` (the chat), as
  the system bar does. Accessibility: each button `.isButton` + selected trait, label = tab title, value = badge
  ("3 new"), the **same accessibility identifiers** as the system items (`tab-bots`, `tab-sessions`, …) so UI tests
  drive both looks; the container is a `.tabBar` trait group. Turning the look off restores the system bar in the
  same change.
- **Titles.** Tab roots keep the inline large title *position* but draw it as the desktop label (12 pt × ratio ×
  scale, semibold, uppercase, tracked, `label2`) on a 44 pt row (`:81-83,174-178`); pushed pages keep the small bar
  title (14 pt semibold). `PushedPageTitles` stays the rule for which is which. Settings' own title: label style
  (`:181`).
- **Rows (Bots and Sessions drawn alike, `:193-213,272-284`).** Height exactly 60 pt × scale at non-accessibility
  sizes (grows at accessibility sizes), 20 pt gutter, face 36 pt × scale (pinned tiles 48 pt × scale, `:283`), 10 pt
  between face and text, name 14 pt semibold with the time (11 pt, `label2`) on the same line, one line of 12.5 pt
  preview in `label2`, **no separators**, the ⋯ at the same trailing edge on both lists. The faces are the ORIGINAL
  robot heads, drawn smaller, never restyled; their plate takes the 4 pt corner. Press: one inset box (2 pt top and
  bottom, 8 pt sides, 4 pt radius, `rowActive`) over the whole row including its ⋯ (`:325-336`); a pinned head keeps
  its own press. Long-press lift: flat, `editor` fill, 1 pt `strokeSecondary` outline, no drop shadow (`:361-362`).
  This spec's 12–14 pt vertical padding rule for wrapping rows still holds for rows that wrap (settings rows,
  descriptions); the 60 pt roster rows are single-line by design.
- **Section headers** everywhere (roster sections, day groups in Sessions, grouped-list headers, Bot Info headers,
  Edit Bot field labels): the desktop label, `label2`, 36 pt min height for roster sections with the count semibold
  (`:149-152,213,277-281,316`).
- **Grouped lists (Settings, More, Bot Info, pages).** A group is a 1 pt `strokeSecondary` outlined box, 4 pt radius,
  on the page colour, not a filled card (`:139-148`); rows 44 pt min with 10 pt gaps; inner dividers `strokeTertiary`
  inset 46 pt. Icons: small monochrome glyphs in `label2` (20 pt box, 16 pt glyph, × scale), no coloured tile
  (`:157-167`). SwiftUI `List` screens get this through one modifier (`.hqGroupedList()`), which in the look off
  returns today's inset-grouped style untouched.
- **Controls.** Switch on = `tintText` instead of green (`:268-270,312`). Segmented controls: outlined strip (1 pt
  `strokeSecondary`, 3 pt radius, 2 pt padding), chosen segment `rowActive` fill with `label` semibold, others
  `label2` medium, no raised pill (`:306-310`). Text fields in sheets: 1 pt `strokeSecondary` outline, no fill,
  focus = accent outline (`:316-319,341-342`). Search fields: bordered, transparent fill (`:169-172`). Kanban status
  chips: outlined, chosen one on `rowActive`, never inverted (`:286-298`). Bot Info quick-action tiles: outlined,
  press = `rowActive` (`:353-354`). The selected skin card: accent border plus 1 pt inner accent ring (`:321-323`).
- **Queue card, activity shelf, question dock, memo notice** above the composer: square-cornered bordered boxes
  (`editor`, 1 pt `strokeSecondary`, 4 pt), flush with the message bar (`:300-304`).
- Screens added by other m9 streams (voice dock, share, screen viewer, groups, photo heads, browser viewer, …) get
  the look for free where they use `HQPalette` / `HQFont` / `HQShape` / `HQSurface`; the lint tests (§3.4, §5.2)
  make a new screen that bypasses them fail the build's tests. Full-screen media surfaces (the browser viewer's
  stage, the screen viewer, the image viewer) keep their black stage in both looks.

### 5.4 The Desktop Look chat and the reply time (L840, L839)

Web: `ui-chat/index.ts` drops the bubbles; `phone-ui-desktop.css:230-266`. Owner (`MEM/desktop-look-reply-time.md`):
asked "for a time next to responses in Desktop Look", then "the time should be bottom right"; "Your own messages get
no time (owner asked for responses only)". Owner on High Contrast build 204: the "chat thread looks awesome".

- **Replies:** no bubble and no tail. Markdown text straight on the page at the side inset (20 pt), 15 pt, line
  height 1.6, full width to the opposite inset. Code cards, tables and tool rows keep their cards (`editor` fill,
  4 pt radius).
- **Your messages:** a bordered box (fill `userBubble`, 1 pt `userBubbleBorder`, 4 pt radius, padding 8 × 12, text
  `textPrimary`, 15 pt at 1.5), trailing-aligned with today's max width rule, no tail, **no time**.
- **Reply time:** once per run (a run = consecutive replies within `ChatMetrics.runSeconds`, the same grouping the
  bubbles use), on the run's **last prose part**, bottom right, caption2 with tabular digits, `label2`. As in a
  bubble, the last line keeps the time's width + 12 pt free: if the text's last line fits beside it the time sits on
  that line's baseline at the trailing edge; if not, the time takes the next line. When the run ends with a code
  card or a table, the time takes its own right-aligned line under it (`:240-251`). Bot deliveries (cron / job
  messages) get the time the same way. Format: the same string the bubble's corner time uses today.
- **Chat bar:** Back, the chat's name as "the desktop's open tab": a 20 pt face (× scale), the name in the chat
  title style (13 pt semibold uppercase tracked) over a 2 pt `tintText` rule under the title button, then ⋯
  (`:232-236`). Solid, no line under the bar.
- **Message bar:** ONE bordered box (1 pt `strokePrimary`, 4 pt radius, `editor` fill, 6 × 10 pt outer padding)
  holding ☰, +, the field, the microphone and Send / Stop; the buttons inside it draw no background of their own;
  focus turns the border to the accent (`composerRing` seed, else `tint`) (`:253-266`). The recorder rows, draft
  chip and attachment tray keep their positions; the attachment chip is opaque `editor` (`:260-262`).
- **Group rooms** (when the groups stream is on the train) keep bubbles, in the desktop colours of §5.1
  (`:50-58`, `MEM/desktop-look.md`: "group rooms keep bubbles (desktop colours)").
- Layout: `ChatRow` layout gets a `look` input; `TextLayout` computes exact heights for both looks (the time
  reserve reuses `ChatMetrics.timeReserveGap`); the send lift, streaming glide, jump button and "Show More" clamp
  work unchanged. Switching the look with a chat open keeps the row at the top of the viewport in place.

### 5.5 Legible colours (L837)

Web: `desktop-look.ts:64-128`. "A theme's accent is drawn as text … and its secondary text colour as captions; some
themes pick ones too faint for that (Cyberpunk's neon green on the white Desktop palette is 1.4:1). Each is measured
against the page and, when under 4.5:1, mixed toward the theme's own text colour just until it reads. Themes that
already read are left as they are." `MEM/desktop-look.md`: "Verified on all 11 themes × light/dark."

`ThemeMath.legible(source:text:page:)`: for `keep` in 100, 90, …, 0: `c = mix_oklab(source keep %, text)`; composite
`c` over `page` (page itself composited over white); return the first `c` whose WCAG contrast with the page is
≥ 4.5; `keep == 100` means untouched. Applied to `accent` → `tint` / `tintText`, and `textSecondary` → `label2`,
only with the look on (slice A reuses the function for `tintText` in the iOS look, §4.3). It is part of
`ThemeResolver`, so it re-runs on a skin, mode, look or High Contrast change. The oklab conversion uses the same
matrices as `desktop-look.ts:83-85`. Unit tests: the Cyberpunk-light case is corrected; Nous is untouched; for all
12 skins × 2 modes `tintText` and `label2` reach 4.5:1 on `page`.

### 5.6 The Nous hand-off (L836, L741)

Web: `desktop-look-row.tsx:10-25`. "iOS System is the phone's own skin and has no desktop counterpart, so turning
the look on moves it to Nous (the desktop's default skin)."

`ThemeStore.setDesktopLook(_ on:)`:
- on, and the skin is `ios` → store `skinBeforeLook = "ios"`, set skin `nous` (not marked as a pick).
- off, and `skinBeforeLook == "ios"` and the skin is still `nous` → set skin back to `ios`.
- off → always remove `skinBeforeLook`.
- A skin picked by hand while the look is on is kept when the look goes off (the "still nous" condition).
- While the look is on, the iOS System card stays in the grid and can be picked (the web allows it); picking it
  clears nothing else.

### 5.7 Acceptance (slice B)

- B1 Default off on a fresh install; the look-off baseline passes after the slice lands.
- B2 Turning it on changes the open Theme page and everything behind it at once; a tour (§11.3) in Midnight dark and
  Nous light of every screen on the train is captured and **looked at**: no glass anywhere, no hairline under the top
  bar, over the tab bar or over the message bar, 20 pt gutters, small-caps labels, outlined groups, 60 pt roster rows.
- B3 Chat: replies have no bubble; your message is a bordered box; the message bar is one box; the time shows once
  per run at the bottom right of replies and never on your messages; after a code card it is on its own line.
- B4 `ios` + look on → skin shows Nous; look off → iOS System again; pick Midnight while on, turn off → Midnight stays.
- B5 Legibility unit tests (§5.5) pass; Cyberpunk light's links and selected tab are readable in a screenshot.
- B6 Relaunch with the look on: the first frame is already in the look (screen recording of launch, looked at).
- B7 Every press and hold state checked (owner build 103: "audit EVERY press/hold state"): row press, pinned head
  press, long-press lift, bar button press, segmented press, tile press, ⋯ press, Kanban row press.
- B8 Turning the look off restores native glass and the system tab bar live (the web verified the same).
- B9 Dynamic Type xSmall, Large, xxxLarge, AX3, AX5: no clipped text, rows grow at accessibility sizes, tab bar
  labels stay readable (large content viewer supported on `DesktopTabBar` buttons).

---

## 6. Slice C — High Contrast (L743, L825, L839)

Owner, 2026-10-07 (`MEM/high-contrast-option.md`): "many themes have no hierarchy, and their own sent message is
nearly the page colour." On build 204: "harder lines everywhere too much, esp. the line over the tab bar; chat
thread 'looks awesome'" → strokes softened to 18 / 13 / 10 %, tab bar line removed, "user message tint/outline +
composer 50% outline kept".

Web: `phone-ui-contrast.css:10-49`; applies **only with the Desktop Look on** (`desktop-look.ts:14-17`). It is not
iOS's Increase Contrast setting and does not replace it (the existing Increase Contrast handling stays).

With `ink = textPrimary`, `page`, `accent` (un-legibled seed accent):

| Token | Dark | Light |
|---|---|---|
| `strokePrimary / Secondary / Tertiary` | `ink` at 18 / 13 / 10 % alpha | same |
| `separator` | `strokeTertiary`; opaque separator = oklab 10 % `ink` in `page` | same |
| `label2` | oklab 65 % legible(`textSecondary`) + 35 % `ink` | same |
| `label3` | oklab 70 % `textTertiary` + 30 % `ink` | same |
| `editor` (message bar, cards, code, section fills, elevated cell, card fill) | oklab 10 % `ink` in `page` | 5 % |
| `fill1` | oklab 12 % `ink` in `page` | same |
| `rowActive` / pressed cell | oklab 22 % `accent` in `page` | 14 % |
| `userBubble` | oklab 28 % `accent` in `page` | 13 % |
| `userBubbleBorder` | oklab 75 % `accent` in `page` | 65 % |
| `botBubble` (rooms) | `editor`, border `strokeSecondary` | same |

Plus: your message box's border is the full `userBubbleBorder`; the message bar's border is `ink` at 50 % alpha
(`:46-47`); unselected tab labels are `label2` (`:49`); **no** line over the tab bar.

Storage `hqn.theme.highContrast`. Turning the Desktop Look off keeps the stored choice but stops applying it (the
row hides); turning the look on again brings it back (web: the row is rendered only `{on && …}`,
`desktop-look-row.tsx:34-40`, and the CSS keys on both classes).

Acceptance: C1 row visible only while the look is on; C2 in Everforest light and Solarized dark (flat skins) the
own-message box is clearly tinted and outlined, groups read as lifted boxes (screenshots looked at, before/after);
C3 unit tests for the table above for all skins; C4 with the look off the toggle has no effect and the look-off
baseline passes with the stored value on; C5 survives relaunch, first frame included.

---

## 7. Slice D — UI Scale (L744, L826, L893, L1019, L839)

Owner, 2026-10-07 (`MEM/ui-scale-setting.md`): "desktop look a little small on iPhone"; refinement: "creates some ui
glitches, refine a touch more" (names ran together at 125–150 %; faces and icons had to scale too); 2026-10-08: "UI
scaling should only be for the desktop style theming".

Web: `ui-scale.ts:10-41`, `ui-scale-row.tsx:10-21`; native side `DispatchUIScale` (`HermesViewController.swift:910-916`,
clamp 0.8…1.6) multiplies every Dynamic Type size; in the Desktop Look faces, list/bar/tab icons and the 60 pt rows
multiply too (`phone-ui-desktop.css:161-162,185-186,196-198,210,227,235,275,283`). "Why not WKWebView.pageZoom"
does not apply natively.

- Presets 90, 100, 110, 125, 150. `Theme.scale = desktopLook ? percent / 100 : 1` (`appliedUIScale`,
  `ui-scale.ts:21`); the **choice** is kept while the look is off and comes back with it. A stored value outside
  0.8…1.6 or not a number is treated as 100 (`DispatchUIScale.clamped`); a stored value inside the range that is not
  a preset (e.g. 120) is applied as is and the control shows no selection (`ui-scale-row.tsx:17`).
- What multiplies: every `HQFont` size (on top of Dynamic Type, never instead of it), faces (36 / 48 / 20 pt), list,
  bar and tab icons, the 60 pt roster row height, reply action icons, Kanban faces, profile chips. What does not:
  gutters, hairlines, corner radii, the 44 pt minimum tap target, the 16 pt text field floor.
- Layout: the change runs the same path as a Dynamic Type change (`ChatStyleCache`, `TextLayout` purge, list
  reload). Truncation rules from the refinement round: a name and its time never run together (the name truncates
  first; minimum 8 pt gap); a meta line never starts a wrapped line with "·".
- **DECISION:** Dynamic Type accessibility sizes × 150 % can exceed what a 393 pt wide screen can lay out. The
  product of ratio × scale is capped at the AX5 ratio (53 / 17 ≈ 3.12) so the scale never makes text larger than
  iOS's own largest setting.

Acceptance: D1 control visible only while the look is on, five segments on one row, selection haptic; D2 each
preset changes the open page at once; D3 look off → app at 100 % and the row hidden, choice kept; look on → the
choice back; survives relaunch with the first frame at scale (owner-verified behaviour quoted above); D4 at 150 %
on Bots, Sessions, chat, Settings: no overlapping text, no clipped faces (screenshots looked at); D5 unit tests for
clamp, non-preset value, cap.

---

## 8. Wording (exact; from the web, with "Dispatch" appearing nowhere)

| Where | Text | Source |
|---|---|---|
| Settings root, Appearance section, new row | "Theme" — value: the skin's label | `V/i18n/en.ts:1274` |
| Page title (small, on the bar row) | "Theme" | same |
| Toggle | "Desktop Look" | `desktop-look-row.tsx:31` |
| Its description | "Draws Hermes HQ like the Hermes desktop app: your theme’s own colours on every screen, square corners and solid bars instead of glass. Set on this device only." | `:29` |
| Toggle | "High Contrast" | `:38` |
| Its description | "Sets your messages, boxes, lines and secondary text further apart from the page, in your theme’s own colours. For themes that look flat." | `:36` |
| Row title | "UI Scale" | `ui-scale-row.tsx:20` |
| Segments | "90%", "100%", "110%", "125%", "150%" | `:10` |
| Its description | "Makes the Desktop Look’s text, faces and rows larger or smaller, on top of the text size set in iOS Settings. The iOS look stays at 100%. Set on this device only." | `:18` |
| Section header over the grid | "Theme" | `en.ts:1274` |
| Its footer | "Desktop palettes only. The selected mode is applied on top." | `en.ts:1275` |
| Skin labels and descriptions | §4.2's table | |
| Single-palette footer (DECISION, no web wording) | "<Label> has one look, so Light and Dark draw the same." | — |
| Installer wording | §10.3 | |

---

## 9. Settings UI (native design)

Web placement: Settings › Appearance › Theme page, in this order: Desktop Look, High Contrast, UI Scale, Hermes HQ
Themes for Desktop, then the theme list (`build/desktop-look-gates.ts:5-13`, `desktop-look-row.tsx:27-41`).

Native: the Settings root's "Appearance" section keeps its System / Light / Dark picker (`SettingsRootView.swift:294`)
and gains a second row **Theme** with the current skin's label as its value and a chevron; it pushes
`ThemeSettingsController` (a `UIHostingController` on the UIKit navigation stack, small bar title "Theme",
identifier `settings.theme`). The row is added to the settings search index (`SettingsSearch`) with keywords
"theme, skin, desktop look, high contrast, ui scale, colours, colors" so each of the four names finds the page.

**[page-tabs] 2026-11-01 (owner: "getting kind of long and feels chaotic"):** the page is now four tabs under the
bar (`theme.tab`, Bot Info's and Capabilities' whole-label segments): **Themes** (the grid, then Hermes HQ Themes for
Desktop), **Chats** (Chat Bubbles and its Glass switch), **Backgrounds** (App Background, Chat Background; its own tab
as App Background is behind every page, not only chats) and **Look** (Desktop Look, High Contrast, UI Scale). Chats and
Backgrounds are not in the Desktop Look. It opens on Themes; Settings search opens the other tabs for their rows
(`theme:chats`, `theme:backgrounds`, `theme:look`), and the Theme row's keywords are only the Themes tab's words. The Desktop Look's whole-label strip leaves
10 pt beside each label (iOS's own room; it was 14), so Bot Info's five tabs stay one row up to XXL. The order below
predates the tabs and UX studies #60/#110.

**[look-in-themes] 2026-11-01 (owner: "I want the desktop look toggle to be in the theme tab, not its own tab"):** no
Look tab. Themes is: Desktop Look (its switch and note) first, the grid, then High Contrast and UI Scale (the Desktop
Look; UI Scale alone in the iOS look on the Mac), then Hermes HQ Themes for Desktop. The Desktop Look has Themes only, so
it shows no tab strip. `theme:look` (search for Desktop Look) opens Theme on Themes.

`ThemeSettingsView` is an inset-grouped `List` (through `.hqGroupedList()`), sections top to bottom:

1. **Desktop Look** toggle (`theme.desktopLook`), footer = its description.
2. (look on only) **High Contrast** toggle (`theme.highContrast`), footer = its description.
3. (look on only) **UI Scale**: a row with the title and, under it, a full-width segmented `Picker` of the five
   presets (`theme.uiScale`), footer = its description. Rows 2 and 3 appear and leave with the list's standard row
   animation when the look toggles.
4. **Hermes HQ Themes for Desktop** (§10.4).
5. Header "Theme", footer "Desktop palettes only. The selected mode is applied on top.": the skin grid — two columns
   of cards (`LazyVGrid`, 12 pt gaps) inside one clear-background list row. A card: a 64 pt preview (the skin's page
   colour with a strip of its card colour, an accent dot and two text bars in its label colours, for the mode on
   screen), then the label (headline) and the description (footnote, `label2`, up to 3 lines), 12 pt padding.
   Selected: 2 pt `tint` border and a checkmark; identifier `theme.skin.<id>`; a tap selects with a selection haptic
   and applies at once. At accessibility text sizes the grid is one column.

Rules: every wrapping row has 12–14 pt vertical padding; no control is shown that does nothing (rows 2–3 hidden,
not disabled, when the look is off — as the web); toggles answer in the same frame (the repaint follows in the
same run-loop turn). The page works offline and signed out of nothing: slices A–D need no network.

---

## 10. Slice E — Hermes HQ Themes for Desktop (L131, L745, L841, L842, L1020)

Owner (`MEM/desktop-hq-theme.md`): asked 2026-10-08 for "a desktop Hermes theme matching the iOS app"; then a phone
button ("multi-computer asked mid-task"); for a laptop that only runs the desktop app against another computer's
Hermes: "add the copy link button and ship it"; the desktop path wording was corrected because "there is NO
'Capabilities' label (owner couldn't find it)" → "Settings (gear) › Plugins › Manage plugins › Install from Git".
The row was renamed "Hermes HQ Themes for Desktop" when Nous High Contrast was added. Install "never switches the
theme".

### 10.1 What is installed

The file `R/desktop-plugin/hermes-hq-theme/plugin.js` (10,592 bytes, SHA-256
`15564d18b22aa9a03ee72d2ea8f8fc5d65e86ffa26cce53eaf28539fbafd01e4`), which registers two desktop themes, "Hermes HQ"
and "Nous High Contrast". It is the owner's own file from the owner's repository; the native app bundles a byte
copy as `App/Resources/DesktopTheme/hermes-hq-theme.js` (added to BOTH `project.yml` and `project-original.yml`
resources). `Tests/Theme/DesktopThemeResourceTests` checks the bundled file's SHA-256 against the constant above
and that it is under 256 KiB (the web's native limit, `HermesNative.swift:2366`). The text is read from the bundle
only when Add is tapped (`desktop-theme-install.ts:8`).

It is written to `~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js` on the gateway's computer
(`desktop-theme-install.ts:12`); the desktop app loads and hot-reloads that file by itself. The folder is a
constant in Swift, never taken from input (`HermesNative.swift:2370`).

### 10.2 Wire calls (exact)

Both are REST on the gateway, JSON bodies, the account's normal auth (cookie session or Nous bearer), 15 s timeout
each (`desktop-theme-install.ts:37-38`). Bodies carry exactly these keys and no others.

```
POST /api/files/mkdir
{"path":"~/.hermes/desktop-plugins/hermes-hq-theme"}
→ 200 {"ok":true,"entry":{…},"path":"…", …}          (H/files.py:721-728; exists already → still 200, mkdir exist_ok)
→ 409 {"detail":"A file already exists at that path"}

POST /api/fs/write-text
{"path":"~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js","content":"<the file's text>"}
→ 200 {"ok":true,"path":"…","byteSize":10592}        (H/files.py:834-880)
→ 400 {"detail":"Parent directory does not exist"} | 403 {"detail":"File is not writable"} | 413 {"detail":"Content too large"}
```

Order: mkdir, then write-text only if mkdir answered 200 (`HermesNative.swift:2371-2374`); success = write-text 200.
The response bodies are not needed beyond the status.

- **The gateway in use** (L842 "over the computer's own connection"): through the signed-in client's REST
  (`LiveGatewayClient` / the `REST` layer, with its 401 → refresh once).
- **Any other saved gateway** ("natively with a saved sign-in"): `AccountREST.call(stored, method: "POST", path:,
  body:, timeout: 15)` (`HermesKit/Net/AccountREST.swift:9-28`), which uses that account's own session without
  opening its socket or switching, and writes a renewed session back to the vault — the native twin of the web's
  `accountRequest` (`HermesNative.swift:2389-2412`). A saved account with no session (signed out) is not listed
  (§10.4), and if its session turns out dead the answer is 401.
- **DECISION:** one helper `DesktopThemeInstaller.install(on: GatewayAccountRow) async -> Result<Void, Int>` uses
  `AccountREST` for both kinds only if the current account's client cannot be reached from `SettingsServices`;
  the preferred path for the current gateway is its live client so a session renewal is shared with the app. Either
  way the two requests and their bodies are identical.
- Unreachable gateways: the app's existing reachability policy applies (a Tailscale-only host with Tailscale off
  answers status 0 without waiting for a timeout, as `HermesTransportPolicy.reachable` does on the web).

Never touched: `~/.hermes` on this Mac, the owner's real gateway, the public plugin repositories. Tests run only
against the fixture (§11).

### 10.3 Failure words by status (`desktop-theme-install.ts:19-24`)

| Status | Text (red, under that computer's row; VoiceOver announces it) |
|---|---|
| 0 (no answer, timeout, unreachable) | "The computer didn’t answer. Check that it’s on and connected, then try again." |
| 401, 403 | "This phone isn’t signed in to that computer anymore. Sign in to it again in Settings › Gateway." |
| 404 | "That computer’s Hermes is too old to take files from the phone. Update Hermes there, then try again." |
| anything else | "Its Hermes refused the file (HTTP <status>)." |

The status used is the failing request's (mkdir's if mkdir failed, else write-text's).

### 10.4 UI states (section 4 of the Theme page)

Title "Hermes HQ Themes for Desktop". Description (`desktop-theme-row.tsx:80`): "Adds two themes to the Hermes
desktop app<where>: Hermes HQ, this app’s look (iOS colours, blue message bubbles, round shapes), and Nous High
Contrast, Nous with this app’s High Contrast. It changes nothing else." where `<where>` is " on <title>" when there
is exactly one target and empty otherwise.

Targets: saved gateways that have a session (`GatewayAccountRow.hasSession`), the one in use first, then in the
saved list's order (`desktop-theme-row.tsx:86-90`). `title` is the row's `title` (the name given on this phone, else
the host).

- **One target:** the title row carries the button at its trailing edge.
- **Several:** one row per computer: "<title>" plus " · In Use" (secondary colour) on the current one, the button
  trailing; min height 44 pt, the title wraps anywhere.
- **Button** per target (identifier `theme.desktop.add.<row id>`; accessibility label "Add to <title>", or "Add to
  Desktop" if the list could not be read): "Add" (prominent) → "Adding…" (disabled, with the request running) →
  "Added" (secondary style; tapping again re-installs, as on the web where only `busy` disables it). On failure the
  button returns to "Add".
- **Note under a target:** on success "Added. In the desktop app, open Settings › Appearance › Theme and pick
  Hermes HQ or Nous High Contrast."; on failure the §10.3 text in red. Haptic: success / error
  (`desktop-theme-row.tsx:42`).
- **Elsewhere block** (always shown, under the targets): footnote "Hermes app on a computer that uses Hermes on
  another one? Add it there: in its Settings, Plugins › Manage plugins › Install from Git, then paste this link."
  with a secondary button "Copy Link" (accessibility label "Copy Install from Git Link") → copies
  `https://github.com/mrcharlesiv/hermes-hq/tree/main/desktop-plugin/hermes-hq-theme` to `UIPasteboard.general`,
  success haptic, the button reads "Copied". If the copy cannot be confirmed the footnote is replaced by red
  "Couldn’t copy. The link is https://github.com/mrcharlesiv/hermes-hq/tree/main/desktop-plugin/hermes-hq-theme"
  (`desktop-theme-row.tsx:60-68`). The link itself is selectable text in that state.
- **No signed-in computer** (cannot normally happen: Settings needs a sign-in): only the description and the
  elsewhere block show; no dead Add button.
- States are per page visit (in memory), as on the web; leaving and returning shows "Add" again.
- Installs on different computers may run at the same time; a second tap on a row that is "Adding…" does nothing.
- The page leaving mid-install does not cancel the two requests (they are tiny and idempotent); the result is
  dropped.

### 10.5 Related, not this stream

- L1020's "the plugin also copies hermes-hq-theme.js": that is the push add-on (0.6+) writing the same file on the
  Mac by itself (`MEM/desktop-hq-theme.md`, "In the push plugin"). Nothing for the app to do; the phone button stays
  useful for gateways without the add-on.
- The one-time "Update Hermes HQ's Add-on?" offer for add-ons that predate the themes (`R/src/push-setup.ts:65-69`)
  belongs to the push / capabilities rows, not to these.

### 10.6 Acceptance (slice E)

- E1 Two fixtures saved (A in use, B "Beta"): two rows, A first with " · In Use"; Add on A → fixture A's state shows
  exactly one mkdir and one write with the two bodies of §10.2, no extra keys, and the written text's SHA-256 equals
  §10.1's; the row reads "Added" with the note.
- E2 Add on B while A stays in use: fixture B records the two calls, the app does not switch gateways (title menu
  and socket unchanged), A records nothing.
- E3 Each failure: fixture told to answer 0 (drop), 401, 403, 404, 500, and mkdir 409 → the exact §10.3 text for
  each ("Its Hermes refused the file (HTTP 500)." / "(HTTP 409)."); the button is back to "Add" and a retry after
  clearing the failure succeeds.
- E4 Copy Link puts the exact URL on the pasteboard (read back in the UI test) and the button reads "Copied".
- E5 One saved computer: the single-target layout with "… desktop app on <title>: …".
- E6 A saved computer with no session is not listed.
- E7 Unit tests: failure words by status; target ordering; body encoding has exactly the keys of §10.2.

---

## 11. Stand-in gateway and test commands

### 11.1 New fixture `scripts/fixtures/desktoplook-gateway.py`

No committed fixture answers the two file routes. The new script loads `scripts/fixtures/settings-gateway.py` by
path with `importlib` (as that script loads the ref's fixture) so it keeps the rich seed (bots, sections, chats with
code blocks and tables, skills, config) the tour needs, and adds:

- `POST /api/files/mkdir` — auth required (401 without the session, as every `/api/` route of the base fixture);
  body must be an object with a string `path` (else 422); records `{route, path, extraKeys}`; marks the folder as
  existing; answers `200 {"ok":true,"path":<path>,"entry":{"name":"hermes-hq-theme","type":"directory"}}`.
- `POST /api/fs/write-text` — body `{path: str, content: str}` (else 422); `400 {"detail":"Parent directory does
  not exist"}` if the parent was never made; `413` over 8 MiB; records `{route, path, bytes, sha256, extraKeys}`
  and keeps the content in memory (never on disk); answers `200 {"ok":true,"path":<path>,"byteSize":<n>}`.
- Controls (loopback, no auth, never under `/api/`): `GET /__look/state` → `{"calls":[…],"files":{path:{bytes,sha256}}}`;
  `POST /__look/fail {"route":"mkdir"|"write","status":401|403|404|409|500|"drop"|"slow","count":N}` (`drop` closes
  the socket without answering; `slow` waits 20 s then answers 200, to hit the 15 s timeout); `POST /__look/reset`.
- Same arguments as the base: `--port`, `--credentials`, `--label`, `--hermes-cookies`.

Start (builders):

```
cd /Users/me/Projects/hermes-hq-native-wt/m9-desktoplook && mkdir -p build/fixtures
python3 scripts/fixtures/desktoplook-gateway.py --port 10100 --hermes-cookies --credentials build/fixtures/desktoplook-a.json > build/fixtures/desktoplook-a.log 2>&1 &
python3 scripts/fixtures/desktoplook-gateway.py --port 10101 --label Beta --credentials build/fixtures/desktoplook-b.json > build/fixtures/desktoplook-b.log 2>&1 &
```

Stress tester: the same on 10105 and 10106. Before starting, check each port with
`lsof -nP -iTCP:<port> -sTCP:LISTEN` and refuse a busy one; stop only the PIDs you started. For the tour's Jobs /
Kanban / Artifacts tabs: `python3 scripts/pages-fixture-gateway.py --port 10102 --credentials
build/fixtures/desktoplook-pages.json --files build/fixtures/desktoplook-pages-files --tick-seconds 0` (the recipe
of `scripts/e2e-pages.sh:26`). For activity cards, attachments, voice rows and questions in the look, the existing
suites' fixtures on this stream's remaining ports (`scripts/fixtures/activity-gateway.py` etc., as their
`scripts/e2e-*.sh` start them).

### 11.2 `scripts/e2e-desktoplook.sh [udid]`

Modelled on `scripts/e2e-settings.sh`: starts fixtures A and B on `HQN_LOOK_PORTS` (default "10100 10101"), passes
`TEST_RUNNER_HQN_LOOK_A` / `_B` (credential files) and `TEST_RUNNER_HQN_SHOTS`, runs
`-only-testing:HermesHQNativeUITests/DesktopLookEndToEndTests` on the given simulator with `HQN_DD` derived data,
prints `scripts/e2e-summary.py`, stops what it started. The UDID is required (no default simulator).

```
xcrun simctl create "HQN-m9-desktoplook" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0   # once; reuse if it exists
scripts/build.sh test <udid>                       # unit tests (Tests/Theme/*)
HQ_IDENTITY=original scripts/build.sh build <udid> # the shipped identity must build too
scripts/e2e-desktoplook.sh <udid>
```

### 11.3 DEBUG launch hooks (App/Debug, DEBUG builds only)

`-HQDebugSkin <id>`, `-HQDebugDesktopLook YES|NO`, `-HQDebugHighContrast YES|NO`, `-HQDebugUIScale <percent>`: set
the stored state before the first frame, so UI tests and the screenshot tour (`scripts/desktoplook-shots.sh <udid>
<out dir>`: 12 screens × the states asked for) need no tapping through Settings. `-HQDebugResetAccounts YES` also
clears the six `hqn.theme.*` keys.

### 11.4 Unit and UI tests (names)

`Tests/Theme/`: `ThemeMathTests` (mix, oklab, contrast against known pairs, legibleMix), `SkinCatalogTests`,
`ThemeIdentityTests`, `DesktopTokensTests`, `HighContrastTokensTests`, `ThemeStoreTests` (keys, hand-off, migration,
scale clamp), `ThemeLintTests`, `DesktopThemeInstallTests` (words by status, ordering, bodies),
`DesktopThemeResourceTests`, `DesktopLookLayoutTests` (reply-time placement: fits on the last line, wraps, after a
code card; row heights at each scale).
`UITests/desktoplook/`: `DesktopLookEndToEndTests` (A1–A3, B2–B4, B8, C1, D1–D3, E1–E6), `LookOffSnapshotTests`.

---

## 12. STRESS PLAN

Run by the stress tester on `HQN-m9-desktoplook-s`, fixtures on 10105–10109, before each slice may ship. Rerun a
flaky failure once before calling it; never loosen an assertion.

**Switching under load**
1. Toggle Desktop Look 200 times in a loop (UI test) with a chat open behind the Settings sheet: no crash, memory
   after the loop within 10 MB of before (the generation table must not grow), final state correct.
2. Cycle all 12 skins × light/dark × look on/off × contrast on/off (96 states) and screenshot Bots, chat and
   Settings in each; a script checks no screenshot is blank or equal to the previous state's when it should differ;
   a person looks at the Midnight, Cyberpunk-light, Everforest-light and iOS-dark sets.
3. Toggle the look **while a reply is streaming** (fixture stream at 60 tokens/s, 4,000-token reply with code and a
   table): no dropped or duplicated text, the row stays put, the stream finishes, heights are exact afterwards (no
   jump when scrolling the whole chat).
4. Toggle while: the keyboard is up with a draft (draft and focus kept), a memo is recording (recording continues),
   the send lift is mid-flight, a sheet is at medium detent, a `UIMenu` is open, a long-press lift is showing, the
   question dock is up, a search is active in Settings.
5. Change UI Scale 90 → 150 → 90 fifty times on a 500-row chat: reading position kept within one row, no layout
   pass over 100 ms after the first (signpost or `CACurrentMediaTime` log).

**Speed**
6. Chat open time (the app's own first-content measure from `scripts/e2e.sh`) with the look on vs off on the
   performance fixture: within 10 %. Scrolling a 2,000-row chat with the look on: no hitch over 2 frames in
   Instruments' animation hitches or the app's frame log.
7. Look off: launch-to-first-frame time unchanged from the train (± 5 %); `ThemeStore.load` under 1 ms.
8. Colour providers are called on every draw: 10,000 calls to a palette provider under 5 ms total (unit benchmark),
   lock uncontended from 4 threads (SwiftUI resolves off main).

**Bad data**
9. Write garbage into each `hqn.theme.*` default (`xcrun simctl spawn <udid> defaults write <bundle id> …`): unknown
   skin id, skin as a number, `uiScale` = 0, −50, 9999, "abc", `desktopLook` as a string: the app launches in a sane
   state (default skin / off / 100 %) and the Theme page shows that state.
10. `skinBeforeLook` = "ios" with the look stored off and skin "midnight": nothing flips.
11. Installer: the bundled theme file missing or empty (simulated by a DEBUG hook). Required behaviour: the section
    hides its Add buttons and shows only the description and the elsewhere block (never a control that does
    nothing, and never a failure text that blames the computer for the app's own missing file).

**Bad network (installer)**
12. Fixture `drop`, `slow` (20 s), 401, 403, 404, 409, 500 on mkdir and on write separately: exact words each
    time; the button always comes back; no spinner left running; total wait never over 31 s.
13. Fixture stopped mid-request; airplane mode (Network Link Conditioner "100% loss") on Add: status-0 words
    within the timeout.
14. Tap Add on A and B at the same moment; tap Add 20 times fast on one row: exactly one mkdir + one write per
    completed install, no interleaved state.
15. Session expired on B (fixture `--access-ttl` short or its session cleared): 401 words, and the app's own
    connection to A is untouched; **no sign-in is retried in a loop**.

**Interruption and relaunch**
16. Kill the app (simctl terminate) right after flipping each toggle: the stored state is the last one tapped and
    the next first frame shows it.
17. Background → foreground 30 times with the look on; rotate (if the app allows) and trait changes (system
    light ↔ dark from Control Center while the look is on, Increase Contrast on/off, Bold Text on/off, Reduce
    Transparency on/off): correct colours each time, look-on tab bar stays docked.
18. Gateway switch, sign-out and sign-in, Reset to Defaults…, Import Settings… with the look on: theme state kept,
    no screen left in the old look.
19. Memory warning (`simctl spawn … notifyutil` / Debug › Simulate Memory Warning) with the look on, then scroll a
    chat: layouts rebuild correctly.

**Accessibility sizes and assistive tech**
20. Dynamic Type xSmall, Large, xxxLarge, AX1, AX3, AX5 × UI Scale 90, 100, 150 × look on: Bots, Sessions, chat,
    Theme page, Bot Info, a sheet: no clipped or overlapping text, every button ≥ 44 pt, the UI Scale segments stay
    on one row or wrap cleanly, the product cap (§7) holds.
21. VoiceOver pass with the look on: the docked tab bar announces tabs, selection and badges; skin cards announce
    label, description and selected; Add buttons announce "Add to <computer>" and the result note; the reply time
    is part of the reply's label, not a separate stop.
22. Contrast audit (script over the resolver, all 12 skins × 2 modes × contrast off/on): body text, secondary text,
    tint text, tab labels (selected and not), your-message text on its box, time under replies — each ≥ 4.5:1;
    failures listed by skin.
23. Reduce Motion: no cross-dissolve on a theme change. Smart Invert and Increase Contrast with High Contrast on:
    still legible.

**Regression guard**
24. Look-off baseline (§3.6) after every slice, and the full existing suites (`scripts/e2e.sh`, `e2e-settings.sh`,
    `e2e-menus.sh`, `e2e-pages.sh`, `e2e-activity.sh`, `e2e-attachments.sh`, `e2e-voice.sh`, `e2e-questions.sh` on
    this stream's ports) run once with the look OFF (must pass unchanged) and once with
    `-HQDebugDesktopLook YES` injected (must pass: same identifiers, same flows).

---

## 13. Owner to-do and open calls

`docs/owner-todo/desktoplook.md` holds what waits on the owner. Nothing in this stream needs a relay, plugin or
real-gateway change. One taste call is recorded there: whether iOS System should become the default skin (§4.4).

## 14. Risks

1. **Scale of the migration.** ~660 colour sites already go through two palettes (cheap), but 351 font sites, 105
   radius sites and 25 glass sites must be routed through the new factories. It is mechanical and lint-guarded, yet
   it touches almost every UI file, so it will conflict with every other m9 stream. Mitigation: slice A changes
   only palette internals; the Ship agent should merge slice B's mechanical commit right after a train merge, and
   B's builder re-runs the lint tests after every `m9/train` merge.
2. **Pixel identity with the look off** is the promise that protects what the owner already approved; the baseline
   test (§3.6) must be recorded before any code change.
3. **iOS 26 chrome.** Hiding the system tab bar and removing bar-button glass (`hidesSharedBackground`) must be
   verified on the iOS 27 simulator; if the system bar cannot be hidden cleanly on some screen, that screen is
   reported, not papered over.
4. **Exact heights in the chat** for the bubble-less layout and reply time: any mismatch shows as scroll jumps. The
   layout tests of §11.4 and stress items 3 and 5 are the guard.
5. **Token port accuracy.** The desktop mixes are many; `desktop-tokens.json` generated from the CSS formulas is
   the oracle, and the builder must judge in Midnight against real desktop screenshots, as the owner's note says.
6. **Single-palette skins in Light mode** (§4.2 DECISION) and the monospace fonts (§3.4 DECISION) differ slightly
   from the desktop; both are written down for the owner.
7. **Not seen yet.** This spec was written from sources; nothing in it has been built or run. Outcomes in
   `docs/briefs/m9/desktoplook-rows.md` are all "todo".

## Addendum (repair after stress round 2)

- DECISION (§10, installer): a 200 counts as installed only when its body is a JSON object that does not say
  otherwise (`ok` false, `error` or `detail` present). Anything else shows "Something answered, but it wasn’t Hermes.
  Check this computer’s address in Settings › Gateway, then try again." The web app takes any 200; native is stricter
  so a proxy's or captive network's page is never reported as "Added".
- At the accessibility text sizes the desktop themes card stacks its title and button.
- DECISION: under a skin in the iOS look the reply bubble keeps the phone's own grey, as the web app does
  (phone-ui-desktop.css:3-4).
