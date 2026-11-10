# 06 — Native feel and design (milestone 1)

What the native chat, bot list and heads must look and feel like, taken from the web app the owner uses today
(reference: `~/Projects/hermes-hq-native-ref238`, release-build238) and from the owner's recorded decisions
(memory directory `~/.claude/projects/-Users-me-Projects-hermes-ios/memory/`).

**Citation conventions.** `src/…`, `ios/…`, `vendor/…` paths are relative to `~/Projects/hermes-hq-native-ref238`.
`memory/x.md` is a file in the memory directory above. Line numbers are for the ref238 tree.

**Precedence.** When code and docs disagree, this spec follows the shipped code (build 238), and the owner's memory
notes win over both where the owner said something newer. Disagreements are flagged with **⚑ DISAGREES**. Open
questions are flagged with **UNKNOWN**, and choices the native app has to make are flagged with **DECISION**.

**This spec vs the native repo's own docs.** `docs/ARCHITECTURE.md` says "Protocol facts live in `docs/spec/*.md` —
follow them exactly; when the spec and the reference web app disagree, the web app's behaviour wins"
(`~/Projects/hermes-hq-native/docs/ARCHITECTURE.md:5-6`). Every look-and-feel value below is the web app's shipped
behaviour, so **this file wins** over `ARCHITECTURE.md` and `PLAN.md` wherever they differ on look and feel. Four
known contradictions, with the wording those files should carry (this spec may only edit `docs/spec/`, so it can't
fix them itself; see §13 item 10):

| Native doc says | Shipped web app (this spec) | Should read |
|---|---|---|
| "else a jump button shows a count" (`ARCHITECTURE.md:46`) | no count and no dot (§4.4; `src/phone-chat.css:43-45`) | "else the jump button appears (no count, no dot)" |
| "HeadView (draws the default robot heads)" (`ARCHITECTURE.md:27`); "bot list with robot heads" (`PLAN.md:14`) | the default head is a plain Shapes head (§7.1; `src/ui-heads/head.ts:246-258`) | "HeadView (draws the default Shapes heads; saved heads from `ui_meta`)" |
| "unread dot" (`PLAN.md:14`; not in `ARCHITECTURE.md`) | a filled circle, 16 pt on a row, 10 pt on a pinned tile, no number (§6.1, §6.2) | "unread circle (16 pt row / 10 pt tile, no count)" |
| "the bar sits 8 pt above the keyboard and at the safe area when down" (`ARCHITECTURE.md:47-48`) | keyboard down: the glass bottom is **29 pt above the screen bottom**, which is 5 pt *inside* a 34 pt home-indicator inset (§4.3) | "8 pt above the keyboard; 29 pt above the screen bottom when the keyboard is down" |

**Units.** CSS `px` on the phone = iOS points (pt). "Body", "Footnote" and so on are the iOS text styles; the web
app mirrors them at the Large (default) size: Body 17/22, Callout 16/21, Subheadline 15/20, Footnote 13/18,
Caption 1 12/16, Caption 2 11/13, Headline 17/22 semibold, Title 2 22/28, Title 1 28/34
(`src/phone-ios-tokens.css:86-96`). In the native app, use `UIFont.preferredFont(forTextStyle:)` so Dynamic Type works,
and keep the caps noted below.

---

## 0. The ten rules that matter most

1. **Telegram is the feel benchmark.** Chats open instantly with text already drawn, the keyboard never "fights", and
   nothing bounces (`memory/smoothness-round.md`, `memory/smooth-chat-transitions.md`, `memory/chat-open-bounce.md`).
2. **Bubbles on both sides**, Telegram-shaped, in the Hermes colours, not Telegram's colours. Never unbox bot replies
   (`memory/chat-bubbles-telegram.md`, `memory/telegram-look-hold.md`).
3. **A sent message stays at the bottom.** A new reply is read from its top: following stops when the reply's top
   reaches the bar (`memory/thread-top-anchor.md`).
4. **Composer row = Telegram's**: 40 pt glass controls, glass 26 pt in from the sides, 29 pt above the screen bottom;
   with the keyboard up, 8 pt from the sides and 8 pt above the keys (`memory/telegram-field-sizing.md`).
5. **Native glass only** (`UIGlassEffect` / `.glassEffect()` / system bars, sheets and menus). No blur-and-tint
   imitations, and no heavy tints on glass (`memory/liquid-glass.md`, `memory/reply-peek.md`).
6. **Rows that can wrap get 12–14 pt of vertical padding** (`memory/row-padding-feedback.md`).
7. **Unread = a filled circle with no number**: 16 pt at the right edge of a list row, 10 pt beside the name on a
   pinned tile (`memory/unread-circle-position.md`, `memory/unread-badges.md`).
8. **The default head is a plain Shapes head** (a coloured shape with two slit eyes, white on light pages and black on
   dark ones). No hats, and no redrawn heads (`memory/default-shape-heads.md`, `memory/bot-head-redraw-proposal.md`,
   `memory/new-bot-style-no-hats.md`).
9. **Tool calls are quiet compact rows** (one grey line per run, with a glyph, a summary and a chevron), and they open
   into a card (`src/ui-chat/trail.css:1-28`).
10. **Never bring back what the owner rejected** (see §12): Telegram colours, wallpaper or read checks; rays or anime
    art; redrawn heads; a tab-bar accessory; a shrinking tab bar; top-bar layout overhauls.

---

## 1. Colour palette (exact values)

### 1.1 Which skin is the default

- The web app's iPhone default skin is **"Nous"**. The "iOS System" skin exists, but its flag `IOS_SKIN` is absent
  from the Release list, so it is off (`src/ui-kit/ios-theme.ts:14-16`, `src/ui-kit/flags.ts:20-38`).
- Nous seeds: light background `#ffffff`, foreground `#1f2328`, accent (midground) `#0053fd`. Dark background `#0d1117`,
  foreground `#e6edf3`, accent `#4a84fe` (`vendor/hermes/apps/shared/src/theme-presets.ts:127-128,144,155-156,172`).
- The page colour is the background mixed toward a neutral grey: light 92 % of `#ffffff` with 8 % of `#f3f3f3`, dark
  74 % of `#0d1117` with 26 % of `#0d0d0e` (`vendor/hermes/apps/desktop/src/themes/context.tsx:210-221`,
  `vendor/hermes/apps/desktop/src/styles.css:297-301,399`). The boot test's stored dark background is the same
  `#0d1015` (`src/boot-theme.test.ts:30`).
- **UNKNOWN:** which skin the owner has actually picked on their phone. The skin lives in the web app's localStorage
  (`hermes-desktop-theme-v2`), which the native app can't read. **DECISION for M1:** ship Nous, and keep every colour
  behind one palette type so iOS System (and later the other skins) can be added.

### 1.2 Tokens for the native app (Nous, the default)

| Token (web name) | Light | Dark | Source |
|---|---|---|---|
| Page / chat / list background (`--ui-chat-surface-background`, `--ios-bg`) | `#FEFEFE` | `#0D1015` | computed above; `src/phone-ios-tokens.css:17` |
| Label (`--ios-label`) | `#1F2328` at 94 % (`rgba(31,35,40,.94)`) | `#E6EDF3` at 94 % | `styles.css:364`, `phone-ios-tokens.css:22` |
| Secondary label (`--ios-label-2`) | `#1F2328` at 74 % | `#E6EDF3` at 74 % | `styles.css:365`, `phone-ios-tokens.css:23` |
| Tertiary label (`--ios-label-3`) | `#1F2328` at 36 % | `#E6EDF3` at 36 % | `styles.css:367`, `phone-ios-tokens.css:24` |
| Tint / accent (`--ios-tint`) | `#0053FD` | `#4A84FE` (CIELAB L≈57, so the dark-mode floor `max(l,57)` leaves it unchanged) | `phone-ios-tokens.css:40,109` |
| Tint as small text (`--ios-tint-text`) | `#0040DD` | `#0A84FF` | `phone-ios-tokens.css:13,106` |
| Text and glyphs on tint (`--ios-on-tint`) | `#FFFFFF` (black only when the accent's CIELAB L ≥ 60) | `#FFFFFF` | `phone-ios-tokens.css:46` |
| **Bot bubble** (`--ios-bubble-bot`) | **`#E9E9EB`** | **`#26282C`** | `phone-ios-tokens.css:47,116` |
| Bot bubble text | Label | Label | `phone-ui-chat.css:73` |
| **Your bubble** (`--ios-bubble-me-fill`) | **`#0053FD`** (= tint) | **≈`#3863BF`** (75 % `#4A84FE` + 25 % `#000`) | `phone-ios-tokens.css:51,118` |
| Your bubble text (`--ios-bubble-me-text`) | `#FFFFFF` (black only when the fill's L ≥ 55) | `#FFFFFF` | `phone-ios-tokens.css:54` |
| Time inside your bubble (`--ios-bubble-me-time`) | `#FFFFFF` at 85 % | `#FFFFFF` at 88 % | `phone-ios-tokens.css:55,119` |
| Time inside a bot bubble | Secondary label | Secondary label | `phone-ui-chat.css:51-53` |
| Separator (hairline, `--ios-separator`) | `rgba(60,60,67,.29)` | `rgba(84,84,88,.6)` | `phone-ios-tokens.css:28,114` |
| Opaque separator | `#C6C6C8` | `#38383A` | `phone-ios-tokens.css:29,114` |
| Fill 1 / 2 / 3 / 4 (`--ios-fill…`) | `rgba(120,120,128,.2)` / `rgba(120,120,128,.16)` / `rgba(118,118,128,.12)` / `rgba(116,116,128,.08)` | `.36` / `.32` / `rgba(118,118,128,.24)` / `rgba(118,118,128,.18)` | `phone-ios-tokens.css:30,110` |
| Cell, pressed cell | page colour, `#D1D1D6` | `#1C1C1E`, `#2C2C2E` | `phone-ios-tokens.css:19,27,113` |
| Elevated cell (sheets, menus, completion lists) | page colour | `#2C2C2E` | `phone-ios-tokens.css:21,113` |
| Search field fill | `#767680` at 12 % | same formula | `src/phone-tabs.css:19` |
| Green text (diff `+12`) | `#248A3D` | `#30D158` | `phone-ios-tokens.css:77,106` |
| Red text (errors, `−3`, failed) | `#D70015` | `#FF453A` | `phone-ios-tokens.css:13,106` |
| Orange text (needs you) | `#C93400` | `#FF9F0A` | `phone-ios-tokens.css:13,106` |
| Muted grey (muted unread circle) | `#8E8E93` | `#8E8E93` | `phone-ios-tokens.css:11,105` |

The **iOS System** skin, kept for later: page `#FFFFFF` / `#000000`; label `#000` / `#FFF`; label-2
`rgba(60,60,67,.6)` / `rgba(235,235,245,.6)`; tint `#007AFF` / `#0A84FF`. The bubbles use the same formulas, so
your bubble is `#007AFF` in light and ≈`#0863BF` in dark, and the bot bubble is unchanged
(`src/phone-ios-tokens.css:137-153`, `src/ui-kit/ios-theme.ts:25-43`).

**Increase Contrast:** bubbles gain an edge. The bot's edge is label-3, and yours is your fill mixed 70 % with
black (`phone-ios-tokens.css:159-164`, `phone-ui-chat.css:164`).

**⚑ DISAGREES:** `~/Projects/dispatch-handoff/design/DESIGN.md` §4.12 says "your bubble is grey, not blue" and "the
bot reply is an unboxed document". The owner overrode both. Owner decision 2 (2026-09-28) gave both sides Hermes
colours in a Telegram bubble shape (`~/Projects/dispatch-handoff/design/OWNER-DECISIONS.md`), and on 2026-10-06 the
owner confirmed white text on the blue fill (comment at `phone-ios-tokens.css:41-45`). The code above is what ships.

---

## 2. Message bubbles

### 2.1 Shape and size

| Property | Your bubble | Bot bubble | Source |
|---|---|---|---|
| Alignment | trailing | leading, at the 16 pt content edge | `phone-ui-chat.css:39-40,67-68`; `renderer-mobile.css:195` |
| Max width | `min(80 % of column, 320 pt)`; 90 % at accessibility text sizes | 100 % of the column (column = screen − 2×16) | `phone-ui-chat.css:40,60,72` |
| Width | fits its text | fits its text | `phone-ui-chat.css:40,72` |
| Padding | 6 top/bottom, 12 leading/trailing, inside a 1 pt border (normally transparent) | same | `phone-ui-chat.css:41,72` |
| Corner radius | 12 (owner, 2026-10-16; was 18 = web) | 12 | `phone-ui-chat.css:23` |
| Text | Body 17, line-height 1.3, never capped | same | `phone-ui-chat.css:24-25,74` |
| Line breaking | greedy, filling the bubble (no balanced wrapping) | same | `phone-ui-chat.css:75-77` |
| Long message | clamps at 10 lines with a fade, then "Show More" (tint, Caption 2 semibold, bottom-left, 44 pt target); the same height when it opens with a quote or holds a code card (audit 863: blocks past it wait, a card crossing it shows whole) | n/a | `phone-ui-chat.css:55-59` |

**⚑ DISAGREES:** DESIGN.md §4.12 gives padding 8/14 and no tail. The code uses 6/12 and a tail.

### 2.2 Runs, corners and the tail

- A **run** is consecutive messages from the same sender and source, each within **300 s** of the one before
  (`src/ui-chat/run.ts:24-25,91-97`). Positions: `single`, `first`, `middle`, `last` (`run.ts:109`).
- Bubbles in a run sit **2 pt apart** (`phone-ui-chat.css:79,84-90`).
- Corners where two bubbles of a run face each other drop to **6 pt**: the trailing side for yours and the leading
  side for a bot's (`phone-ui-chat.css:88-96`). The ends keep 12 pt.
- The **last bubble of a run** (or a single one) gets a **tail** at its bottom corner (trailing for yours, leading for
  a bot's). That corner's radius becomes 0, and an 8×17 pt shape hangs outside the bubble with its bottom 1 pt below
  the bubble's bottom edge (`phone-ui-chat.css:110-126`). The exact tail paths, in an 8×17 view box:
  - Trailing tail (yours), filled with the bubble's colour: `M0 4H1C1 10.5 3 15.2 8 17H0Z` (`phone-ui-chat.css:31`).
  - Leading tail (bot's), the mirror image: `M8 4H7C7 10.5 5 15.2 0 17H8Z` (`phone-ui-chat.css:33`).
  - The edge stroke used under Increase Contrast is drawn with the even-odd paths at `phone-ui-chat.css:32,34`.
  - **Native:** build each bubble as one `UIBezierPath` (rounded rect plus tail) and fill it. Don't stack separate
    views. Cache the path per (size, position).
- **Glass bubbles** (owner, 2026-11-01: "the tinted glass kind of wins everywhere"; Theme › Chat Bubbles › Style › Glass, Solid the
  default since 2026-11-02, the iOS look on iPhone and iPad): the bubble is Liquid Glass tinted with its own colour instead of the solid fill,
  §8 rule 11. Glass takes rounded corners, not a path, so the tail goes and its corner rounds as a joined one (6 pt);
  the bubble's frame and the time's place are unchanged.
- **Tinted bubbles** (owner, 2026-11-01, from a Telegram screenshot: "Can we have an option to do the same with our
  chat bubbles?"): Theme › Chats › Chat Bubbles › Style is Solid | Glass | Tinted (`BubbleStyle`, solid the default since 2026-11-02 (owner);
  the Mac has a Tinted switch, since it has no Glass). Tinted keeps the tail. Each bubble shows a soft copy of the
  Chat Background (48 px, blurred by a sixteenth, saturation 1.7), lined up with the picture on screen and repainted
  around the skin's bubble lightness, so it takes the picture's colours and part of its light and dark, never all of
  it: Telegram's look, with no live blur (`TintedBubbles`, App/Chat/Cells/TintedBubbles.swift). §8 rule 11 has the rule. With no Chat Background,
  or under Reduce Transparency, the bubbles are solid.
- A bot's reply can contain several prose bubbles (text parts split by tool rows). Consecutive prose bubbles sit
  2 pt apart, and a bubble that follows a non-bubble block sits 6 pt below it (`phone-ui-chat.css:78-79`). Only the
  reply's last prose bubble gets the tail and the time (`phone-ui-chat.css:111,139-141`).
- Turns: messages stack with the renderer's turn gap of **6 pt** (`0.375rem`;
  `vendor/hermes/apps/desktop/src/styles.css:516`; `vendor/.../thread/list.tsx:440`).

### 2.3 Inside the bubble

- **Time:** Caption 2 (11 pt, scales, **capped at 20 pt**), line-height 1.15, tabular digits. It sits absolutely at
  10 pt from the trailing edge and 5 pt from the bottom (`phone-ui-chat.css:28,51-53`). The text's last line keeps an
  invisible copy of the time plus 12 pt free on its right, so the time never overlaps text (`phone-ui-chat.css:48-50`).
  When the last block isn't a paragraph or list (a code block or table), the time gets its own line: bottom padding
  = 11 × 1.15 + 9 ≈ 21.7 pt (`phone-ui-chat.css:80-82`).
- **Inline code:** radius 6 (`phone-ui-chat.css:144`).
- **Code block / table inside a bubble:** an inset with no border and no shadow, radius 10, Fill 4 in light
  (`phone-ui-chat.css:628`). **In dark the code inset is not Fill 4:** `src/phone-fe-convo.css:525` sets
  `.dark [data-slot='code-card'] {background: color-mix(in srgb, #fff 7%, var(--ui-bg-editor)) !important}`, and the
  `!important` beats the bubble rule. For Nous dark that is ≈ **`#1F2023`** (editor `#0E0F12` = 38 % `#010409` + 62 %
  `#161618`, `vendor/hermes/apps/desktop/src/styles.css:307,590,595`; `themes/context.tsx:223`), slightly darker than the
  `#26282C` bubble. Tables keep Fill 4 in both modes. Full code-block spec: §2.6.
  A wide table fades out on the right and has "Expand Table" under it (Footnote, tint-text, 44 pt target;
  `phone-ui-chat.css:633-635`).
- **Lists:** indent `min(1.625em, 30 pt)` (`phone-ui-chat.css:70`).
- **Links in your bubble:** your text colour, underlined (`phone-ui-chat.css:44-47`).
- **Sender name** (only for deliveries from another bot, or for the chat's bot after another bot has spoken):
  Subheadline 15 semibold in the bot's colour, made to reach 4.5:1 (`phone-ui-chat.css:102-104`,
  `src/ui-chat/name-color.ts:1-3`).
- **A delivery from another bot** (a cron job or an agent message): its 28 pt face beside the run's last bubble with an
  8 pt gap; the job's name sits under the sender as Footnote label-2 (`phone-ui-chat.css:106-107,131-134`).

### 2.4 Timestamps

- **One time per run** (owner, 2026-09-30), drawn only in the bubble that ends the run. The other bubbles of the run
  drop both the time and its reserved width (`phone-ui-chat.css:136-141`; `memory/chat-refinement-shapes.md`).
  **⚑ DISAGREES:** round-9 decision D1 ("every bubble shows its own time", OWNER-DECISIONS.md) is older, and the code
  follows the newer one-per-run rule.
- **Clock format:** the device's locale and hour cycle, hour numeric and minute 2-digit, no seconds ("9:14 AM";
  `run.ts:140-147`). The message's time is `metadata.custom.timelineTimestamp` (unix seconds), else the creation
  time (`run.ts:64-69`).
- **Day separator:** a centred Caption 1 line (12 pt, **capped at 22**), label-2, tabular digits, with 12 pt top and
  bottom padding and 8 pt side padding (`phone-ui-chat.css:17,607`). The text is "Today 9:14 AM",
  "Yesterday 9:14 AM", or "Sep 26 9:14 AM" (the year is added when it isn't the current year). It appears at the
  first timed message, at a date change, or after a gap of **≥ 1800 s** (`run.ts:161-170`). The whole line is one
  weight. **⚑ DISAGREES:** DESIGN.md wants the day semibold; the code doesn't do that.
- Menu titles and VoiceOver use the long form ("Yesterday 9:14 PM", "Sep 26, 9:14 PM"; `run.ts:149-160`).

### 2.5 Action row (latest reply only)

- It shows under the latest settled reply only: Copy · Read Aloud · Regenerate · More. Each is a 44 pt circle with a
  20 pt glyph in label-2, a press fill of Fill 3, and no labels. The row starts 10 pt left of the content edge, so the
  glyphs line up with the text (`phone-ui-chat.css:439-461`).
- Older replies keep their actions in their hold menu.
- **M1:** Copy is enough, and More can wait. **DECISION.**

### 2.6 Code blocks and syntax highlighting

Fenced code in a reply goes `SyntaxHighlighter` → `RichCodeBlock` → the code card
(`vendor/hermes/apps/desktop/src/components/assistant-ui/markdown-text.tsx:743-760`). `RichCodeBlock` sends only
` ```mermaid `, ` ```svg ` and ` ```listing ` to their own renderers; every other language gets the code card
(`vendor/.../components/assistant-ui/embeds/registry.tsx:11-39`). Mermaid/SVG/listing and artifact cards are later
milestones; M1 draws them as ordinary code cards.

**Card geometry (phone, Release):**

| Part | Value | Source |
|---|---|---|
| Card | radius 10, no border, no shadow; fill = Fill 4 (light) / ≈`#1F2023` (Nous dark), see §2.3 | `phone-ui-chat.css:628`; `phone-fe-convo.css:525` |
| Gap above the card | the paragraph gap (`margin-block: var(--paragraph-gap) 0`) | `vendor/.../styles.css:2081-2089` |
| Top strip | **40 pt**, reserved by `padding-top: 40px` on the card; holds the language label on the left and Copy on the right | `src/phone-fe-convo.css:376`; `src/phone-chat.css:179` |
| Language label | in the strip, 14 pt from the leading edge, vertically centred in 40 pt, **12 pt weight 500 system font**, label-3 (`--ui-text-tertiary`), one line with an ellipsis, max width = card − 72 pt, not tappable | `phone-chat.css:179`; gate `build/fe-convo-gates.ts:570` |
| Label text | `codeLanguageLabel(lang)`: none for empty, `text`, `plain`, `plaintext`, `txt`, `none`, `output`, `log`; else the map (`py`/`python`→Python, `js`→JavaScript, `jsx`→JSX, `ts`→TypeScript, `tsx`→TSX, `sh`/`bash`/`zsh`/`shell`/`console`→Shell, `json`→JSON, `yaml`/`yml`→YAML, `toml`→TOML, `html`→HTML, `css`→CSS, `sql`→SQL, `md`/`markdown`→Markdown, `swift`→Swift, `go`→Go, `rust`/`rs`→Rust, `rb`/`ruby`→Ruby, `java`→Java, `kotlin`/`kt`→Kotlin, `c`→C, `cpp`/`c++`→C++, `cs`/`csharp`→C#, `php`→PHP, `diff`→Diff, `xml`→XML, `dockerfile`→Dockerfile, `make`/`makefile`→Makefile, `graphql`→GraphQL, `lua`→Lua, `r`→R, `ini`→INI, `env`→Env); else, if the tag matches `^[a-z][\w+#.-]{0,15}$`, the tag with its first letter capitalised; else none | `src/fe-convo-r4.ts:174-183` |
| Copy button | **44×44 pt**, top 0, **4 pt from the trailing edge**, always visible on the phone (opacity 1; the desktop's hover reveal is overridden); glyph = Tabler `IconCopy` at **12 pt** in muted-foreground; on success it swaps to `IconCheck` for **1.5 s** (`IconX` on failure); success haptic `notification.success` | `phone-fe-convo.css:51-52,377`; `vendor/.../components/chat/shiki-highlighter.tsx:163-170`; `vendor/.../components/ui/copy-button.tsx:15,142-143`; `vendor/.../lib/icons.ts:22,38`; `build/haptics-gates.ts:27` |
| Copied text | the code with `@url:` references turned back into plain URLs (`copyableCodeText`) | `shiki-highlighter.tsx:130-137` |
| Compact card | when there is **no language label and fewer than 3 lines**: no strip (`padding-top: 0`), card at least 44 pt tall, code padded 52 pt on the trailing side so the Copy button (still top-trailing) never covers it | gate `build/ui-revision-gates.ts:281`; `phone-ui-chat.css:636-637` |
| Code padding | 12 pt sides, 10 pt top and bottom (`[&_pre]:px-3 [&_pre]:py-2.5`) | `shiki-highlighter.tsx:171` |
| Code text | **Footnote size (13 at default, grows with Dynamic Type), line-height 1.5**, monospace; the web's stack resolves to `ui-monospace` (SF Mono) on iOS. Native: `UIFont.monospacedSystemFont` scaled with `UIFontMetrics(forTextStyle: .footnote)`. Tab width 2 | `phone-chat.css:177-178`; `vendor/.../styles.css:487-489`; `phone-fe-convo.css:555` |
| Wrapping | none: long lines scroll sideways inside the card (`overflow-x: auto`, `white-space: pre`) | `vendor/.../components/chat/code-card.tsx:39`; `shiki-highlighter.tsx:112` |
| Height clamp | the code area is capped at **120 pt** (`max-h-[7.5rem]`); when its content is taller than 121 pt, a 28 pt fade (from the card's fill) covers the bottom with a 36×28 pt chevron-down toggle at the trailing end; open, the cap becomes **40 % of the screen height** and the code scrolls inside it. The phone does not restyle this. **DECISION:** keep the 120 pt clamp and the toggle, but give the toggle a 44 pt hit area (the web's 36×28 is below the phone's 44 pt rule) | `vendor/.../components/chat/expandable-block.tsx:14-61` |
| Prose fences | a fence the renderer judges to be prose (`isLikelyProseCodeBlock`) is drawn as wrapped body text with no card. Later milestone; M1 draws every fence as a card | `vendor/.../lib/markdown-code.ts:381-407`; `shiki-highlighter.tsx:155-157` |

**Highlighter and palette (copy these exact colours):**

- The web uses **Shiki 4.3.1** with the themes **`github-light-default`** (light) and **`github-dark-dimmed`** (dark),
  switched by the page's colour scheme (`defaultColor: 'light-dark()'`) (`package.json:85`;
  `vendor/.../components/chat/shiki-config.ts:9`; `vendor/.../components/chat/shiki-block.tsx:101-106`).
- The themes' backgrounds are **never drawn**: the card's own fill shows (`[&_pre]:bg-transparent!`,
  `code-card.tsx:39`).
- Light: comments are remapped from `#6e7781` to **`#57606a`** for contrast (`shiki-config.ts:19-21`).
- Dark: every token is drawn through `filter: saturate(0.82) brightness(0.92)` (`vendor/.../styles.css:2231-2233`).
  The dark column below has that filter **pre-applied** (computed in sRGB; ≈, verify against a screenshot).

| Token (TextMate scopes) | Light | Dark (theme value → drawn ≈) |
|---|---|---|
| Plain text / default foreground | `#1F2328` | `#ADBAC7` → **`#A1ABB5`** |
| Comment (`comment`, `punctuation.definition.comment`, `string.comment`) | **`#57606A`** (remapped) | `#768390` → **`#6E7882`** |
| Keyword, storage, storage.type, `constant.character`, `constant.other.placeholder`, `punctuation.section.embedded` | `#CF222E` | `#F47067` → **`#CF6C65`** |
| String, regexp, `string.other.link` | `#0A3069` | `#96D0FF` → **`#92BEE1`** |
| Constant, number, `variable.language`, `support`, `meta.property-name`, `entity` (other), `markup.inline.raw`, `meta.diff.header` | `#0550AE` | `#6CB6FF` → **`#6EA6DD`** |
| `entity.name` (types, classes), `variable`, `meta.definition.variable`, `punctuation.definition.list.begin.markdown` | `#953800` | `#F69D50` → **`#D69359`** |
| `entity.name.function`, `meta.diff.range` (bold) | `#8250DF` | `#DCBDFB` → **`#C7B0DE`** |
| `entity.name.tag`, `support.class.component`, `support.type.property-name.json`, `markup.quote` | `#116329` | `#8DDB8C` → **`#8BC68A`** |
| `variable.other`, `variable.parameter.function`, `meta.object.member`, `meta.embedded.expression`, `storage.modifier.import` | `#1F2328` | `#ADBAC7` → **`#A1ABB5`** |
| `invalid.*` (italic), `message.error` | `#82071E` | `#FF938A` → **`#DC8B84`** |
| `markup.inserted` (diff +) | fg `#116329` on `#DAFBE1` | fg `#8DDB8C` on `#113417` (filtered ≈ fg `#8BC68A`) |
| `markup.deleted` (diff −) | fg `#82071E` on `#FFEBE9` | fg `#FF938A` on `#5D0F12` (filtered ≈ fg `#DC8B84`) |
| `markup.heading` (bold) | `#0550AE` | `#6CB6FF` → `#6EA6DD` |

  Source: `~/Projects/hermes-ios/node_modules/@shikijs/themes/dist/github-light-default.mjs` and
  `github-dark-dimmed.mjs` (version 4.3.1, the same pin as ref238's `package-lock.json`).
- **Languages:** whatever Shiki bundles (`language in bundledLanguages`: 235 grammars, 332 names with aliases, so
  `py`, `sh`, `bash`, `zsh`, `ts`, `yml` and so on all resolve). `text` stays plain. Any other unknown tag (including
  `env`) renders as plain text in the theme foreground (`shiki-block.tsx:47-49,90-92`; `shiki-highlighter.tsx:177`
  passes `language || 'text'`).
- **When highlighting runs** (web):
  1. **Never while its message is streaming:** every fence in a streaming message renders plain
     (`defer={isStreaming}`, `markdown-text.tsx:754`; `plain = defer || …`, `shiki-highlighter.tsx:159`).
  2. Only when the card is on screen or within **160 pt** of it, the app is in the foreground, the chat isn't
     parked mid-transition, and the user isn't holding a text selection over it (an IntersectionObserver with
     `rootMargin: 160px`) (`src/visible-syntax.ts:6-14,47-50`; gate `build/visible-syntax-gates.ts:2-7`).
  3. Never for code over **150,000 characters or 3,000 lines** (stays plain, drawn in 200-line chunks)
     (`shiki-highlighter.tsx:45-47,67-84,91-106`).
  4. A cache miss waits **120 ms** (debounce) before tokenising; results are cached by (theme scope, language, code),
     at most 512 entries / 6 M characters, so reopening a chat repaints instantly (`shiki-block.tsx:32,122-166`;
     `vendor/.../components/chat/shiki-highlight-cache.ts:17-18`).
  5. Highlighting changes colours only, never geometry: the plain fallback uses the same `pre`/`code` layout
     (`vendor/.../components/chat/shiki-plain.tsx:1-9`).
  - While plain, the web draws the code in the foreground at 90 % (`code-card.tsx:39`); after highlighting it uses
    the theme foreground. **DECISION (native):** draw plain code in the theme's default foreground from the start,
    so highlighting changes only the token colours.
- **DECISION (native highlighter):** M1 must not embed a JavaScript engine just to run Shiki. Use a native tokenizer
  (for example a tree-sitter based highlighter, or a small hand-written tokenizer for the languages in the label map
  above), mapping its token kinds onto the scope rows of the palette table. It must:
  - run off the main thread, keyed by (language, code hash), with an LRU like the web's;
  - apply its result as attribute (colour) changes only, with no relayout;
  - follow the same deferral: plain while the message streams, highlight after the turn settles, and only for cards
    within 160 pt of the visible area;
  - skip code over 150,000 characters or 3,000 lines.
  Exact token-for-token parity with Shiki/TextMate grammars is not required; the colours per token kind are.
- While its message streams the web also gives the card a soft accent glow and fades its bottom 24 pt
  (`vendor/.../styles.css:2093-2109`). **DECISION (M1):** omit the glow. It is decoration, and Power Saver already
  turns it off (`src/power-saver.css:13`).

---

## 3. Tool calls (compact rows: "work trail")

The default **Tool Call Style is Rows**, and the default **After Reply is Keep**
(`src/ui-chat/tool-calls-setting.ts:11-33`). The Bubbles and In Header styles and Hide When Done are settings for later
milestones (`memory/tool-calls-hide-when-done.md`). The work trail is on in Release (`src/ui-chat/flags.ts:28,33`).

### 3.1 The run row (collapsed)

- **One row per run** of consecutive tool calls. Runs separated only by silent reasoning or empty text count as one
  run (`src/ui-chat/trail-model.ts:108-126`).
- Layout: `[18 pt glyph] 8 pt [title, one line, ellipsized] [trailing meta] [14 pt chevron]`. The row is at least
  40 pt tall with padding 8 top/bottom and 2 at the sides. Text is Subheadline 15 in **label-2**. There's no
  background; a press shows Fill 4 with radius 10 (`src/ui-chat/trail.css:4-15`).
- The chevron is label-3 and points right when closed and down when open (`src/ui-chat/trail-view.tsx:31-32`).
- At accessibility sizes the title wraps (`trail.css:10`).
- Two adjacent runs overlap by −6 pt, so they read as one list (`trail.css:18`).
- **Glyphs** are 24-unit SVG paths with stroke 1.6 and round caps and joins (`trail-view.tsx:20-29`):
  - thinking: `M8 17c-5-4-3-12 4-12s9 8 4 12M9 20h6M9 17h6`
  - terminal: rect (3,5,18,14, rx 3) + `m7 9 3 3-3 3m6 0h4`
  - file: `M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z` + `M14 3v5h5M9 13h6M9 17h4`
  - explore: circle (11,11, r 6) + `m20 20-4.5-4.5`
  - other: `M14.7 6.3a4 4 0 0 0-5.4 5.4L4 17v3h3l5.3-5.3a4 4 0 0 0 5.4-5.4l-2.5 2.5-2.4-.6-.6-2.4z`
  - The glyph is picked from the summary's first word: Edited/Editing → file; Explored/Exploring → explore;
    Ran/Running → terminal; anything else → other (`trail-model.ts:101-108`).
  - **DECISION:** SF Symbols could stand in (`lightbulb`, `apple.terminal`, `doc.text`, `magnifyingglass`,
    `wrench.and.screwdriver`), but the owner is used to these drawings, so port the paths.

### 3.2 Title wording (copy the renderer exactly)

- `summarizeToolRun(tools, live)` (`vendor/hermes/apps/desktop/src/components/assistant-ui/tool/run-summary.ts:192-235`).
- Categories, in this order: edit, explore, search, read, browse, interact, analyze, run, delegate, other
  (`run-summary.ts:39-50`).
- Verb and noun per category (`run-summary.ts:52-63`):

  | Category | Past | Present | Noun |
  |---|---|---|---|
  | edit | Edited | Editing | file(s) |
  | explore | Explored | Exploring | file(s) |
  | search | Searched | Searching | query/queries |
  | read | Read | Reading | page(s) |
  | browse | Opened | Opening | page(s) |
  | interact | Performed | Performing | browser action(s) |
  | analyze | Analyzed | Analyzing | image(s) |
  | run | Ran | Running | command(s) |
  | delegate | Delegated | Delegating | task(s) |
  | other | Used | Using | tool(s) |

- Tool → category (`run-summary.ts:68-88`): `terminal` and `execute_code` → run; `read_file`, `list_files` and
  `search_files` → explore; `web_search` and `session_search_recall` → search; `web_extract` → read;
  `browser_navigate` → browse; any other `browser_*` → interact; `vision_analyze` → analyze; `delegate_task` →
  delegate; the file-edit tools **`edit_file`, `patch`, `write_file`** → edit (checked first,
  `vendor/hermes/apps/desktop/src/lib/tool-render-class.ts:11-16`); everything else → other.
- One clause per category (`run-summary.ts:154-171`). With a single item it names it ("Edited wiring.tsx",
  "Searched “hermes agent”", "Read example.com/docs"). Otherwise it counts ("Explored 3 files"). A finished command
  always counts, even alone ("Ran 1 command"); only a live one names the command. The exact naming rules are in §3.2.1.
- While the run is live, the clause of the most recent call uses the present tense. Clauses join with ", " and every
  clause after the first starts lowercase ("Explored 3 files, ran 5 commands").
- Failed calls add ", N tool call(s) failed" (`run-summary.ts:228-232`;
  `vendor/hermes/apps/desktop/src/i18n/en.ts:5378`).
- The trail's last row adds " · 18s", using the duration rounded (`trail-model.ts:3-6`).
- **Thinking rows:** "Thinking" while live; when done, "Thought for 7s", "Thought briefly" (under 1 s), or "Thought"
  (no duration) (`vendor/.../thread/message-parts.tsx:227-237`; `en.ts:5059-5062`).

#### 3.2.1 Single-item naming, exactly (`run-summary.ts:95-171`)

Paths are relative to `vendor/hermes/apps/desktop/src/`. "First non-empty string" means `firstStringField(args, keys)`:
the first listed key whose value is a string with non-whitespace content, trimmed (`lib/text.ts:19-29`). Arguments
that arrive as a JSON string are parsed first; anything unparsable counts as `{}`
(`components/assistant-ui/tool/fallback-model/format.ts:90-106`).

1. **Count per category** = the number of calls, except `web_extract`, which counts the length of its `urls` array
   (1 when missing or empty) (`run-summary.ts:95-103`).
2. **A target is looked up only when the count is exactly 1 and the category isn't `interact`**
   (`run-summary.ts:164`). "Performed 1 browser action" never names anything.
3. **Target per category** (`toolTarget`, `run-summary.ts:123-152`):

   | Category | Target | Example |
   |---|---|---|
   | run (`terminal`, `execute_code`) | `summarizeShellCommand(first of command, code)` (see 5) | "Running npm run typecheck" |
   | search (`web_search`, `session_search_recall`) | first of `query`, `search_term` (legacy); whitespace collapsed to single spaces, cut to 48 characters (47 + "…"), wrapped in curly quotes `“…”` (`compactPreview`, `fallback-model/format.ts:28-50`) | "Searched “hermes agent”" |
   | read (`web_extract`), browse (`browser_navigate`) | the first `https?://` URL found anywhere in the args, searching values depth-first (so both `urls: [...]` and a legacy `url` string work; pattern `https?:\/\/[^\s'"<>)\]]+`), shown as **hostname + path** (the path is dropped only when it is `/`); an unparsable URL is shown as-is (`fallback-model/targets.ts:57-89`) | "Read example.com/docs", "Opened a.example" |
   | edit, explore, analyze, other, delegate | first of `path`, `file`, `filepath` → its last path component (backslashes count as `/`; `fileEditBasename`, `fallback-model/index.ts:75-79`); if none, first of `query`, `url` as-is | "Edited wiring.tsx", "Explored status.ts" |

   No target (empty string) falls back to the count form: "Analyzed 1 image" (`vision_analyze` takes `image_url`,
   which isn't a looked-up key), "Explored 1 file" (`search_files` with no `path`).
4. **Naming vs counting** (`run-summary.ts:166-170`): use "`<verb> <target>`" when a target exists **and** (the
   category is live **or** the category isn't `run`). Otherwise "`<verb> <count> <noun>`", with the singular noun
   for 1. So a settled single command reads "Ran 1 command"; while it runs it reads "Running <command>".
5. **`summarizeShellCommand`** (`lib/summarize-command.ts:188-216`), display only:
   - Split on top-level `&&`, `||`, `;` and newlines, ignoring separators inside quotes (pipes do not split).
   - Strip a trailing pipe into `head`, `tail`, `wc`, `sort` or `uniq`.
   - Clean each part (`lib/summarize-command.ts:134-155`): drop a standalone redirection word (`>`, `>>`, `<`, with an
     optional fd number, such as `2>`) together with the word after it, and drop `N>&M` / `N<&M` words such as `2>&1`.
     Redirections glued to their target (`>out.txt`) stay.
   - With one part, show it (cleaned).
   - Otherwise drop the setup parts (`cd`, `pushd`, `popd`, `export`, `set`, `unset`, `source`, `.`, `true`, `false`,
     `:`) and banner `echo`s (`echo` with `--`, `_exit=`, `$?`, `${` or `PIPESTATUS`). One left: show it. Several left:
     "`<first> + N command(s)`". None left: show the original.
   - `execute_code` passes its `code` through the same function.
6. **Which clause is live:** when the run is live, the category of its first pending call (no `result` and no
   `completedAt`), or of its last call if none is pending, uses the present tense (`run-summary.ts:197-198`). On the
   phone a chain is live only while the message is running **and** the chain is the message's tail
   (`src/ui-chat/trail.tsx:65`).
7. **Skill calls** (`skill_view`, `skills_list`) don't join a category; they lead the summary as their own clauses:
   "Loading skill" / "Loaded skill" / "Failed to load skill"; with `file_path`, "Reading skill resource" / "Read
   skill resource" / "Failed to read skill resource"; `skills_list` → "Listing skills" / "Listed skills" / "Failed to
   list skills"; no result → "Skill result unavailable". Each is followed by ": <name>" or ": <name> → <file_path>"
   when present (`components/assistant-ui/tool/skill-activity.ts:16-40`; `i18n/en.ts:5379-5390`).
8. **Failures:** a call failed when `isError`, or its result has `success: false` or `ok: false` or an error message,
   unless the result says `success: true` or `ok: true` (`fallback-model/format.ts:110-119`).

**File edits on the phone are never inside a run.** `edit_file`, `patch` and `write_file` are card tools, so
`splitRunItems` cuts the run around them (`lib/tool-render-class.ts:42-44`;
`components/assistant-ui/tool/fallback.tsx:800-821`). On the phone each edit is its own top-level trail row: the
file glyph, the title `summarizeToolRun([thatEdit], pending)` ("Editing wiring.tsx" while pending, "Edited
wiring.tsx" after), and the chevron (`src/ui-chat/trail-tool.tsx:32-46`; `src/ui-chat/trail.tsx:26-33,47-50`). The
"edit" category therefore only ever appears as a single-item title. `delegate_task` (the subagent card), `clarify`,
`image_generate`, `manage_catalog` and `manage_connections` are card tools that never show as trail rows
(`lib/tool-render-class.ts:31`; `src/ui-chat/trail.tsx:31`).

**Step titles inside an opened run** use the same function on one call (`src/ui-chat/trail-tool.tsx:45`): "Explored
a.ts", "Searched “kv cache”", "Read example.com/docs", and **"Ran 1 command" for every settled command**. The full
command line is in the step's sheet. Copy this as-is.

**⚑ DISAGREES (phone vs renderer):** before summarising, the phone keeps only these argument keys: `command`,
`code`, `path`, `file`, `filepath`, `query`, `url`, `skill`, `name`, `skill_name`, `operation`, `action`. Strings are
cut to 2,048 characters and arrays to 8 items (`src/ui-chat/tool-presentation.ts:2,5-27`;
`src/ui-chat/trail.tsx:66`; `trail-tool.tsx:41`). So in build 238:
- `web_extract`'s real `urls` key is dropped, and every page read shows "Read 1 page" / "Reading 1 page", even for
  several URLs. The renderer's own test expects "Read example.com/docs" and "Read 3 pages"
  (`components/assistant-ui/tool/run-summary.test.ts:81,98-103`). Hermes's schema uses `urls`
  (`~/.hermes/hermes-agent/tools/web_tools.py:543`).
- A skill resource read loses its `file_path`, so it reads as "Loaded skill: <name>".
- `search_term` (legacy) is dropped.

**DECISION (native):** summarise from the full arguments, matching the renderer (`run-summary.ts`) and its tests.
The projection exists only to bound the web's work on huge arguments; native can cut long strings itself.

### 3.3 Opened run (inset card) and steps

- The inset card: margin 2 top and 8 bottom, padding 0 12, radius 14, Fill 4, no border (`trail.css:19`).
- Each step is a row at least 44 pt tall with 10 pt top/bottom padding, separated by hairlines (`trail.css:20-21`).
- Each step's meta: a failure's "Exit 2" / "Failed" (red) (`trail-model.ts:81-86`, `trail.css:11-13`).
  **⚑ DISAGREES (dead code):** `stepMeta` would also show a file's "+12 −3" (green), but nothing in build 238 sets a
  step's `added` / `removed`. The collapsed step carries only `title`, `kind` and `status`, and the details path
  sets `diff` instead (`src/ui-chat/trail-tool.tsx:40-57`; no other producer in `src/`). The shipped edit row shows no
  line counts. **DECISION (M1):** match the shipped row, with no counts.
- Tapping a step opens a sheet with labelled monospace blocks (Command, Output, Error output, Exit code) at Footnote
  size, radius 14, on the elevated cell colour (`trail-model.ts:87-100`, `trail.css:38-43`).
- Opening a run fades the card in. Closed history never builds its step views (`trail-view.tsx:40-45`).
- **Native rule:** never animate row height inside the transcript. Insert or remove the card with no height
  animation, fade its content, and let the list's normal update move the rows below
  (`memory/tool-calls-hide-when-done.md`, "never animate layout height inside the transcript").

### 3.4 Live status while waiting (before any text)

**⚑ DISAGREES (flag off in Release):** everything in this subsection, and the cold-load skeleton in §4.2, belongs to
`PHONE_TURN_STATUS`, which is **`false` in Release** (`src/ui-chat/flags.ts:16,36`; every rule in
`src/ui-chat/status.css:2-21` is scoped to `html.ios-turn-status`). Build 238 shows the renderer's own row instead
(gate `build/ui-chat-status-gates.ts:17-20`):
- a 12 pt pulsing square in the accent, then "Hermes is loading a response" (or a provider wait hint), then an
  elapsed timer;
- at the caption size (13 pt), with the timer in label-2;
- in a full-width row at least 28 pt tall with 8 pt above and below
(`vendor/.../thread/status.tsx:243-268`; `vendor/.../i18n/en.ts:5052`; `src/phone-fe-convo.css:64-74`). The title's
status line (§4.1, "Thinking…") is on in Release either way. **DECISION (M1):** build the capsule below, the phone
design the flag was waiting on, and say so in the build note. It needs no web parity, because the web hasn't shipped
either version to the phone as a finished design.

- A leading 44×30 capsule in the bot bubble's colour holding three 7 pt dots, then the wait text in Footnote label-2:
  "Waiting for <model>". A timer "· 0:12" appears after 10 s, and after 60 s with no step running the text becomes "<Bot> is still thinking…" (or "still working…" once it has run steps)
  (`src/ui-chat/status.css:2-6`, `src/ui-chat/turn-status-model.ts:15-24`).
- The dots animate opacity 0.45 → 1 → 0.45 over 1.5 s, staggered 0.18 s (`status.css:18-23`).

---

## 4. Chat screen layout

### 4.1 Top bar (no surface; floating glass controls)

- **Owner's ruling:** keep the bar's layout (Back · centred head + name · ⋯), only steadier, and don't re-propose
  layout overhauls (`memory/chat-status-line.md`).
- The bar has no surface. The transcript scrolls up under the status bar, and Back, the title and ⋯ float over it
  as separate glass pieces (`src/phone-ui-chat.css:263-273`).
- Placement: the bar's minimum height is the top safe area + 52 pt, with 4 pt bottom padding and 16 pt side insets
  (`src/phone-ui-nav.css:146`). On the owner's 402 pt phone the 44 pt controls sit at y = 64, 16 pt from the sides,
  which matches Telegram (`memory/telegram-field-sizing.md`).
- **Back:** a 44 pt glass circle with a 26 pt chevron at stroke 2.25 (`phone-ui-nav.css:147-151`).
  - When other chats have unread replies, Back becomes a glass capsule "‹ N". N counts unread bots plus unread chats.
    The capsule has padding 0 14 / 0 8, and the count is 17 pt semibold (capped at 22) with tabular digits
    (`phone-ui-nav.css:152-154`; `memory/reply-peek.md`).
- **Title:** a glass **rounded rectangle, radius 14** (not a capsule: the owner disliked a head inside a capsule), 44 pt
  tall, padded 0 14 / 0 5 (`phone-ui-chat.css:274-277`; `memory/chat-status-line.md` build 69).
  - Contents: a **34 pt head**, a 10 pt gap, then the name in 17 semibold (capped at 22), one line with an ellipsis
    (`src/ui-chat/title-view.tsx:33,144-149`; `phone-ui-chat.css:15,181-185`). Max width `min(66 % of the screen, 300 pt)`
    (`phone-ui-chat.css:172`).
  - A session that isn't the bot's own chat shows the bot's name under its title in 13 pt (capped at 18) label-2
    (`title-view.tsx:140-142`, `phone-ui-chat.css:17,188`).
  - Tap or hold opens Bot Info. The press dims to 60 % (`phone-ui-chat.css:176`).
  - Group rooms use a 26 pt face (`title-view.tsx:33`).
- **⋯:** a 44 pt glass circle with a 22 pt glyph (`phone-ui-nav.css:155-158`). Its menu holds a "Model" submenu (later
  milestone).
- **Scroll edge** behind the bar, so the clock and controls stay readable:
  - Solid page colour down to the bottom of the top safe area, then the page colour at 80 % opacity at 62 % of the
    height, then transparent. It blurs 12 and is masked to fade out from 72 % (`phone-ui-chat.css:231-232,270-273`).
  - It runs 10 pt below the status line's area.
  - **Native:** with no system navigation-bar background, use iOS 26's scroll edge effect
    (`UIScrollEdgeEffect` / `.scrollEdgeEffectStyle(.soft)`) on the chat's scroll view. That is the native version
    of this fade. **DECISION:** prefer the system edge effect over a hand-made gradient view.
- **Status line** (owner, 2026-10-02): what the bot is doing, on its own line under the title, so it never moves
  anything (`phone-ui-chat.css:242-262`; `memory/chat-status-line.md`).
  - Height = subtitle size × 1.25 + 6 ≈ **22 pt** at default size. It rises 4 pt into the bar
    (`phone-ui-chat.css:17,245`).
  - A small capsule (padding 0 10, 6 pt gap, max width 240 when tappable). It holds three 3 pt dots (2 pt gap,
    opacity 0.4 → 1 over 1.2 s, staggered 0.2 s) and the words in 13 pt (capped at 18) (`phone-ui-chat.css:188-200,280-281`).
  - Colour: tint-text in light and label in dark for "working" (`phone-ui-chat.css:192-194`).
  - Words (`src/ui-kit/bot-status.ts:29,42-51`): "Thinking…", "Running a command…", "Writing…", "Using its computer",
    "Waiting for your approval" (orange), "Waiting for your reply" (orange), "Waking up…" (with a 10 pt spinner),
    "Offline", "Reconnecting…", "Can’t reach this bot".
  - Shown only while not idle. The transcript's top padding always reserves the line's space, so it appearing or
    disappearing moves nothing (`phone-ui-chat.css:303-305`).
  - Web draws it on a material (a text panel). **DECISION (native):** a `UIGlassEffect` capsule is fine, because native
    content inside glass stays live. The web only avoided native glass there because its mirrored glass froze the
    dots (`memory/tool-calls-hide-when-done.md`, build 192).

### 4.2 Transcript

- Content inset: 16 pt at the sides. The top starts 12 pt below the bar plus the status line's reserved space
  (`src/renderer-mobile.css:195`; `phone-ui-chat.css:300-305`).
- The user prompt is **not** sticky on the phone (`renderer-mobile.css:199` disables the desktop's sticky prompt).
- Background: the page colour, with no wallpaper (§12). **Exception (owner, 2026-10-30: "Custom background
  support"):** Settings › Appearance › Theme › Chat Background puts a picture the person chose behind every chat, in the
  iOS look only. It is off until a picture is chosen. With one set, the grey lines on the page (days, notices, tool runs,
  group lines) get frosted pills, opened cards take the reply bubble's colour, and an empty chat's intro gets a glass card
  (`App/Theme/Backdrop.swift`). The pills are the system's thin material, flat with no rim (owner, 2026-11-01, with
  glass bubbles on: "more flat in some way. Just so it's not ALL glass", then "I like frosted the most"). Glass pills
  measured 3.2–4.4:1 in four places over Sunset and a busy photo; frosted 5.6–7.5:1 everywhere. Solid page-colour pills
  were heavy black chips in dark mode, and words with no pill could not be read on a busy photo. The thinking row ("Ivy
  is running npm test… · 0:12") gets one pill round its typing
  dots, words and timer, inside the 16 pt column: the dots stand on it with no grey capsule of their own, and
  the words, dots and timer take the primary label (owner, 2026-11-01: "with a background, the tool calls at the bottom
  are hard to read", then "the 3 dots look cheap" in a capsule inside the pill; label-2 measured 3.9:1 on dark glass).
  Every pill's words take the primary label too, a count or chevron after them label 2 (2026-11-01: on the glass pills
  label 2 measured 2.5–3.6:1 in dark mode; a dark tint on the glass was dropped when the pills went frosted).
  The app never picks a wallpaper itself: the Telegram gradient stays rejected. Tinted bubbles (§2.2) borrow
  Telegram's way of showing the wallpaper through a bubble, not its colours, and only over a picture the person chose.
- **App Background (owner, 2026-11-01: "change my background in the rest of the app… one background on all of the app
  and then a separate background for chats. Or I can have them be the same… like 10 different backgrounds"):** Theme ›
  Backgrounds has two rows, App Background and Chat Background, each opening its own page (preview, Pictures grid,
  Dim, Blur). The app's picture sits behind every tab page and what it pushes (Sessions, Bots, Jobs, More, Settings,
  Files, Boards…), never behind sheets, and never in the Desktop Look. Rows keep their solid cards; a pinned title band
  shows the same picture, lined up with the page's, so there is no seam. Chats start on **Use App Background** (their
  own Dim and Blur still apply); choosing a chat picture turns that off, and a chat picture from before 2026-11-01 stays
  the chats' own. Dim starts at 45 % for pages, 30 % for chats. The Pictures grid: None, ten of the app's own
  (`App/Theme/BackdropPresets.swift`, drawn on the phone for each look and screen size; Theme Glow follows the theme
  colour), and Your Photo. Under it, four more groups, eight pictures each, in
  `Packages/WallpaperArt/` (owner, 2026-11-05, of these styles side by side: "I love them all"): **Photographic** (real
  terrain, clouds and water, ray-traced and lit), **Illustrated** (flat inks and bold shapes, like a printed travel
  poster), **Painted** (brush strokes over a lit study) and **Doodles** (packed hand-drawn sets: Forest, Peaks, Gaming and
  Sports on the masculine side, Rose and Lilac on the feminine side, Travel and Café neutral; owner 2026-11-03). The three
  landscape styles are kept in Caches once drawn (`BackdropPictureCache`, PNG, at most 200 MB): a Photographic picture
  costs about 6 CPU-seconds the first time. A picture picked in builds 722–723 that has since been replaced moves to the
  nearest new one (`BackdropPreset(stored:)`). These are pictures the person picks; §12's rejected Telegram
  *wallpaper* was a forced default with Telegram's colours. Still off until the person picks one.
- Cold load with nothing cached: a skeleton of one trailing 56 %-wide, 48 pt-tall bubble shape and three leading
  16 pt lines in Fill 3 with a shimmer. Never a spinner on white (`status.css:12-16`). **Native target:** the cache
  makes this rare. **⚑** The skeleton is behind `PHONE_TURN_STATUS` (off in Release, §3.4). Build 238 shows the
  renderer's centred 48 pt rose-curve loader in the accent at 70 % instead (`vendor/.../thread/status.tsx:222-240`;
  gate `build/ui-chat-status-gates.ts:33`). **DECISION (M1):** use the skeleton.
- An empty bot chat shows the bot intro: an 80 pt head, the name in Title 2, the role and description in Subheadline,
  and capsule buttons in tint at 15 % (`src/ui-bots/bot-intro.tsx:25-31`; `src/phone-ui-bots.css:126-138`).

### 4.3 Composer row (Telegram's measurements; owner, 2026-10-09)

Measured from the owner's Telegram screenshot and matched in builds 237–238 (`memory/telegram-field-sizing.md`).
For a 402 pt-wide phone with a 34 pt home-indicator inset:

| Measure | Keyboard down | Keyboard up | Source |
|---|---|---|---|
| Control size | 40 pt visible, centred in a 44 pt hit box (2 pt inset) | same | `phone-ui-chat.css:374,384-386,429-430` |
| Glass from the screen's sides | **26 pt** (dock 8 + row 16 + inset 2) | **8 pt** | `phone-ui-chat.css:317,376-382` |
| Glass bottom above the screen bottom / keys | **29 pt** | **8 pt above the keyboard** | `phone-ui-chat.css:319-325,374,381` |
| How the web gets the bottom gap | the chat box extends 11 pt into the 34 pt inset (`max(0, inset − 23)`), and the row adds 4 pt of padding + 2 pt of inset | padding 6 + inset 2 | `phone-ui-chat.css:325,374,381` |

- **One bar (native, 2026-10-31; owner: "redesign this section to make it a lot better"):** in the iOS look the row is
  a single Liquid Glass bar, 26 pt from the sides (8 with the keys up) and 29 pt above the screen bottom, as before.
  It replaced four glass shapes side by side, which left the field ~212 pt wide on a 402 pt phone. The Desktop Look's
  one box is unchanged (`ComposerView` `applySurfaces`). The bullets below are the Telegram row it replaced.
  - **Always two rows:** at rest, focused or holding words, the bar is the same: the text across the top (16 pt in,
    16 pt above, 12 pt below) and a row of buttons below. Owner 2026-11-01: "the text input section at the bottom
    should always be the 2x height version instead of starting 1x height and growing when you click it". Until then
    it rested in one row (44 pt, radius 22: +, ☰ and the mic on discs, the text between) and grew on focus; ☰ and the
    mic had been plain glyphs that grew discs on focus until the owner said it "feels wrong" (2026-10-31), and a faint
    ☰ that hid while typing was rejected ("an awful UX"). The model bubble is there from the start; it reads the
    chat's model whenever that changes, and again on focus. Each button is on a 36 pt disc of Liquid Glass
    of its own (`ComposerGlassDisc`; owner 2026-10-31: "all of the bubbles in the chat thing to be liquid glass"), the
    discs 8 pt apart and 8 pt from the bar's edges. A press sinks a disc to 90 % (it dims under Reduce Motion). The corner grows to 26 so they stay concentric with it. The row is +, ☰,
    the model bubble, the mic, then the circle. The mic records a memo on an empty field and is Dictate (words at the
    cursor) once there are words, so each end keeps two buttons.
  - **Model bubble:** a 36 pt capsule of the same glass holding only the model's name ("Opus 5.5", 15 pt in label,
    no chevron; a "provider/model" id shows its model part). It is as wide as the name plus 22 pt either side, never
    narrower than 72 pt (twice its height), and sits centred in the room between ☰'s disc and the next disc (the mic,
    Dictate, or the circle when neither stands there), at least 8 pt from each, so the gaps either side are always
    equal. On a switch it eases to the new name's width (0.25 s, none under Reduce Motion). The effort is in the
    panel; VoiceOver still reads it ("Opus 5.5, High"). Owner 2026-11-01 picked this over a bubble across the whole
    room: "the bubble width is small and it only shows the model name". The words always fit and never end in "…":
    a name too long for the room takes all of it, then gives way to its form without the tag ("Preview", "Free"),
    then without its filler words ("Instruct", a release number like "2507", a format like "FP8"; "Meta" before
    Llama), each allowed to shrink a little (to 86 %) first; only then does the type shrink further. Always one
    line: two in the capsule "would be busy" (owner 2026-10-31). It is not drawn in chats that can't
    switch models. Owner: the row was "missing something"; the center "needs to be in a bubble"; "minimal info"; the
    reference (Claude's composer) for spacing; then "that must be always even … never … an ellipsis" (2026-10-31).
    While its panel is open the glass stays plain and the name takes the tint: a tint fill read as a second blue
    mass beside Send (owner: "too visually heavy").
  - **Model panel** (a tap on the bubble, or ⋯ › Model; `App/Chat/Menus/ModelPanel.swift`): the keys go down and the
    bar keeps its two rows, the bubble's glass tinted. A glass card (radius 34, at most 440 wide, 12 pt above the bar)
    springs out of the bubble, with the page dimmed and lightly blurred behind it and the bar sharp on top.
    - **Two ways in, one place.** The bubble shows only in the two-row bar, so the ⋯'s **Model** row (`cpu`, the
      model and its thinking under it, "Sonnet 5 · Medium", or "Offline") opens the same panel: from a one-row bar the
      bar grows into its two rows first and the card springs from the bubble there, which shows where it lives; the
      Desktop Look's bar has no bubble, so the card rises in place, and folds back the same way. The ⋯ used to hold a
      Model submenu with its own picker, Reasoning and Fast; owner 2026-11-01 ("Do the weak points"): one control,
      one place. Its blocks rise in one
    by one. Owner, on a first build that followed another app's Model Settings sheet: "rebuild it to be our own … the
    slider even … unique to Hermes HQ".
    - **What it is for:** how this chat thinks, and nothing else. Its model, thinking, Fast and skipping approvals are
      this chat's alone in Hermes (session-scoped `config.set`); only the approval mode is the bot's. The bot's own
      models (default, fallbacks, auxiliary) are in its Bot Info, and app-wide things (saved prompts) and the chat's
      actions stay in the ⋯, so the panel overlaps neither. Owner 2026-11-01 on a cut that held the whole ⋯ in tiles:
      "looks like we're just … cramming everything into one thing. It doesn't feel like we tried to like
      thoughtfully design it"; on Prompts: "you wouldn't save a prompt for a certain chat". Four blocks, top down:
    - **Who:** the model's name (title 2 bold) with its tag, its maker under it, and `chevron.up.chevron.down`
      (subheadline semibold, label 2) after the name on its first line. The name and maker are one button, Switch
      Model (a header to VoiceOver, its words dimmed while held), that opens a native menu titled with what a pick
      changes ([model-scope] owner 2026-11-03: "Applies to this chat only. Change <bot>’s default in Bot Info ›
      Brain.", `ModelPanelModel.switchScope`; no title at the accessibility text sizes, where it filled the menu
      ahead of the picks: `switchMenuTitle`), in a fixed order:
      **Favorites** (every one, the current model checked, each with its short maker), **Recent** (up to five that
      aren't favourites or current), **All Models** (one submenu per provider, "12 models", read from the catalog as
      the menu opens, with the menu's own loading row meanwhile; a one-provider catalog lists its models in place;
      when it can't, "Couldn’t load models" (disabled) above **Try Again**, which reads the list again for the next
      open, as 3x-composer §12.2 point 5), then **Search All Models**, which opens the Models sheet. A switch
      puts a spinner where the chevrons were, then the face cheers once and the thinking bar flashes. Owner on the
      first cut, a wrapped cloud of capsules: "Needs to be A LOT cleaner"; on three tiles: "a menu that opens all and
      shows the favorites first" (2026-10-31).
      - The chat's bot (its head or photo, 60 pt) sits in the top corner, level with the name (owner 2026-11-01:
        "put the bot image in the top right because that space is unused"). It acts the thinking level out: at Off it
        rests and looks at you, at any other level it acts out thinking, its animations running at 1× at the least
        level up to 2.2× at the most (`HeadView.posedMood`). A tap closes the panel and opens the bot's Bot Info
        (VoiceOver: the bot's name, "Opens Bot Info: its default model, fallback models and auxiliary models"). With
        no Bot Info to open (a chat that isn't a bot's) it is only a picture.
    - **Facts** on one solid strip (radius 14, at least 44 pt tall) in equal centred columns, each a value
      (subheadline semibold) over a caption (footnote, label 2): **1M** Context (the chat's window, else the id's
      "[1m]" tag, else models.dev's `limit.context`), **18%** Used (once the chat has used any), the price
      (**Included** / **Free** Price, or **$5 · $25** "In · out per 1M") and the plan (**62% left** Weekly, **Rate
      limited** "Back in 2 h"), or **Available** / **Offline** Status with no plan. VoiceOver reads each column whole
      ("$5 in · $25 out per 1M"). Two columns to a line at the accessibility sizes. Owner on the first cut's
      left-hung capsules: "This section needs to be visually balanced better".
      - The price and the plan end their captions in a small `chevron.forward` and are buttons: Price closes the
        panel and opens Model Prices, the plan Usage & Limits (the ⋯'s own pages; VoiceOver "Opens Model Prices").
        They replace the panel's earlier Usage and Prices tiles, which said the same thing twice. Offline both pages
        need the gateway, so the columns rest without their chevrons.
    - **Thinking** on one slim row (owner 2026-11-01: "the effort selector something that took up a lot less room";
      it was the face in a 248 pt ring): "Thinking" (subheadline semibold) with the level and what it means at its
      end ("**High** · Thinks hard"; Off "Answers straight away"), under it when they won't share a line, over a bar
      22 pt thick with a 34 pt tint knob ringed in white and a 6 pt dot at each level, lit in the tint up to the knob.
      - Dragging along the bar ticks at each level crossed and settles on the nearest on release (a critically damped
        spring). On the bar the knob follows the finger and a tap jumps to the level; on the words a sideways drag
        slides it (right is harder) and an up-or-down drag still scrolls the card. A drag the card takes back puts the
        level back where it was. It sets Reasoning. VoiceOver adjusts it.
      - While the panel is open the page's back swipes are held: a drag right on the thinking control pulled the whole
        page off to go back (owner 2026-10-31). They come back as they were when it closes.
      - While the knob moves, lights with soft tails run up the lit part and pour into the knob, which glows; faster as
        the level climbs. As the panel opens the bar fills from empty up to the level.
      - **The drive** (`App/Chat/Menus/ThinkingDrive.swift`; Settings › Sounds & Haptics › Thinking Bar: Lightspeed,
        the default, Afterburner or Calm). Owner 2026-11-01: "a haptic feedback that accelerates. It gets more
        aggressive as you slide it towards the highest effort … like you're going into hyperspace … the visual
        matches it. Feel free to have a lot of fun with this". While a finger holds the bar, a Core Haptics hum runs
        under it and the bar beats: each beat is a knock and a light at the same moment, the beat's rate multiplying
        by the same share at each level (Lightspeed 2.5 to 28 a second, Afterburner 1.6 to 22), the hum and the knocks
        growing stronger and sharper. Crossing a level knocks, harder higher up; reaching the top level with the finger
        down is the jump (a heavy hit, a sharp one on its heels, a rumble falling away). Letting go winds it down over
        a second or two.
        - **Lightspeed** (owner 2026-11-05: "much more epic"; `LightspeedScript.swift`, `LightspeedSky.swift`, `LightspeedSkyShader.swift`):
          stars stream through the lit part into the knob, dots near Off and lines at the top, and each beat runs back
          down the bar. The lit part stays the theme's colour so the level reads. Behind the card the page goes to true
          black and 1,400 stars pour out of the knob, following it all the way up. Its moments:
          - **Breath**, from the last level but one to the top level's halfway point: the stars crowd ahead and slow,
            the tails shorten, the page reaches black, the knocks go quiet and sharp and the hum sinks.
          - **Hit**, at that halfway point or when a finger landing at the top has heated up: in one frame the double
            hit, a radial flash just behind the card's top edge, the sky's centre knocked 6 pt down, the tails at full
            length; then a front runs out to the far corner, bending and brightening the stars it passes. No ring is
            drawn. The stars' centre starts from the knob and falls to that spot in about 0.8 s (owner 2026-11-05:
            "naturally fall into the center"). Pulled back under the halfway point it heads back to the knob at once,
            in about 0.5 s, on the same spring, so turning back partway never kinks.
          - **Cruise**, held at the top: no knocks (the shaking stops as it breaks through), the hum swells and falls
            every 1.6 s, the card's edge is an eclipse's rim (brighter than white on screens that can), and a near star
            passes every 2.5 to 4 s with a thump.
          - **Drop**, letting go in the warp: a thud with a dying rumble and a tick as it docks; the tails snap into
            their stars in 120 ms, and the page opens out from the centre by 700 ms. A lift lower down just fades.
          - The page flashes at most once in 1.5 s, and only after the knob has been back under the last level; beats
            never touch it. Without Metal the older lines draw. `-HQDebugWarpFreeze <stage:value>` holds a moment for
            screenshots; census `modelpanel-warp` sweeps it (`-HQDebugWarpDown YES` for the old path back to High).
        - **Afterburner:** the knob is an engine and the bar its exhaust. The plume runs from the tint through magenta
          and orange to white at the nozzle, heat streams back through it, lens-shaped shock diamonds stand behind the
          nozzle from Medium up, sparks streak off the knob from High up, and every beat sends a tongue of flame back
          down the plume. Behind the card the page darkens to a furnace glow that breathes with the beat (orange to
          red, never white, so the card takes its colour rather than going grey) and embers rise past the card. The
          jump is a shower of sparks, an orange flash and a ring. Its knocks are heavier and duller than Lightspeed's.
        - **Calm** is the bar as before: a tick at each level.
        - Under Reduce Motion, in Low Power Mode and in the Desktop Look the bar and the page draw calmly (no fill, no
          backdrop); the haptics still run. A light page gets a deeper veil so it reaches the same night. Haptics off
          in Settings stops the hum and the knocks. Without Core Haptics the knocks fall back to impact taps, at most
          25 a second.
      - A model that doesn't think shows "Thinking" with "This model answers without a thinking step" and no bar to
        move; one with a single level names it ("High · Thinks hard · its only level").
    - **Fast**, **Approval Mode** and **YOLO** as three rows of one solid card (radius 14), like a Settings
      group: each row at least 50 pt, a symbol in the tint, its name (body), its end; a hairline between them from the
      names on. A row that reaches further or less far than the rest says so under its name (footnote, label 2). At
      the accessibility sizes the value goes under the name and note. Owner 2026-10-31: "The pop-up for the model
      needs to also have your approval settings on it and fast mode".
      - Fast (bolt) ends in a switch; a tap anywhere on the row turns it on or off. A model with no fast mode keeps the
        row, dimmed, saying "Not on this model" in place of the switch, so Fast is always found in the same place.
      - Approval Mode (shield) is the one bot-wide thing in the panel, so it says so under its name: "Every chat with
        Hermes" (the bot's name; "this bot" before it is known). It ends in the mode (label 2) and chevrons, and opens
        a native menu headed with the same words: Manual "Ask before actions that require approval", Smart
        "Automatically assess actions and ask when needed", Off "Run without approval prompts". Names and words are
        Hermes' own (`approvals.mode`, the desktop app's Approval mode menu; owner 2026-11-01: "Idk if these are the
        same terms that Hermes uses"; until then Approvals / Skip Approvals and our own sentences) (`config.set approvals.mode`, the bot's
        config, so every chat with it and its jobs follow; the current one checked). At Off the shield turns to an
        orange `exclamationmark.shield.fill`.
      - YOLO (`shield.slash.fill`; Hermes' name for it in the CLI, the TUI and the desktop app), right under it, is
        this chat's exception: a switch with "No prompts in this chat" under its name (`config.set yolo`, as /yolo
        does). Its shield is orange while on; the Approval Mode row keeps
        saying the bot's mode. They were one menu with two sections, the bot's modes and this chat's skip; owner
        2026-11-01 ("Do the weak points"): one control reached two ways, now two rows that each say how far they go.
      - The mode comes in the chat's info (`approval_mode`); an older Hermes that leaves it out is asked once with
        `config.get approvals.mode` as the panel opens, the row showing its name alone meanwhile. A pick shows at
        once and goes back, with "Couldn’t Change Approvals", if the gateway refuses it.
    - On a 402 pt phone the whole card fits the room above the bar at Large and XL text with nothing to scroll; at the
      accessibility sizes the card scrolls under a faded bottom edge.
    - **Any model, any provider** (owner 2026-10-31: "We need to guarantee this works no matter the model and provider
      someone uses"). Nothing assumes a length (`App/Chat/Menus/TextFit.swift`): words take one line, shrink a little
      to stay on it, then wrap between words onto the lines the place allows, and only then shrink. An id with no
      spaces may break after `_`, `/` or `:`, and between letters when even that would leave it too small to read.
      - The tag pill rides beside the name while they share a line, else the tag follows the name in label 2 words.
      - A row's name and value take two lines each before they shrink.
      - The maker is the catalog's provider name without its notes, else Hermes' own name for the slug, else the
        slug in words ("vertex_ai" → Vertex AI); never a bare slug. Two lines (three at the accessibility sizes);
        a name that would only read small in them (a sign-in's whole sentence) shows the short form, and the full
        name stays in the name's spoken label.
      - The short form (also under each model in the menu): the first clause, without "Subscription" or "Account",
        an address as its host ("Anthropic OAuth", "ChatGPT or Codex", "192.168.1.20:8080").
      - The facts strip's columns go two to a line, then one, when a value or caption won't read at its size in an
        equal column (a long price); a short last line shares the full width. A caption may take two lines.
      - A level's words too long for the line beside "Thinking" go under it, two lines (six at the accessibility
        sizes) before they shrink.
      - Offline, the rows, the name's chevrons and the bar stay dimmed after the panel opens.
      - Checked by `Tests/Menus/ModelPanelAnyModelTests.swift`: 21 real-world ids from every kind of provider plus
        the hard states, at 320/375/402/440 pt and Large to AX Large text. Every label's words sit in its frame, no
        two pieces overlap or leave the margins, nothing is drawn under half its size (bar a 47-letter id with no
        break at all in a 320 pt window); the bubble on one line at 130 to 300 pt.
      - The name takes up to three lines before it shrinks (four at the accessibility sizes).

    It closes on a tap outside, a swipe down, the VoiceOver escape, Search All Models, or the keys rising, folding back into
    the bubble. Under Reduce Motion it fades, nothing runs and the face is still. Owner: "very epic … pop-up … the
    context window, effort … animation behind it" (2026-10-31).
  - **The keys come back:** a pop-up opened while the keys were up brings them back when it closes, whichever way it
    closes. That covers the model panel, All Models, the ☰ sheet, the + menu's pickers, Prompts, Usage, Prices, and
    any sheet the chat presents. It is not done on the Mac. See `ChatViewController+KeysReturn.swift`. Owner
    2026-10-31: "you should be returned to the keyboard open again".
  - The recorder and a voice draft take the bar from its two rows to their own (as they did before).
- **Order:** `[☰ commands 40] [+ 40] [field ≥40, mic inside at the trailing end] [primary 40]`
  (`src/ui-chat/composer.tsx:47-58`; `phone-ui-chat.css:375-376,383-396`). The ☰ appears in 1:1 chats on iPhone only.
- **Gaps between glass shapes:** ☰ ↔ + is 7 pt (3 + 2 + 2); + ↔ field is 6 pt (4 + 2); field ↔ primary is 6 pt
  (`phone-ui-chat.css:375-376,383`).
- **☰ and +:** glass circles. Glyphs are 18 pt masks in label-2: plus `M12 5v14M5 12h14` (stroke 2.2) and menu
  `M5 7h14M5 12h14M5 17h14` (stroke 2) (`phone-ui-chat.css:19-20,385-394`).
- **Field:**
  - Glass with radius 18. It's round at one line and becomes a rounded rectangle as it grows (`phone-ios-tokens.css:69-70`).
  - Minimum 40 pt tall, 14 pt horizontal padding. Text is Body (17/22) at a minimum of 16 pt, with 8 pt top and
    bottom padding (`phone-ui-chat.css:399-409`).
  - It grows to **6 lines** (3 at accessibility sizes), then scrolls (`phone-ui-chat.css:408,415`).
  - Placeholder: "Message <Bot name>", or "Message" when no bot is known. It stays one line, clipped
    (`src/ui-chat/chat-words.ts:3-7`; `phone-ui-chat.css:413-414`).
  - Off glass (Reduce Transparency), the field has a 1 pt border in Fill 1 on the page colour (`phone-ui-chat.css:399-400`).
- **Mic:** a 44 pt box inside the field's trailing end. The field's trailing padding grows to 44 to make room. The
  glyph is 20 pt at stroke 1.9 in label-2. It hides while there is text, because Send takes its place
  (`phone-ui-chat.css:22,395,420-424`). Voice is a later milestone; **M1** may omit the mic.
- **Primary:** a circle in a 44 pt box. In Release the phone's primary is `PhoneVoiceControls`' `.ios-voice-primary`
  (`PHONE_VOICE_UI` is released: `src/ui-voice/flags.ts:7-8`; gate `build/ui-voice-gates.ts:19`). Its circle is
  `inset: 4px`, so **36 pt** (`src/phone-ui-voice.css:18-19`), and it shrinks to 92 % while pressed
  (`phone-ui-voice.css:20`). **⚑ DISAGREES:** the 40 pt rule at `phone-ui-chat.css:429-430` styles the renderer's own
  `.rounded-full` primary, which the voice controls replace on the phone. **DECISION (native):** 40 pt, to match ☰, +
  and the field (the owner's 40 pt Telegram row, `memory/telegram-field-sizing.md`). Check it on the owner's phone.
  - **Send:** tint fill with a white up arrow, 17 pt at stroke 2.6, path `M12 20V5M5.5 11.5 12 5l6.5 6.5` in a 24-unit
    box (`src/ui-voice/voice-controls.tsx:85`). The web's is a solid fill. **Native (iOS look, owner 2026-10-31: the
    blue Talk circle "isn't in Liquid Glass"):** every primary circle is a 36 pt disc of Liquid Glass tinted in its
    colour (`ComposerGlassDisc`): Send and Talk in the tint at 70 % (the glass shows through; the white glyph keeps
    3.5:1 in light, 4.5:1 in dark; full under Increase Contrast), Stop and a dictation's Stop in label, disabled Send
    plain glass like the bar's other discs; the glyphs keep their colours. The Desktop Look keeps its solid ink circle.
  - **Stop:** a label-colour circle with a **10 pt square, corner radius 2.5**, in the page colour
    (`phone-ui-voice.css:23-24,29`; `voice-controls.tsx:86`).
  - **Talk:** a label-colour circle with waveform bars. Later milestone.
  - **Disabled Send:** a Fill 2 circle with a label-3 glyph (`phone-ui-voice.css:25-26`).
  - Which one shows, and the queue button beside it: §5.6.4.
- **Behind the row:** no bar. A scroll edge (the page colour at 86 %) fades upward from 40 % of its height, blurs 8,
  starts 18 pt above the row and runs under the home indicator (`phone-ui-chat.css:317,331-346`).
  - **Native:** the bottom scroll edge effect on the chat scroll view, plus glass controls. **DECISION**, as for the top.
- The web's solid bar returns when the dock holds more than the row: queued messages, a notice, the voice dock, or a
  memo being recorded (`phone-ui-chat.css:331-337`). **Native: no solid bar in any of those states.** Queued messages,
  notices, the Talk dock and the photo tray are glass cards over the scroll edge, and a recording memo keeps the page
  behind the bar unchanged (owner 2026-11-01: a solid page-colour band behind a recording covered the whole bottom,
  white over a chat background).
- **Native glass grouping:** put ☰, + and the field in one `UIGlassContainerEffect` with **spacing 6**. At 10 the
  closer circles melted into one shape (`ios/App/App/HermesUINav.swift:728-740`; `memory/telegram-field-sizing.md`).
- **Keyboard (the owner's top complaint):**
  - The row and the transcript must move in the same frame as the keys, both up and down. Build 237 had the row lag
    11 pt behind the keys and then jump (`memory/telegram-field-sizing.md`).
  - **Native:** pin the composer to `keyboardLayoutGuide`. The 29 pt ↔ 8 pt bottom gap and the 26 pt ↔ 8 pt side inset
    change inside the keyboard's own animation, never after it.
  - `keyboardDismissMode = .interactive`.
  - An anchored reply stays in place when the keyboard opens or closes (`memory/thread-top-anchor.md`).
- **Coast catch:** a tap on the composer within **120 ms** of a momentum-scroll event stops the coast and must not
  focus the field. The owner's keyboard kept popping up when they stopped a flick over the floating composer
  (`src/ui-chat/coast-catch.ts:12`; `memory/jump-arrow-under-dock.md`).
- At accessibility sizes (AX2 and up) the field takes a full-width row above the buttons
  (`phone-ui-chat.css:435-437`). Later.

**⚑ DISAGREES:** DESIGN.md §4.13 specifies a 52 pt row with 36 pt controls. The owner replaced that with Telegram's
40 pt row on 2026-10-09, and the code follows the owner.

**⚑ DISAGREES:** `~/Projects/hermes-hq-native/docs/ARCHITECTURE.md:47-48` puts the bar "8 pt above the keyboard and
at the safe area when down". With the keyboard down the glass bottom is **29 pt above the screen bottom** (5 pt inside
a 34 pt home-indicator inset), not at the safe area. This spec wins.

### 4.4 Jump to latest

- **Web today:** a 44 pt circle 16 pt from the trailing edge, its bottom 16 pt above the composer's top. It's opaque
  in the card colour with a shadow of `0 2 8 rgba(0,0,0,.12)`, and holds an 18 pt down arrow
  (`src/phone-chat.css:37-40`; `vendor/hermes/apps/desktop/src/app/chat/scroll-to-bottom-button.tsx:125`).
  - **No count and no dot.** The renderer's count is messages below the fold, not unread messages
    (`phone-chat.css:43-45`). **⚑ DISAGREES:** `~/Projects/hermes-hq-native/docs/ARCHITECTURE.md:46` says "a jump
    button shows a count". This spec wins (see Precedence at the top).
  - In: opacity 0 → 1 and scale 0.85 → 1 over 200 ms, `cubic-bezier(.22,1,.36,1)`. Out: the reverse over 180 ms
    ease-in (`phone-chat.css:181-189`; `vendor/.../styles.css:2503-2508`).
  - Hidden while a message is being edited or a hold menu is open (`phone-chat.css:47`, `phone-ui-chat.css:669`).
- **DECISION:** draw it natively as an interactive `UIGlassEffect` circle to match the composer's glass. The web
  version is opaque only because it predates the glass work (`memory/liquid-glass.md`: "the chat's scroll-to-bottom
  button is still opaque").
- **⚑ DISAGREES:** DESIGN.md §4.12 says a 36 pt glass circle 12 pt above the composer, with an accent dot. The code
  has no dot and is 44 pt.
- **Tap behaviour:**
  1. Stop any momentum first (one tap must work; `memory/jump-arrow-coast.md`, `src/phone-jump-coast.ts:8`).
  2. Glide to the end: if the end is more than **1.5 screens** away, cut to 1.5 screens above the end, then ease out
     (cubic) over **320 ms**, reading the live end every frame (`phone-jump-coast.ts:12-13`;
     `memory/jump-arrow-under-dock.md`).
  3. A finger touching the list cancels the glide. Reduce Motion jumps straight to the end.
- It must be tappable everywhere it sits. In the web app, chips stacked above the composer covered it in build 232
  (`memory/jump-arrow-under-dock.md`).

---

## 5. Chat open, follow and streaming behaviour

### 5.1 Opening a chat

- **Push:**
  - The web shell's native push uses a spring of **0.35 s** (0.5 s and 0.4 s "felt slow beside Telegram"), parallax
    0.3 and dim 0.1 (`ios/App/App/HermesUINav.swift:858-864`).
  - The edge swipe completes past 35 % of the width or above 300 pt/s. Its finish takes `0.16 + 0.19 × remaining
    share` seconds (`HermesUINav.swift:861-862,1221`).
  - A mid-screen swipe back exists too (`memory/smooth-chat-transitions.md`, build 87).
  - **Native:** use the standard `UINavigationController` push, and turn on the full-width
    `interactiveContentPopGestureRecognizer` (iOS 26) so a mid-screen swipe goes back.
- **First frame has text:** the chat is laid out at its final size before the push starts. In the web app the
  transcript laid out at the wrong height and re-placed itself in 2–4 steps over about 200 ms, and the owner saw "the
  text moved up as it slid in" (`memory/smooth-chat-transitions.md`, builds 87–89).
- **Opens at the end** (the newest message at the bottom), showing cached history.
- **No bounce:** growth that arrives after opening (fresh history, late layout) must not animate.
  - The web glides content only while a reply is live, plus a 1.5 s grace after it ends
    (`src/ui-chat/stream-glide.ts:9-11,104`; `memory/chat-open-bounce.md`).
  - Fresh history merges in place. When the reader is at the end, the end stays pinned with no visible move.
- **Haptic:** a soft impact (`impact.soft`) when a chat opens from a touch on a row. Nothing on launch restore, a
  notification open, or Back (`memory/taptic-feedback-gaps.md`, build 213).

### 5.2 Sending

- **Your message joins at the bottom.** Never push it to the top of the screen with blank space under it
  (ChatGPT-style). The owner reversed that after using Telegram (`memory/thread-top-anchor.md`, build 46).
- **Send lift:** the bubble rises from the composer. Its text starts aligned to the draft's text with no fade, and
  the bubble grows out from around the text, over **340 ms** (`src/ui-chat/chat-motion.ts:9`;
  `memory/smooth-chat-transitions.md`, build 90).
  - Start it on the first calm frame. In the web app a transition started in the send's commit was mostly over
    before it painted (`chat-motion.ts:17-18`).
- Send keeps the keyboard up (`memory/chat-refinement-shapes.md`). No haptic on Send
  (`memory/taptic-feedback-gaps.md`: "Deliberately left silent: Send"). **⚑ DISAGREES:** DESIGN.md §3.4 lists
  `impact.light` for Send; the later audit chose silence.

### 5.3 Following a reply ("a new reply is read from its top")

- The anchor is the reply: the first non-user message after your last sent one (`src/phone-thread-anchor.ts:4-11`;
  `memory/thread-top-anchor.md`).
- While the reply is shorter than the room on screen, the list follows the end.
- When following would push the reply's top under the bar, following **stops** with the reply's top **4 pt** below
  the bar (`ANCHOR_GAP_PX = 4`, `phone-thread-anchor.ts:9-11`). The rest arrives below the fold, and the jump arrow
  appears.
- After that the reader owns the position until they return to the end. If they scroll, nothing moves them.
- Opening or closing the keyboard leaves an anchored message where it is.
- **Native (inverted table):** "following" means keeping the content offset at the newest end. "Holding" means
  freezing the reply's top at bar + 4 pt as the reply grows (adjust the offset by the growth), then letting the user
  scroll.

### 5.4 Streaming growth

- When the list is at its end and a reply grows, the new lines **glide** up instead of jumping
  (`stream-glide.ts:1-34`):
  - growth ≤ 44 pt: **200 ms**, `cubic-bezier(.22,.8,.25,1)`;
  - 44–110 pt: **320 ms**, `cubic-bezier(.3,.1,.2,1)`;
  - 110–280 pt: **420 ms**, same curve;
  - over 280 pt: instant.
- A growth that lands mid-glide carries on from where the text is. No glide under Reduce Motion or during the send
  lift.
- **Whole replies** (some providers send the reply as one delta of 60 characters or more) are revealed a few words at
  a time: 1.6 characters per ms, at least 280 ms and at most 700 ms, for the first 1,200 characters, then the rest
  lands at once. Only at the end of the list (`src/ui-chat/reply-reveal.ts:1-29`). A touch, leaving the app, or
  another delta shows everything at once.
- **Native:** coalesce deltas to at most one layout per display frame. Animate only the content offset or transform,
  never row heights frame by frame (`memory/tool-calls-hide-when-done.md`: move 5–15 pt per frame).

### 5.5 Tool rows appearing and folding

- New rows enter with a short fade, and the glide above moves the rows below them (`trail-view.tsx:40-45,166`).
- "Hide When Done" (later) fades blocks out over 200 ms, removes them in one commit, and slides what's below over
  380 ms (`src/ui-chat/steps-fold.ts:13,15`).

### 5.6 Failure, stop and delivery states (visual)

The logic is in `04-send-stream-stop.md`. This section covers only what is drawn. `vendor/…` means
`vendor/hermes/apps/desktop/src/…`.

#### 5.6.1 The error card (a turn that failed, with or without a partial reply)

- **When:** the assistant message's status is `incomplete` and carries an error string. The headline's wording comes
  from `metadata.custom.errorSurface` (`{layer, code, retryable, …}`) (`vendor/…/thread/assistant-message.tsx:549-558`;
  `MessagePrimitive.Error` at `:313-335`). The phone card is `PHONE_ERROR_CARD`, **on in Release**
  (`src/ui-chat/flags.ts:37`).
- **Where:** inside the assistant message, after all its parts (text bubbles, trail rows), as its own block at the
  full column width. It is **not** a bubble (`assistant-message.tsx:305-335`).
  - **Partial reply:** the bubbles streamed so far stay as they are, and the last prose bubble keeps its tail and
    time (§2.2). The card sits under them.
  - **Tools but no text:** the card sits under the trail rows.
- **Card:** padding 12, **8 pt above and below**, no border, **radius 14**. Fill = grouped background
  (`--ios-bg-grouped`, which for Nous is the sidebar seed: **`#F6F8FA`** light, **`#010409`** dark). Text is
  Subheadline (15/20) in label colour, and all of it is selectable (`src/ui-chat/errors.css:2-3`;
  `src/phone-ios-tokens.css:18`; `vendor/hermes/apps/shared/src/theme-presets.ts:149,177`;
  `vendor/…/themes/context.tsx:222,261`). Neutral, not red. The desktop's red-tinted card is replaced.
- **Heading row** (`src/ui-chat/error-view.tsx:11-16`; `errors.css:4-8`):
  - an **18 pt glyph** in iOS red (`#FF3B30` light / `#FF453A` dark): a circle r 9 plus the path `M12 7v6m0 3v1`,
    stroke 1.8, in a 24-unit box;
  - an 8 pt gap;
  - the title in **Headline (17 semibold)**: "**<Bot name> couldn't finish this reply**" ("Hermes" when the name is
    empty) (`src/ui-chat/trail-model.ts:12`);
  - under it, 4 pt down, the **reason** in Subheadline label-2, keeping line breaks. The reason is the body from the
    error-code table (`vendor/…/lib/error-surface-copy.ts:25-…`; `vendor/…/i18n/en.ts:5097-5160`). A short raw error
    (≤ 160 characters, one line) with no table wording becomes the reason itself (`src/fe-convo-r4.ts:208-213`; gate
    `build/fe-convo-gates.ts`, r4-104). When the card offers no Retry, the retry sentences are reworded away
    (`withoutRetryWords`, `src/fe-convo-r6.ts:26-33`; gate `build/ui-chat-trail-gates.ts`, PhoneErrorHeadline).
  - A **dismiss ✕** (14 pt glyph) sits at the heading's trailing end, because the main chat passes `onDismissError`
    (`assistant-message.tsx:318-329`; `vendor/…/app/contrib/wiring.tsx:1178`). The phone's card-button rule makes it
    a 44 pt tint-coloured target (`errors.css:9`).
- **Actions** (`errors.css:9-14`; gates `build/ui-chat-trail-gates.ts`, `data-ios-error-primary` /
  `data-ios-recovery`):
  - A column at full width with 4 pt gaps. Each button is at least 44 pt, with no border and no fill, tint text in
    Subheadline, padded 10/12, with a 14 pt glyph (`src/phone-fe-convo.css:360`).
  - **The primary recovery comes first**, as a capsule filled with tint 16 % over the cell colour, text tint-text.
    It is the first of retry → sign in again → choose model → compress that the plan offers
    (`trail-model.ts:9-11`).
  - Labels: "Retry" (with a refresh glyph), "Sign in to <provider> again", "Choose a model", "Compress conversation",
    "Edit message", "Start new session", "Switch provider", "Update API key" (`en.ts:5245-5275`).
  - Retry is offered only on the turn the renderer allows (`ownTurnPlan`, `src/fe-convo-r3.ts:436-438`).
  - The **last button is "Details"**, which replaces the desktop's Send Diagnostics and Copy. It opens a medium sheet
    "Error Details" with Done, the raw error text in Footnote, and footer buttons "Copy" ("Copied" plus a success
    haptic, or "Try Copy Again") and "Send Diagnostics…" (`error-view.tsx:18-46`; `errors.css:15-16`).
- **M1:** the card, the reason, Retry as the primary, and Details (Copy only). The other recoveries are later
  milestones; omit their buttons. **DECISION.**

#### 5.6.2 "Hermes ended this turn without a reply."

- It isn't a separate look. It is the error card above with `errorSurface {code: "no_reply", layer: "runtime",
  retryable: true}` (`vendor/…/store/session-states.ts:550-551`).
  - A turn that ran tools but wrote no text gets the error on its own last assistant message, so the card sits under
    its trail rows.
  - Otherwise an empty assistant message is appended (`id "assistant-no-reply-<ms>"`, no parts) that shows only the
    card (`session-states.ts:573-597`).
- On the phone it reads: title "**<Bot> couldn't finish this reply**"; reason "**Hermes ended this turn without a
  reply. Retry to send it again.**" (`en.ts:5137-5140`); primary capsule "**Retry**"; then "Details".

#### 5.6.3 Stopped turns and the Stop-failed toast

- **Stopped after some reply:**
  - a caption "**Stopped**" under the message, at the text indent with 4 pt above;
  - 12 pt (`text-xs`) in muted-foreground, letter-spacing 0.01 em;
  - "**Interrupted**" when the turn stalled instead
  (gates `build/fe-convo-gates.ts:283,507`; `src/phone-fe-convo.css:282`).
- **Stopped before any reply:**
  - one row: "**Stopped before Hermes replied**" in secondary text, 13 pt at line-height 1.4, then a "**Retry**"
    capsule;
  - the capsule has a 14 pt refresh glyph and an 11.5 pt label in the accent, a 1 pt border of accent at 35 %, and no
    fill;
  - 12 pt horizontal and 4 pt vertical gaps (gate `build/fe-convo-gates.ts:712`; `phone-fe-convo.css:360,521-522`;
    `vendor/…/styles.css:2380-2392`).
  - **DECISION (native):** keep the look, but give the capsule a 44 pt hit area.
  - **Audit 863:** Retry follows the error card's rule (`ChatRowBuilder.retryPrompt(forStoppedAt:)`): only on the
    newest turn, never while a reply runs, and only when the prompt was words alone (its photos and files can't go
    again from here); otherwise the line shows without the capsule.
- **Stop failed** (`session.interrupt` rejected): an **error toast**, title "**Stop failed**"
  (`vendor/…/app/session/hooks/use-prompt-actions/index.ts:749-752`; `en.ts:5539`).
  - Content: a red alert-circle glyph (Tabler `IconAlertCircle`, 16 pt, destructive colour), the title, the readable
    error as its message, and a collapsed "Details" line for the raw text (`vendor/…/components/notifications.tsx:37,
    280-300,359-366`; `vendor/…/store/notifications.ts:309-340`).
  - It stays until dismissed: error toasts have no timeout (`store/notifications.ts:60-66`).
  - Placement in a chat: the screen width less **16 pt** on each side (at most 448 pt), dropped just under the chat
    header. It must end above the composer and the jump button, and scrolls inside itself if taller
    (`src/phone-chat.css:66-85`).
  - It is a solid elevated card, radius 14, not glass (§8.5; `phone-fe-convo.css:292`).
  - **DECISION (native):** a solid banner under the bar: red glyph, "Stop failed" in Headline, the reason in
    Subheadline label-2, a ✕, and swipe up to dismiss. The primary stays Stop while the turn is still busy.

#### 5.6.4 Under your bubble, and the composer while busy

- **Send caption** (`PHONE_SEND_STATE`, **on in Release**: `src/ui-chat/flags.ts:38`). One line directly under your
  bubble, **trailing-aligned**, Footnote (13/18) in **label-2**, 6 pt side padding, wrapping anywhere
  (`src/ui-chat/send.css:2-9`; placed after the bubble by gate `build/ui-chat-send-gates.ts`, `PhoneSendState`). Texts
  (`src/ui-chat/send-state.ts:24-29`):
  - nothing for the first **2 s** of a send, then "**Sending…**" (`SENDING_DELAY = 2000`, `send-state.ts:10`);
  - "**Queued**" while the message waits in the client queue;
  - "**Delivery Unconfirmed · Check**" after a send failed to confirm, in **red** (`--ios-red-text`: `#D70015` /
    `#FF453A`). The whole caption is then a button (at least 44×44, text end-aligned); while it checks it reads
    "**Checking Delivery…**" and is disabled (`send.css:10-19`; `src/ui-chat/send-view.tsx:10-28`);
  - nothing once the gateway accepted the message (`sent`).
  - In Release, queued messages live in the queue card above the composer (`PHONE_QUEUE_ROW` on, `flags.ts:39`;
    `send-view.tsx:48`), so "Queued" is rarely seen under a bubble.
- **Composer while a turn runs** (`src/ui-voice/voice-controls.tsx:184-199`; vendor rule
  `vendor/…/app/chat/composer/index.tsx:420-431`):

  | Field | Turn idle | Turn running |
  |---|---|---|
  | empty | mic in the field; primary = **Talk** (M1, without voice: a **disabled Send**, Fill 2 circle with a label-3 arrow, as a group room shows) | primary = **Stop** (label-colour circle, 10 pt page-colour square r 2.5); disabled only when the composer is disabled |
  | has text | primary = **Send** (tint) | primary = **Send** (tint), never greyed out, plus a **Queue** button just before it: a 44 pt borderless button with an 18 pt "layers" glyph (`m12 3 9 5-9 5-9-5 9-5Z` + `m3 13 9 5 9-5`, stroke 1.8) in **tint**, 40 % opacity when disabled |

  - Send while running **steers** the live turn when it can (text only, nothing blocking), and otherwise queues
    (`busyAction`, `index.tsx:426-431`). Queue always queues. Both keep the keyboard up (`voice-controls.tsx:175-182`).
  - The Queue glyph and its CSS: `voice-controls.tsx:88,191`; `src/phone-ui-voice.css:12-16`.
  - When the composer is disabled (reconnecting), every control is disabled and the placeholder changes
    (`src/ui-chat/composer.tsx:17-20`).
  - **M1:** Send, Stop and the disabled Send. Queue and steer follow 04's M1 scope.

---

## 6. Bot list (Bots tab)

### 6.1 Rows (Messages metrics, 12–14 pt padding)

Rows sit on the page colour (`src/phone-tabs.css:151`).

| Part | Value | Source |
|---|---|---|
| Leading inset | 20 pt (or the safe area if larger) | `phone-ui-bots.css:11-12` |
| Head | **56 pt**, app-icon squircle (corner 22.37 % of the size, continuous) | `src/ui-bots/bot-row.tsx:236`; `src/ui-kit/bot-avatar.css:2,7` |
| Head → text gap | 14 pt | `phone-ui-bots.css:11` |
| Vertical padding | **14 pt top and bottom**, minimum row height 88 pt (text column at least 52 pt) | `phone-ui-bots.css:11-15` |
| Line 1 | name in Body **semibold** (17/22), one line with an ellipsis; trailing time in Caption 1 (12) label-2, tabular digits; 8 pt column gap | `phone-ui-bots.css:21-27` |
| Line 2 | preview in Subheadline (15/20) label-2, **2 lines**; 4 pt row gap | `phone-ui-bots.css:21,28-29` |
| Status glyphs (mute, hidden, pin) | 13 pt (scales up to 26), label-2 | `phone-ui-bots.css:8,26,31` |
| Trailing actions button | a 44 pt round button (owner decision 4: keep it), 4 pt from the edge (or the safe area), vertically centred, label-2, Fill 3 circle while pressed. **The glyph is the horizontal ellipsis "⋯"**, not "⋮": lucide `Ellipsis` drawn at **22 pt with stroke 2.4** (three r 1 circles at x 5, 12 and 19 on y 12 in a 24-unit box, stroked, so each dot is about 4 pt across). The source comments call it "⋮", but the drawn glyph is horizontal. Native: SF Symbol `ellipsis` (not `ellipsis.vertical`) at a matching weight. VoiceOver: "Actions for <name>" | `src/ui-bots/bot-row.tsx:96-102`; `phone-ui-bots.css:39-42`; lucide-react 1.48.0 `icons/ellipsis.mjs`; OWNER-DECISIONS.md #4 |
| Separator | a hairline from x = inset + 70 (90 pt) to 20 pt from the right edge | `phone-ui-bots.css:9` |
| Press | cell-pressed colour | `phone-ui-bots.css:17` |

- **Unread** (`memory/unread-circle-position.md`; `phone-ui-bots.css:18-35`):
  - A **16 pt** tint circle at the trailing end of line 2 (beside the pin), centred on the first preview line.
  - Muted bots get grey `#8E8E93`.
  - The name switches to Headline (still 17 semibold), and the time turns tint-text.
- **No number** anywhere. Hermes's `message_count` counts tool calls and results, so a count would overstate one
  reply many times (`memory/unread-badges.md`).
- **Head badges** at the bottom-right, 2 pt outside the head (`src/ui-kit/bot-avatar.css:10-17`,
  `src/ui-kit/bot-avatar.tsx:21`):
  - size `clamp(14, 0.36 × head, 22)`, so 20 pt for a 56 pt head, with a 2 pt ring in the page colour;
  - needs-you: orange;
  - working: tint with three white dots;
  - computer: tint.
- **Status line:** the preview, or "Working…" (tint), "Waiting for your approval: <summary>" (orange), "Waiting for your
  reply" (orange), "Using its computer", or "No messages yet" (`bot-status.ts:42-51`).
- **Times** (`src/list-time.ts:29-40`): "9:05 AM" today, "Yesterday", a weekday within the week ("Mon"), else
  "Aug 7" ("Aug 7, 2025" in another year).
- At accessibility sizes the time moves under the preview, the name wraps, and the preview gets 3 lines
  (`phone-ui-bots.css:43-50`).
- Skeleton rows (cold load): a 56 pt Fill 3 squircle and two lines at 40 % and 78 % width (`phone-ui-bots.css:111-120`).

### 6.2 Pinned tiles vs rows

- Pinned bots show as a **grid of tiles above the list**, at most **6** (`src/ui-bots/pinned-model.ts:4`). **They
  don't repeat in the list below** (D2, OWNER-DECISIONS.md).
- Grid: 3 columns, gaps of 12 pt vertical and 4 pt horizontal, padding 4 pt top and 8 pt bottom
  (`phone-ui-bots.css:145,193`).
  - With 1 or 2 pins the tiles are centred, each a third of the width (`phone-ui-bots.css:194-195`).
- Tile: a **72 pt head**, an 8 pt gap, then the name in Footnote (13) medium, centred, up to 2 lines. Padding 4,
  radius 14 for the lifted menu card. No time, preview or ⋮ (`bot-row.tsx:236`; `phone-ui-bots.css:146-152,192`).
- **Unread on a tile:** a **10 pt** circle beside the name, top-aligned 4 pt down (`phone-ui-bots.css:35`).
- A press dims the head to 72 % over 0.18 s (not a row rectangle). Holding opens the menu, and holding then moving
  rearranges the pins (`phone-ui-bots.css:154-161,203-211`).
- A "Pinned" section: pins sync to desktop Hermes through a section called "Pinned" (id `hermes-hq-pinned`, bot meta
  `pinnedFrom`). The phone hides that section unless pins overflow the 6 tiles (`memory/pinned-section.md`). For M1,
  just don't show it as a section.
- At accessibility sizes the grid becomes ordinary rows (`phone-ui-bots.css:153`).

### 6.3 Section headers and search

- Section header: at least 44 pt tall, 8 pt top margin, the 20 pt inset. Subheadline 15 **semibold** label-2, a
  regular-weight count, and a chevron (1 em, label-3) that turns −90° when collapsed (0.2 s). A named section has a
  44 pt ⋯ button (`phone-ui-bots.css:164-187`).
- Search field: 36 pt tall, radius 10, the search fill colour, the same position on every tab (x 20, y 114, 362 wide on
  the owner's phone) (`phone-tabs.css:126,129`; `memory/chat-status-line.md`).
- The Bots bar has one trailing glass capsule with Filter, Search and + (New Bot, Group Chat or Section; a + since
  2026-11, so the pencil only means a new chat: 1x-settings §5.6), 44 pt each (`phone-ui-bots.css:94-100`).

### 6.4 Sessions list (basic, M1)

- Row: at least 72 pt tall, a 40 pt face, 12 pt gap. Title in Body regular (semibold when unread). Time in
  Subheadline label-2 (tint-text when unread). Preview in Subheadline label-2, 2 lines.
  The hairline starts at the text (x = 16 + 56) (`src/phone-ui-lists.css:4-43`).
- Trailing actions button: a 44 pt wide column the row's full height (the press shows a 44 pt Fill 3 circle), with
  label-2 glyph. **The glyph is the horizontal "⋯"**: three *filled* circles r 1.9 at x 5, 12, 19 (y 12) in a 24-unit
  box, drawn at 22 pt (`src/ui-lists/session-row.tsx:94-107`; `phone-ui-lists.css:46-52`). The comments call it "⋮".
  Native: SF Symbol `ellipsis`.
- Unread is the face's **corner badge**: a tint circle `10 + 0.17 × 40 ≈ 17 pt` at the top-right, 3 pt outside, with a
  2 pt ring (`bot-avatar.tsx:34-35`; `bot-avatar.css:12-13`; `memory/unread-circle-position.md`: Sessions rows kept the
  badge).
- **⚑ DISAGREES (row padding):** the web's Sessions row gets about 10 pt of vertical padding (72 pt minimum height −
  51.6 pt content; `phone-ui-lists.css:18`), which is below the owner's 12–14 pt rule for rows that wrap. **DECISION:**
  use 12 pt top and bottom natively.

---

## 7. Heads (bot avatars)

### 7.1 Defaults (owner, 2026-10-08, builds 226 and 230)

- Every bot without a saved head, **including the primary "default" profile**, gets a **plain Shapes head**
  (`src/ui-heads/head.ts:246-258`; `memory/default-shape-heads.md`):
  - `key = profile.trim().toLowerCase() || 'default'`
  - `hash = FNV-1a 32-bit over the key's code points` (`head.ts:185-189`): start at 2166136261; for each code point,
    `hash ^= cp`, then `hash = imul(hash, 16777619)`; return `hash >>> 0`. Use `hash || 1`.
  - Colour = `C[hash % 21]`, with C = SHAPE_COLORS minus ink, slate and paper, in this order: red, coral, peach,
    butter, lime, grass, mint, teal, sky, cobalt, lilac, grape, rose, pink, magenta, plum, denim, forest, wine, cocoa,
    caramel (`head.ts:30-31,250`).
  - Form = the **first draw** of `seededRandom(hash)` (mulberry32, `head.ts:190-197`), indexed into
    `[round, blob, square, pill, hex, cloud]` as `floor(r × 6)` (`head.ts:204,256`).
  - `seed = hash % (2^31 − 1) || 1`. The seed shapes the blob's wobble.
  - `look: slits`, `tile: none` (no board), no specs, **no hat**, no mouth, no blush.
- **Shape fill colour** = the tone's accent (`src/ui-heads/shapes.ts:117`; `src/ui-heads/robot.ts:12-37`):

  | colour | accent | colour | accent | colour | accent |
  |---|---|---|---|---|---|
  | red | `#EF3B36` | coral | `#FF7057` | peach | `#FFA043` |
  | butter | `#FFCE2E` | lime | `#96DB3C` | grass | `#2DBE60` |
  | mint | `#1FCFA5` | teal | `#22BCD8` | sky | `#4A93FF` |
  | cobalt | `#2E5BFF` | lilac | `#9479FF` | grape | `#7C3AED` |
  | rose | `#FFAFC8` | pink | `#FF66AD` | magenta | `#E0218A` |
  | plum | `#8A3F96` | denim | `#3A5BA8` | forest | `#23784E` |
  | wine | `#B03055` | cocoa | `#8A5638` | caramel | `#C98A55` |
  | ink | `#0A0A0A` on a light page, `#F4F4F2` on a dark page (grey rim `#636366`, 14 units, when the mode is unknown) | slate | `#6B7688` | paper | `#EFE9DB` (rim `#B8AD95`) |

- **Eyes** (`shapes.ts:132-145`):
  - Colour: **`#FFFFFF` on a light page and `#1A1A1A` on a dark page.** A paper shape, or ink drawn white, always gets
    `#1A1A1A`. A head drawn for an unknown mode (notifications, desktop copy) keeps white eyes
    (`memory/default-shape-heads.md`, build 230). The head must redraw when the appearance changes.
  - Slit geometry, in a 1024 space with UNIT = 300 (`shapes.ts:13`):
    - s = 300 × face size;
    - each slit is a rounded rect of width `0.15 s × bold` and height `0.38 s × narrow`, radius = width / 2;
    - the slits sit at `cx ± 0.2 s`;
    - rotation = the pose's lean: idle `[−20°, −20°]`, so they lean up and to the right;
    - the eye centre = `512 + (face.x + pose.x × size) × 300`, with idle pose at `(0.3, −0.28)`;
    - `bold` = 1.2 for small (list) pictures and 1 otherwise; `narrow` = 0.86 while thinking or speaking.
  - Face positions per form, as `[x, y, eye scale]` (`shapes.ts:26-37`): round, blob and square `[0, −.04, 1]`
    (`:27-29`); **hex `[0, −.02, 1]`** (`:36`); pill `[0, −.02, .92]` (`:33`); cloud `[−.02, .1, .92]` (`:37`).
    (02 §10.4 agrees.) Poses (`shapes.ts:44-50`): thinking and speaking `(0, .02)` lean 0; done `(0, −.08)` lean
    `[24, −24]`; offline `(0, .1)` lean 90 (flat dashes).
- **Outlines:**
  - round: a circle; square: superellipse `(.93, .93, .3)`; hex: rounded at .2; pill, blob (wobble 0.08 from the seed)
    and cloud are built with `parts.ts` helpers (`shapes.ts:26-37`).
  - The bare head is scaled to fill **984/1024** of the frame (`shapes.ts:93-110`).
  - **Native:** port `shapes.ts` and the pure geometry helpers from `src/ui-heads/parts.ts` (`around`, `wobble`,
    `superellipse`, `rounded`, `cloud`, `spline`) to `CGPath`, and cache one image per (head, size, mode).
- **Frame:** a transparent squircle (22.37 %). A bare Shapes head has no plate behind it (`bot-avatar.css:1-3`).
- **⚑ DISAGREES:** the native repo's `docs/ARCHITECTURE.md:27` says "HeadView (draws the default robot heads)", and
  `PLAN.md:14` says "bot list with robot heads". The default became Shapes on 2026-10-08. The robot is still the
  standard *for the Robot theme* (§12), but it isn't the default face. This spec wins (see Precedence at the top).
  **UNKNOWN:** whether the owner's own bots carry *saved* Robot heads. If they do, M1 shows their 288 px mirror PNGs
  (§7.2), so they will still look like robots on the owner's phone. That's correct, and it isn't a default.

### 7.2 Saved heads

- A saved head is stored per profile in `ui_meta['dispatch-head']` with a revision (`src/ui-heads/sync.ts:1-6,27-30`).
  The fields are in `head.ts:65-93`. The protocol is in the profiles spec.
- **M1:** draw Shapes heads natively. **DECISION** for other themes (robot, dots, orb, pixel, emoji, monogram):
  use the profile's avatar picture when it is the app's 288×288 mirror PNG (`src/ui-heads/mirror.ts:1-26`), else fall
  back to the default Shapes head. Port the robot renderer in a later milestone.
- Photo avatars draw in the same squircle.

### 7.3 Motion

- **At rest, Shapes heads blink and glance** (`src/ui-heads/motion.ts`; `src/ui-heads/bot-head.css`):
  - Blink: scaleY 1 → 0.08 (at 42 %) → 1 over **0.19 s** ease-in-out. The first comes 1.2–6 s after appearing, then
    every 4.2–9.4 s, with a 15 % chance of a second blink 280 ms later (`bot-head.css:17-19`; `motion.ts:107-113,142`).
  - Glance: the eyes move by fractions of the head's width to one of `[0,0], [−.146,.025], [−.078,.078], [−.02,−.012],
    [−.11,−.02]` over **0.42 s** with `cubic-bezier(.35,0,.25,1)`, every 3.4–8 s. 25 % of the time they go back to rest
    (`motion.ts:21,89-97,115-117`; `bot-head.css:13-15`).
- **Working** (thinking or speaking): the head "breathes", scale (1.05, 0.95) at mid-cycle over 1.7 s with its origin at
  50 % / 94 %, and its narrowed eyes sweep side to side over 2.4 s (`bot-head.css:42-50,68-73`).
- **Still** under Reduce Motion, Low Power Mode or thermal pressure, while off screen, or when covered
  (`motion.ts:36-37`; `bot-head.css:52-57`).
- Animate only transforms on layers. Never redraw the picture: the web measured about 6 CPU-seconds per minute for
  7 heads when it redrew (`memory/heads-motion.md`).

---

## 8. Glass rules (native only)

0. **Glass when possible** (owner, 2026-10-30: "make sure we use Liquid Glass when possible in the main theming"). In
   the iOS look, anything that floats over content is Liquid Glass by default: bars, floating buttons, capsules, menus,
   and every half-height sheet (`hqGlassPage()`, App/Kit/SheetStyle.swift; full height turns solid on its own, unless
   the sheet asks for `hqGlassPage(everyHeight: true)`: New Job, owner 2026-10-31, "the entire pop-up should be liquid
   glass". iOS 26.1 draws nothing for a glass effect set on a full-height detent, so the detent's effect is a clear
   colour and the sheet's own `UIGlassEffect` view sits behind its content, with the container's concentric corners).
   Something floating that stays solid needs a written reason on the line that makes it solid (`solid-ok: …`), and
   ThemeTests enforces the marker for sheets (`sheetsAreGlassUnlessALineSaysWhyNot`). The Desktop Look has no glass at
   all; it flattens everything (`ThemeChrome`, `hqGlass*` helpers in App/Theme/DesktopLayout.swift), and the Mac and
   regular-width form sheets stay opaque.
1. **Only system glass:**
   - UIKit: `UIGlassEffect(style: .regular)` inside a `UIVisualEffectView`; group neighbours in
     `UIGlassContainerEffect` with **spacing 6** (`ios/App/App/HermesUINav.swift:728-740,808-810`).
   - SwiftUI: `.glassEffect(.regular.interactive())` inside a `GlassEffectContainer`.
   - Plus system bars, `UITabBar`, sheets and `UIMenu`.
   - **Never** a hand-made blur plus tint. The owner rejected public build 74: "It isn't Liquid Glass. So much of this
     is wrong." (`memory/liquid-glass.md`).
2. **Untinted** for chrome (Back, title, ⋯, ☰, +, field, jump, peek). Never tint glass heavily to make it readable.
   The 72 % tint on the reply peek "read as a flat white pill", and the owner asked "shouldn't that be liquid glass?"
   (`memory/reply-peek.md`). Tint glass only for a prominent verb (a sheet's Save), using the accent
   (`memory/liquid-glass.md`, build 79).
3. **Interactive** (`isInteractive = true`) on anything touchable, so it lights up and gives under the finger. The
   system's press response replaces the web's 1.12 scale swell (`phone-ui-nav.css:84`; `HermesUINav.swift:808-810`).
4. **Which pieces are glass:**
   - chat: Back (and the "‹ N" capsule), the title rounded rect (r 14), ⋯, the status capsule (**DECISION**, §4.1), ☰,
     +, the field, and the jump button (**DECISION**, §4.4);
   - lists: the Bots bar capsule;
   - the tab bar (system `UITabBar`, floating glass);
   - sheets at half height (system sheets are glass on iOS 26; the page under them is clear, `HQPalette.sheetPage`),
     with a sheet bar ✕ as a glass circle and a verb as a tinted glass capsule;
   - HUD, Undo and "Reconnecting…" capsules;
   - the reply-peek banner (`memory/liquid-glass.md`, `memory/liquid-glass-more.md`).
5. **What sits on the glass is designed for it** (owner, 2026-10-30: "design all of the stuff that is on top of the
   Liquid Glass better"). The glass is the frame; the content is solid:
   - lines people read or pick from sit on solid cards (`HQPalette.sheetCard`, `hqSolidOnGlass()` for table cells,
     `.hqSheetRows()` in SwiftUI), never on bare glass: bubbles behind the glass tinted the values in verification
     round 3;
   - text that must sit on the glass itself (titles, section headers, empty states) uses strong ink (never the
     tertiary label) and passes 4.5:1 over a busy chat (3:1 for bold text of 17 pt and up);
   - no glass on glass: buttons, search fields and toggles inside a glass sheet are solid, matching the cards;
   - except picks (owner, 2026-10-31, New Job: "as much that is inside of it as possible should be liquid glass too,
     with all of it themed so that it looks right on top of liquid glass"): a strip of choices standing on the sheet's
     glass (bot tiles, template cards, frequency chips, a header's See All) is interactive glass itself
     (`hqPickGlass`, the chosen one tinted 16 % and ringed in the tint, a chip filled with the tint, a third darker in
     the dark), grouped in one `GlassEffectContainer` with spacing 0 (`hqPickGlassRow`: glass can't sample glass, so
     a lone pick smeared its tinted neighbour along its edge). Words on a pick are full ink. The strip runs edge to
     edge (`listSectionMargins(.horizontal, 0)`, the content margins at the gutter) so picks scroll out at the
     sheet's edges instead of being cut off inside a card. Fields and rows people read stay on solid cards, and a
     placeholder there is `HQPalette.cardNote` (the system's measured 1.7:1);
   - panels over the chat with lists to pick from (the `/`-command list, the @ list, toasts, notice cards) stay solid
     elevated surfaces; the web made them opaque because see-through text was unreadable (`phone-ui-chat.css:645-661`;
     `memory/chat-visibility-alignment.md`).
   - Checked with `scripts/glass-contrast.swift` (Vision finds each line, prints its contrast; `--below 0.45` for a
     half-height sheet) on tour shots (`scripts/desktoplook2-tour.sh`) in light and dark, both looks.
6. **Send is a solid accent circle**, not glass (`phone-ui-chat.css:433-434`).
7. **Sweep siblings.** When one surface gets glass, every sibling of the same family gets the same treatment in the
   same build. The owner inspects every sheet bar and button family (`memory/liquid-glass.md`, "Pattern from this
   owner").
8. **Sheets:** one corner radius for every sheet, and the sheet bar's controls 16 pt in and 9 pt down. The owner
   noticed different radii and insets between sheets (`memory/liquid-glass.md`, build 83). Prefer system sheets
   (`UISheetPresentationController`) and their defaults.
9. **Accessibility:** let the system handle Reduce Transparency and Increase Contrast. Don't add custom opaque
   fallbacks except where the web drew a solid bar (the top and bottom scroll edges turn solid under Reduce
   Transparency; `phone-ui-chat.css:283-285,330`).
10. **In-app reply banner** (later milestone, recorded here for the glass pattern):
    - a capsule of untinted interactive `UIGlassEffect`, 64 pt tall, at y = safe-area top + 2 (Apple's banner spot),
      12 pt side insets, at most 440 pt wide;
    - a 40 pt face, the name in 15 semibold over one line of the reply in 14 regular secondary, and a "+N" count in 13
      semibold;
    - shown for 4.5 s; swipe up to dismiss; a resting finger holds it
      (`ios/App/App/HermesUIChat.swift:44-60,88-100,142-200`; `memory/reply-peek.md`).
11. **Chat bubbles** (owner, 2026-11-01, an exception to rules 2 and 5): with Theme › Chat Bubbles › Glass on (the
    standard), text bubbles (yours, replies, the tool-step bubble) are `UIGlassEffect(.regular)` tinted with the skin's
    own bubble colour (`GlassBubbles`, App/Chat/Cells/ChatCells.swift): replies at 55 %, yours at 85 %, both at 90 %
    under Increase Contrast, which keeps its 1 pt edge over the glass. The tint is what makes it work on every skin: a
    plain page still shows that skin's bubble, and a Chat Background shows through it. Untinted glass was tried first
    (2026-11-01): clear glass failed 4.5:1 over a busy picture and plain glass drew every skin's replies the same white.
    Cards of rows under a reply (changed files, an opened run) stay solid (rule 5), as do code cards inside a bubble.
    Reduce Transparency draws the solid bubbles, tail included: the glass is a choice of look for content, not chrome.
    The send's flying stand-in is solid (its reveal mask would cut glass flat) and lands as glass. The Desktop Look keeps
    its boxes. **Not on the Mac** (`GlassBubbles.offered`): Catalyst drew the glass without its tint, so your messages
    came out the replies' grey; the Mac keeps solid bubbles and has no switch until it is checked on a real Mac screen.
    The lines between bubbles on a chat background (days, notices, tool and group lines, the thinking row) are
    frosted, not glass, so the chat is not all glass (owner, 2026-11-01; see the chat background bullet).
    **Tinted** (Style › Tinted, §2.2) is the other choice. Every bubble shares one soft copy of the Chat Background,
    and each bubble shows the part of it that is behind that bubble, so the colour changes as the chat scrolls. The
    copy is not laid see-through under the bubble colour. The first build (624) did that, with the colour 40 % for
    replies, and a dark night photo under a Light chat turned replies into a lavender-grey slab (owner, 2026-11-02:
    "I'm not sure this is right"). Each pixel is now repainted in OKLab instead: the lightness of the solid bubble,
    give or take 60 % of the picture's own light and dark (30 % on the lighter side of a light bubble, where there is
    no room for colour), plus the picture's colour (1.3 times it for replies, half that for yours, 40 % and no light
    and dark under Increase Contrast, which also keeps the 1 pt edge). So a Light reply stays light and a Dark reply
    stays dark on any picture, while a sky, a horizon or a hill passes through it as a soft shape. 644 took 15 % of
    the light and dark and blurred by an eighth: the owner, 2026-11-02, "Telegram chat bubbles change as you scroll.
    It's like they have a heavy blur of something so that they adapt to the background. Yours are not doing that."
    (over a night photo a reply's lightness moved 0.016 from top to bottom in Light, 0.020 in Dark; now 0.06 and
    0.11). Each pixel must still give 4.5:1 for words (7:1 under Increase Contrast) and 3:1 for the time, or the solid
    bubble's own contrast where that is lower, and keep at least 75 % of the solid bubble's contrast. Where it does
    not, that pixel takes as much of the picture as still reads (found by halving, so neighbouring pixels match: steps
    of a quarter drew a hill's outline as a dark blotch), down to the solid colour. Each kind of bubble has its own painted copy (cached, 16 at most). The test
    checks every picture × Light/Dark × skin. The send's stand-in lands solid, then takes the tint. Scrolling 200
    messages dropped no frames in the simulator for Solid, Glass or Tinted (624; the repaint is done once per
    picture and bubble kind, not per frame).
- **Rejected glass behaviours:** the tab bar shrinking on scroll, and a tab-bar accessory bubble
  (`memory/liquid-glass-more.md`).

---

## 9. Motion and haptics summary

| What | Value | Source |
|---|---|---|
| Push / pop | 0.35 s spring, parallax 0.3, dim 0.1 | `HermesUINav.swift:858-864` |
| Swipe-back finish | 0.16 + 0.19 × remaining share (s), starting at the finger's speed | `HermesUINav.swift:1215-1222` |
| Send lift | 340 ms | `src/ui-chat/chat-motion.ts:9` |
| Stream glide | 200 / 320 / 420 ms by growth size; instant over 280 pt | `src/ui-chat/stream-glide.ts:20-34` |
| Live grace after a turn | 1.5 s | `stream-glide.ts:104` |
| Whole-reply reveal | 280–700 ms at 1.6 characters/ms, first 1,200 characters | `src/ui-chat/reply-reveal.ts:19-29` |
| Jump glide | 320 ms ease-out cubic, cut to 1.5 screens | `src/phone-jump-coast.ts:12-13` |
| Jump button in / out | 200 ms `(.22,1,.36,1)` / 180 ms ease-in | `src/phone-chat.css:183-189` |
| Steps fold | fade 200 ms, slide 380 ms | `src/ui-chat/steps-fold.ts:13,15` |
| Head blink / glance | 0.19 s / 0.42 s | `src/ui-heads/bot-head.css:13-19` |
| System spring curve | `cubic-bezier(.32,.72,0,1)`; push 350 ms, sheet 500 ms, fade 200 ms | `src/phone-ios-tokens.css:79` |

Haptics (`~/Projects/dispatch-handoff/design/DESIGN.md` §3.4, as revised by `memory/taptic-feedback-gaps.md`):

- **Silent:** tab switches, push and pop, opening, closing or cancelling sheets, menus and alerts, typing, scrolling,
  per-turn events, and **Send**.
- `selection`: picks, toggles and segments.
- `impact.soft`: opening a chat from a touch.
- `impact.rigid`: Stop.
- `notification.success`: Copy, saves, and a successful sign-in.
- `notification.error`: a failed send or failed sign-in.
- A long press plays a haptic when its menu appears (`src/ui-kit/flags.ts:34-37`).

---

## 10. Accessibility notes

- **Text that scales without a cap:** message text, previews and names.
- **Text that is capped:**
  - bar title 22;
  - subtitle and status 18;
  - bubble time 20;
  - day separator and transcript captions 22;
  - composer text while typing at accessibility sizes: 16–28, with the field capped at 3 lines
    (`phone-ui-chat.css:14-17,28`; `src/phone-chat.css:120`).
- At AX2 and larger, the chat title drops the face and the status becomes a full-width strip under the bar
  (`phone-ui-chat.css:214-223`).
- VoiceOver reads "<Bot> said:" once per reply and "You said:" for yours (`src/ui-chat/bubble.tsx:84-87`;
  `phone-ui-chat.css:100-101`).
- Bot rows read the name, status, time, and "unread", "pinned" or "muted" (`bot-row.tsx:234`).
- Every touch target is at least 44 pt (all of the above).

---

## 11. Out of scope for M1 (the native app must not invent replacements)

- **Desktop Look** and its High Contrast, Reply Time and UI Scale options (`memory/desktop-look.md`,
  `memory/high-contrast-option.md`, `memory/ui-scale-setting.md`).
- **Tool Call Style** Bubbles and In Header, and **After Reply: Hide** (§3).
- Group rooms, the queue, voice, approvals, the question dock, subagent and goal chips, the commands sheet's contents,
  the model menu, the reply peek, and Bot Screen.
- Keep their slots in the layout (for example, the dock can grow above the row) so they can be added without
  redesigning.

---

## 12. What the owner explicitly rejected (never reintroduce)

| Rejected | When | Source |
|---|---|---|
| **Telegram chat colours**: white bot bubble, `#e2fdc9` green "you" bubble, night blue, gradient **wallpaper**, date pill, **✓/✓✓ read checks**. "abandon the telegram chat themes… i don't like them." Keep Telegram's *shapes and sizes* only (and, since 2026-11-01, its way of showing the person's own Chat Background through a bubble: Tinted, §2.2). | 2026-10-06 | `memory/telegram-look-hold.md`, `memory/chat-telegram-look.md`, `memory/tool-calls-hide-when-done.md` |
| **Unboxed bot replies** (ChatGPT / Claude style). "I'm used to using Telegram and I love how the chat bubbles look there." | 2026-09-30 | `memory/chat-bubbles-telegram.md` |
| **Sent message rising to the top** with blank space under it (ChatGPT-style). | 2026-10-01 | `memory/thread-top-anchor.md` |
| **Top-bar layout redesigns**: a Telegram-style centred title with the avatar on the right and a two-line title capsule, a leading identity, a split model chip, the model in the bar. The layout stays Back · head + name · ⋯, with the model in the ⋯ menu. | 2026-10-02 | `memory/chat-status-line.md`, `memory/telegram-field-sizing.md` |
| **A head inside a capsule** in the title (it must be a rounded rect, r 14). | 2026-10-02 | `memory/chat-status-line.md` (build 69) |
| **Three tool-call alternatives**: a summary row, steps inside the reply, step pills ("the look feels wrong"). | 2026-10-06 | `memory/tool-calls-hide-when-done.md` |
| **CSS-imitation glass**, and **heavily tinted native glass**. | 2026-10-02, 2026-10-08 | `memory/liquid-glass.md`, `memory/reply-peek.md` |
| **Tab-bar bottom accessory** ("Inbox · Working…"), and the **tab bar shrinking on scroll**. | 2026-10-07 | `memory/liquid-glass-more.md` |
| **6 pt unread dots** ("awful"); **unread counts/numbers**. | 2026-10-03 | `memory/unread-badges.md` |
| **Redrawn heads** (folded Shapes blobs, new orbs, pixel, "Character" people). "The original robots are 100x better." Remove the Character theme. Keep the original robot as the standard. | 2026-10-06 | `memory/bot-head-redraw-proposal.md` |
| **Hats on Shapes heads** ("hats looked off"; removal built but unshipped, so ref238 still has hats: don't draw them). | 2026-10-08 | `memory/new-bot-style-no-hats.md` |
| **Ray/spark marks, AI-generated anime, the Nous girl**, anything imitating Nous's seal or girl. The icon is the hand-drawn pearl feather. | 2026-10-04 | `memory/hermes-dispatch-branding.md` |
| **Sessions tidy bundle**: scrolling chips, no row ⋮, plain date headers. | 2026-10-08 | `memory/sessions-tidy.md` |
| "Grok Bot" means **xAI's agent-app avatars** (flat shapes, slit eyes), not the @grok logo, and not a black mono-mark "Void" theme. | 2026-10-03 | `memory/grok-shapes-theme.md` |

Also from the owner's habits:

- They judge by feel on the phone and inspect every sibling surface right after each build
  (`memory/liquid-glass.md`).
- Show a few quick renders for taste questions instead of large design workflows
  (`memory/bot-head-redraw-proposal.md`).
- Explain changes in plain "before → now" words (`memory/sessions-tidy.md`).

---

## 13. UNKNOWNs and DECISIONs (collected)

1. **UNKNOWN:** the owner's chosen skin (Nous is the Release default; iOS System is behind a flag that's off). M1
   uses Nous (§1.1).
2. **UNKNOWN:** the Telegram figures (y = 64, 26 pt sides, 29 pt bottom, 8/8 with the keyboard up) come from measuring
   the owner's screenshot (`memory/telegram-field-sizing.md`). The web CSS reproduces them for a 402 pt phone with a
   34 pt inset. On phones with a different inset, keep the rule "glass bottom = screen bottom − 29 pt", not the CSS
   formula. Verify on the owner's iPhone19_2.
3. **DECISION:** use the system scroll edge effect instead of the hand-made gradient-and-blur edges, top and bottom
   (§4.1, §4.3).
4. **DECISION:** the jump button becomes glass (web: opaque card) (§4.4).
5. **DECISION:** the status capsule becomes glass (web: material) (§4.1).
6. **DECISION:** the Sessions row gets 12 pt of vertical padding (web: about 10 pt) (§6.4).
7. **DECISION:** non-Shapes saved heads use the 288 px mirror PNG or fall back to the default Shapes head in M1 (§7.2).
8. **DECISION:** for the action row, Copy alone is enough in M1 (§2.5).
9. **⚑** DESIGN.md (2026-09-28) is superseded in several places (bubble padding, grey bubble, unboxed replies, 36 pt
   composer, jump dot, every-bubble time, bold day label, Send haptic). This spec follows the code and the newer
   owner notes.
10. **⚑ Native repo docs vs this spec.** **This spec wins.** `ARCHITECTURE.md:5-6` itself defers to `docs/spec/`
    and to the web app's behaviour, and every point below is web behaviour. The four contradictions, with replacement
    wording, are in the table under "This spec vs the native repo's own docs" at the top:
    - `ARCHITECTURE.md:27` "default robot heads";
    - `ARCHITECTURE.md:46` "a jump button shows a count";
    - `ARCHITECTURE.md:47-48` "at the safe area when down";
    - `PLAN.md:14` "robot heads, unread dot".
    (An earlier draft of this item said `ARCHITECTURE.md` says "unread dot"; it doesn't. That's `PLAN.md:14`.)
    **UNKNOWN:** who updates those two files, and when. This spec may only edit `docs/spec/`. Until they're fixed,
    engineers follow this file on all four points.
11. **DECISION:** syntax highlighting uses a native tokenizer (no JavaScript engine) with the exact GitHub
    light-default / dark-dimmed colours of §2.6, highlights only after the message stops streaming and only near the
    screen, and caches by (language, code). **UNKNOWN:** which tokenizer (tree-sitter grammars vs a small hand-written
    lexer for the labelled languages). Pick by binary size and a speed test on a 3,000-line block.
12. **DECISION:** the code card's 120 pt height clamp stays, with a 44 pt toggle (web: 36×28) (§2.6).
13. **DECISION:** run summaries use the full tool arguments, as the renderer does. Build 238's phone drops `urls`, so
    it shows "Read 1 page" where the renderer says "Read example.com/docs" (§3.2.1).
14. **⚑ / DECISION:** the waiting capsule and the cold-load skeleton are flag-off in Release (`PHONE_TURN_STATUS`).
    Native M1 builds them anyway (§3.4, §4.2). Say so in the build note so the owner can compare.
15. **⚑ / DECISION:** the shipped primary circle is 36 pt (`phone-ui-voice.css:19`). Native uses 40 pt to match the
    rest of the Telegram row (§4.3). Check it on the owner's phone.
16. **DECISION:** a file edit's trail row shows no "+N −M" counts, as shipped (the meta code is dead in build 238;
    §3.3).
17. **DECISION:** M1's error card shows the reason, Retry (as the primary) and Details. Other recoveries come later
    (§5.6.1). The stopped-row Retry capsule gets a 44 pt hit area (§5.6.3).
