// Hermes HQ theme: a desktop Hermes theme that looks like Hermes HQ on an iPhone (and Nous High Contrast, below).
//
// It adds the theme "Hermes HQ" to Settings › Appearance (and Cmd-K, /skin), through desktop's own `themes`
// contribution area: no Hermes code changes. The palette is the phone's iOS one (src/ui-kit/ios-theme.ts and
// src/phone-ios-tokens.css): white page and #f2f2f7 sidebar in light, true black and #1c1c1e in dark, iOS system
// blue, the SF system font. The CSS below gives it the phone's shapes: iOS corner radii instead of desktop's nearly
// square ones, your messages as filled blue bubbles on the right, a bot's text in grey bubbles on the left (its tool
// rows outside them), a round composer and rounded sidebar rows. Beyond the chat it restyles desktop's shared
// parts, so every page follows: capsule buttons and tint-coloured text buttons, iOS's green switches, round check
// boxes, grey-filled fields, segmented tabs, round menus, solid round sheets over a light dim, Settings as a
// grouped list of white cards, round faces in the sidebar, and sentence case in place of spaced-out capitals.
//
// The CSS keys on desktop's data-slot hooks and a few of its class names, so a Hermes update can move them; the
// palette part keeps working either way. The renderer sets the palette's own tokens inline on <html>, so the CSS
// paints the bubbles from its own --hq-* variables rather than overriding those.
// Installed as ~/.hermes/desktop-plugins/hermes-hq-theme/plugin.js; desktop reloads it when the file changes.
//
// The CSS block is generated: its readable source is scripts/desktop-theme/ (one file per area, in the order of its
// ORDER file), built into this file minified by `node scripts/desktop-theme-build.mjs`. Edit those files, not the block.

const SYSTEM_SANS = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif, "Apple Color Emoji"'
const SYSTEM_MONO = 'ui-monospace, "SF Mono", Menlo, monospace, "Apple Color Emoji"'

// HQ's standard look (HermesKit/Theme/ThemeTokens.swift, ThemeResolver.base): the Nous ink and page, HQ's blue,
// iOS's separators and fills. Not iOS's own white/black and #007aff: that is the separate "iOS System" skin.
export const LIGHT = {
  background: '#fefefe', foreground: '#1f2328', card: '#f2f2f7', cardForeground: '#1f2328',
  muted: '#f6f8fa', mutedForeground: '#595c60', popover: '#ffffff', popoverForeground: '#1f2328',
  primary: '#0053fd', primaryForeground: '#ffffff', secondary: '#e6eeff', secondaryForeground: '#1f2328',
  accent: '#e6eeff', accentForeground: '#1f2328', border: '#c6c6c8', input: '#fefefe', ring: '#0053fd',
  midground: '#0053fd', midgroundForeground: '#ffffff', composerRing: '#0053fd',
  destructive: '#d70015', destructiveForeground: '#ffffff',
  sidebarBackground: '#f6f8fa', sidebarBorder: '#c6c6c8',
  userBubble: '#0053fd', userBubbleBorder: '#0053fd',
}

export const DARK = {
  background: '#0d1015', foreground: '#e6edf3', card: '#1c1c1e', cardForeground: '#e6edf3',
  muted: '#1c1c1e', mutedForeground: '#aeb4b9', popover: '#1c1c1e', popoverForeground: '#e6edf3',
  primary: '#4a84fe', primaryForeground: '#ffffff', secondary: '#15254a', secondaryForeground: '#e6edf3',
  accent: '#15254a', accentForeground: '#e6edf3', border: '#38393d', input: '#0d1015', ring: '#4a84fe',
  midground: '#4a84fe', midgroundForeground: '#ffffff', composerRing: '#4a84fe',
  destructive: '#ff453a', destructiveForeground: '#ffffff',
  sidebarBackground: '#010409', sidebarBorder: '#38393d',
  userBubble: '#3863bf', userBubbleBorder: '#3863bf',
}

export const CSS = `
/* t01-global */
html:root{--radius-scalar:1}
/* t02-bubbles */
html:root{--conversation-text-font-size:14px}
html:root{--hq-bubble-me:#0053fd}
html:root.dark{--hq-bubble-me:#3863bf}
[data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container){position:relative;width:fit-content;max-width:min(80%,44rem);margin-left:auto;padding:8px 13px;border:0;border-radius:12px 12px 0 12px;background:var(--hq-bubble-me);color:#fff;box-shadow:none;backdrop-filter:none}
[data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container) a{text-decoration:underline;text-underline-offset:.15em}
[data-slot='aui_user-message-root'] .composer-human-message-container{background:transparent;justify-content:flex-end}
html:root{--hq-bubble-bot:#e9e9eb}
html:root.dark{--hq-bubble-bot:#26282c}
[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md){position:relative;width:fit-content;max-width:min(88%,60rem);box-sizing:border-box;padding:8px 13px;border-radius:12px 12px 12px 0;background:var(--hq-bubble-bot)}
:is([data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container),[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md))::after{content:'';position:absolute;bottom:0;width:8px;height:15px;pointer-events:none}
[data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container)::after{right:-8px;background:radial-gradient(ellipse 100% 100% at 100% 0,transparent 98%,var(--hq-bubble-me) 100%)}
[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md)::after{left:-8px;background:radial-gradient(ellipse 100% 100% at 0 0,transparent 98%,var(--hq-bubble-bot) 100%)}
:is([data-slot='aui_assistant-message-content'],[data-slot='aui_user-message-root']) .overflow-hidden:has(:is(.aui-md,.composer-human-message)),[data-slot='aui_assistant-message-content'].overflow-hidden,[data-slot='aui_assistant-message-root'].overflow-hidden,:is([data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container),[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md)).overflow-hidden{overflow:clip;overflow-clip-margin:8px}
[data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container){overflow:visible}
/* t03-chrome */
body{--hq-field:#e9e9ea}
html:root.dark body{--hq-field:#2f3137}
html:root body :is([data-slot='composer-root'],[data-slot='composer-root'][data-thread-scrolled-up]){--composer-fill:var(--hq-field)}
html:root body [data-slot='composer-surface']{border-radius:22px;border-color:transparent !important}
/* t04-chatcards */
:is([data-slot='code-card'],[data-slot='file-diff-panel'],.aui-md pre){border-radius:10px}
html:root body{--ui-widget-surface-background:var(--hq-card);--ui-diff-add-border:#34c759;--ui-diff-add-background:rgb(52 199 89/.12);--ui-diff-add-foreground:#248a3d;--ui-diff-remove-border:#ff3b30;--ui-diff-remove-background:rgb(255 59 48/.1);--ui-diff-remove-foreground:#d70015}
html:root.dark body{--ui-diff-add-border:#30d158;--ui-diff-add-background:rgb(48 209 88/.16);--ui-diff-add-foreground:#30db5b;--ui-diff-remove-border:#ff453a;--ui-diff-remove-background:rgb(255 69 58/.16);--ui-diff-remove-foreground:#ff6961}
.rounded-3xl[class*='bg-(--ui-widget-surface-background)']{border-radius:var(--hq-card-r)}
/* t05-global */
body{--hq-cell:#fff;--hq-grouped:#f2f2f7;--hq-raised:#fff;--hq-card:#f2f2f7;--hq-card-r:20px;--hq-page:#fefefe;--hq-sidebar:#f6f8fa;--hq-ink:#1f2328;--hq-tint-text:#0040dd;--hq-sep:rgb(60 60 67/.29);--hq-label-2:rgb(31 35 40/.74);--hq-fill-4:rgb(116 116 128/.08);--hq-fill:rgb(120 120 128/.2);--hq-fill-2:rgb(120 120 128/.16);--hq-fill-3:rgb(118 118 128/.12);--hq-green:#34c759;--hq-thumb-shadow:0 3px 8px rgb(0 0 0/.15),0 3px 1px rgb(0 0 0/.06);--hq-menu-shadow:0 0 0 .5px rgb(0 0 0/.16),0 2px 6px rgb(0 0 0/.08),0 12px 32px rgb(0 0 0/.2);--hq-tint:var(--theme-primary)}
html:root.dark body{--hq-cell:#1c1c1e;--hq-grouped:#000;--hq-raised:#2c2c2e;--hq-card:#1c1c1e;--hq-page:#0d1015;--hq-sidebar:#010409;--hq-ink:#e6edf3;--hq-tint-text:#0a84ff;--hq-sep:rgb(84 84 88/.6);--hq-label-2:rgb(230 237 243/.74);--hq-fill-4:rgb(118 118 128/.18);--hq-fill:rgb(120 120 128/.36);--hq-fill-2:rgb(120 120 128/.32);--hq-fill-3:rgb(118 118 128/.24);--hq-green:#30d158;--hq-thumb-shadow:0 3px 8px rgb(0 0 0/.3),0 3px 1px rgb(0 0 0/.1);--hq-menu-shadow:0 0 0 .5px rgb(255 255 255/.16),0 0 0 1px rgb(0 0 0/.5),0 12px 32px rgb(0 0 0/.55)}
body{--ui-bg-chrome:var(--hq-page);--ui-bg-sidebar:var(--hq-sidebar);--ui-stroke-primary:var(--hq-sep);--ui-stroke-secondary:var(--hq-sep);--ui-stroke-tertiary:color-mix(in srgb,var(--hq-sep) 60%,transparent);--ui-stroke-quaternary:color-mix(in srgb,var(--hq-sep) 40%,transparent);--ui-row-active-background:var(--hq-fill-2);--ui-row-hover-background:var(--hq-fill-4);--ui-control-hover-background:var(--hq-fill-3);--ui-control-active-background:var(--hq-fill-2)}
html:root body .uppercase{text-transform:none;letter-spacing:normal}
[data-slot='button']:not([data-size='inline'],[data-size='micro'],[data-size='grip'],[data-variant='link'],[data-variant='text'],[data-variant='textStrong']){border-radius:999px}
[data-slot='button']:is([data-variant='secondary'],[data-variant='outline']){background:var(--hq-fill-3);color:var(--hq-tint);box-shadow:none}
[data-slot='button']:is([data-variant='secondary'],[data-variant='outline']):hover{background:var(--hq-fill-2);color:var(--hq-tint)}
[data-slot='button']:is([data-variant='link'],[data-variant='text'],[data-variant='textStrong']){color:var(--hq-tint-text);text-decoration:none}
[data-slot='button']:is([data-variant='link'],[data-variant='text'],[data-variant='textStrong']):hover{color:var(--hq-tint-text);opacity:.7;text-decoration:none}
[data-slot='switch']{width:38px;height:23px;padding:2px;border:0;border-radius:999px;box-shadow:none}
[data-slot='switch'][data-state='checked']{background:var(--hq-green)}
[data-slot='switch'][data-state='unchecked']{background:var(--hq-fill)}
[data-slot='switch-thumb']{width:19px;height:19px;background:#fff;box-shadow:var(--hq-thumb-shadow)}
[data-slot='checkbox']{border-radius:999px}
:is([data-slot='input'],[data-slot='textarea'],[data-slot='select-trigger'],.desktop-input-chrome):not([data-slot='composer-rich-input']){border-radius:10px;border-color:transparent;background:var(--hq-fill-3);box-shadow:none}
:is([data-slot='input'],[data-slot='textarea'],[data-slot='select-trigger'],.desktop-input-chrome):not([data-slot='composer-rich-input']):hover{border-color:transparent}
:is([data-slot='input'],[data-slot='textarea'],[data-slot='select-trigger'],.desktop-input-chrome):not([data-slot='composer-rich-input']):is(:focus,:focus-within,[data-state='open']){border-color:var(--hq-tint);box-shadow:0 0 0 3px color-mix(in srgb,var(--hq-tint) 22%,transparent)}
[data-slot='tabs-list']{background:var(--hq-fill-3);border:0;border-radius:9px;padding:2px;gap:0}
[data-slot='tabs-trigger']{border-radius:7px;border:0;box-shadow:none}
[data-slot='tabs-trigger'][data-state='active']{background:var(--hq-raised);box-shadow:var(--hq-thumb-shadow)}
/* t06-overlays */
:is([data-slot='dropdown-menu-content'],[data-slot='dropdown-menu-sub-content'],[data-slot='context-menu-content'],[data-slot='context-menu-sub-content'],[data-slot='select-content'],[data-slot='command']){border-radius:10px;border-color:transparent;background:var(--hq-raised);box-shadow:var(--hq-menu-shadow)}
[data-slot='command'] [cmdk-group-heading]{padding:8px 10px 4px;font-size:12px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--hq-label-2);background:var(--hq-raised)}
:is([data-slot='dropdown-menu-item'],[data-slot='dropdown-menu-checkbox-item'],[data-slot='dropdown-menu-radio-item'],[data-slot='dropdown-menu-sub-trigger'],[data-slot='context-menu-item'],[data-slot='context-menu-checkbox-item'],[data-slot='context-menu-sub-trigger'],[data-slot='select-item'],[data-slot='command-item']){border-radius:5px}
:is([data-slot='dropdown-menu-separator'],[data-slot='context-menu-separator'],[data-slot='select-separator'],[data-slot='command-separator']){background:var(--hq-sep)}
[data-slot='popover-content']{border-radius:10px;border-color:transparent;background:var(--hq-raised);box-shadow:var(--hq-menu-shadow)}
[data-slot='popover-content'] > [data-slot='command']{border-radius:10px;background:transparent;box-shadow:none}
[role='region'] > [data-slot='card-stack'] [data-slot='alert']{padding-block:12px;font-size:12px}
/* t07-chatcards */
[data-slot='tool-approval-stack'] [data-slot='card-stack'] :is([data-slot='card-stack-surface'],[data-slot='card-stack-edge']){border:0;border-radius:var(--hq-card-r);background:var(--hq-card);box-shadow:none}
[data-slot='tool-approval-stack'][data-approval-placement='floating'] [data-slot='card-stack'] :is([data-slot='card-stack-surface'],[data-slot='card-stack-edge']){background:var(--hq-raised);box-shadow:var(--hq-menu-shadow)}
[data-approval-activity][data-glass-opaque]{border-radius:10px}
:is([data-slot='badge'],[data-slot='kbd']){border-radius:6px}
/* t08-overlays */
:is([data-slot='dialog-overlay'],[data-slot='sheet-overlay'],[data-overlay-surface]){background-color:rgb(0 0 0/.2);backdrop-filter:none}
html:root.dark :is([data-slot='dialog-overlay'],[data-slot='sheet-overlay'],[data-overlay-surface]){background-color:rgb(0 0 0/.48)}
[data-slot='dialog-content']{border-radius:22px;border-color:transparent;background:var(--hq-raised);box-shadow:0 20px 60px rgb(0 0 0/.22)}
[data-overlay-surface] [data-glass-raised]{border-radius:22px;border-color:transparent;background-color:var(--hq-grouped);box-shadow:0 20px 60px rgb(0 0 0/.22)}
/* t09-settings-a */
html:root.dark [data-overlay-surface]{--hq-grouped:#1c1c1e;--hq-cell:#2c2c2e}
[data-overlay-surface] [data-glass-raised]:has([id^='setting-field-']) :is(main,div:has(> main)){background:var(--hq-grouped)}
:is(:has(> [id^='setting-field-']):not(.overflow-y-auto),[data-overlay-surface] .grid.gap-1:has(> :is(.scroll-mt-6.rounded-lg,.\\@container) .grid.gap-3.py-3)){gap:0;padding:0 16px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main :is(.overflow-y-auto,:not(:has(> [id^='setting-field-'])):not(.grid.gap-1,[id^='setting-field-'],.scroll-mt-6,.rounded-xl,.border-b,[class*='bg-('])) > :is([id^='setting-field-'],.\\@container:has(> .grid.gap-3.py-3)){padding:0 16px;background:var(--hq-cell)}
[data-overlay-surface] main :is(.overflow-y-auto,:not(:has(> [id^='setting-field-'])):not(.grid.gap-1,[id^='setting-field-'],.scroll-mt-6,.rounded-xl,.border-b,[class*='bg-('])) > :not(:is([id^='setting-field-'],.\\@container:has(> .grid.gap-3.py-3))) + :is([id^='setting-field-'],.\\@container:has(> .grid.gap-3.py-3)),[data-overlay-surface] main :is(.overflow-y-auto,:not(:has(> [id^='setting-field-'])):not(.grid.gap-1,[id^='setting-field-'],.scroll-mt-6,.rounded-xl,.border-b,[class*='bg-('])) > :is([id^='setting-field-'],.\\@container:has(> .grid.gap-3.py-3)):first-child{border-top-left-radius:var(--hq-card-r);border-top-right-radius:var(--hq-card-r)}
[data-overlay-surface] main :is(.overflow-y-auto,:not(:has(> [id^='setting-field-'])):not(.grid.gap-1,[id^='setting-field-'],.scroll-mt-6,.rounded-xl,.border-b,[class*='bg-('])) > :is([id^='setting-field-'],.\\@container:has(> .grid.gap-3.py-3)):not(:has(+ [id^='setting-field-'],+ .\\@container > .grid.gap-3.py-3)){margin-bottom:20px;border-bottom-left-radius:var(--hq-card-r);border-bottom-right-radius:var(--hq-card-r)}
[data-overlay-surface] main [id^='setting-field-']:has(> div > p.max-w-2xl:first-child + .mt-2){padding:0!important;background:none!important;box-shadow:none!important}
[data-overlay-surface] main [id^='setting-field-'] > div > p.max-w-2xl:first-child:has(+ .mt-2){padding:0 16px 6px;font-size:12px;color:var(--hq-label-2)}
[data-overlay-surface] main [id^='setting-field-'] > div > p.max-w-2xl:first-child + .mt-2{margin-top:0;padding:0 16px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
/* t10-settings-c */
[data-overlay-surface] main .\\@container.mb-6:has(> .grid > .min-w-0 > .text-lg.font-semibold){padding:9px 14px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main section > .\\@container:has(> .\\@container > .grid.gap-2.py-3){padding:0 16px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main section > .\\@container > .\\@container + .\\@container{box-shadow:0 -.5px 0 var(--hq-sep)}
[data-overlay-surface] main .mx-auto.max-w-2xl:has(> [id^='setting-field-about.']){padding:0!important;background:none!important}
[data-overlay-surface] main [id^='setting-field-about.'].grid{gap:0;padding:0 16px;border-radius:var(--hq-card-r)!important;background:var(--hq-cell)}
[id^='setting-field-about.'] > .rounded-xl.border{padding:12px 0;border:0;border-radius:0;background:none}
[id^='setting-field-about.'] > * + *{box-shadow:0 -.5px 0 var(--hq-sep)}
[data-overlay-surface] main .mx-auto.max-w-2xl > dl.rounded-lg.border{gap:0;margin-top:20px;padding:4px 16px;border:0;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main .mx-auto.max-w-2xl > dl.rounded-lg.border > div + div{box-shadow:0 -.5px 0 var(--hq-sep)}
[data-overlay-surface] main .grid.gap-2:has(> .scroll-mt-6.rounded-\\[6px\\]){gap:0;padding:0 16px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main .scroll-mt-6.rounded-\\[6px\\] > .group\\/card{padding:10px 0;border-radius:0;background:none!important;--tw-ring-shadow:0 0 #0000;box-shadow:none}
[data-overlay-surface] main .scroll-mt-6.rounded-\\[6px\\] + .scroll-mt-6.rounded-\\[6px\\]{box-shadow:0 -.5px 0 var(--hq-sep)}
[data-overlay-surface] main:has(> div > nav[aria-label='Tools & Keys']) .scroll-mt-6 .h-8.min-w-0 > .truncate{font-variant-caps:all-small-caps;font-size:14px;letter-spacing:.03em}
[data-overlay-surface] main button.group.grid.rounded-\\[6px\\]:has(> .flex-col > .font-semibold){margin-bottom:20px;padding:9px 14px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main section.grid.gap-2:has(> :is(button.group.flex,div.group.grid).rounded-\\[6px\\]){gap:0}
[data-overlay-surface] main section.grid.gap-2:has(> :is(button.group.flex,div.group.grid).rounded-\\[6px\\]) > p{margin:20px 0 6px;padding:0 16px;font-size:12px;font-weight:400;color:var(--hq-label-2)}
[data-overlay-surface] main section.grid.gap-2 > :is(button.group.flex,div.group.grid).rounded-\\[6px\\]{border-radius:0;background-color:var(--hq-cell)}
[data-overlay-surface] main section.grid.gap-2 > :is(button.group.flex,div.group.grid).rounded-\\[6px\\] + :is(button.group.flex,div.group.grid).rounded-\\[6px\\]{background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-size:calc(100% - 32px) .5px;background-position:16px 0;background-repeat:no-repeat}
[data-overlay-surface] main :not(:is(button.group.flex,div.group.grid).rounded-\\[6px\\]) + section.grid.gap-2 > :is(button.group.flex,div.group.grid).rounded-\\[6px\\]{border-top-left-radius:var(--hq-card-r);border-top-right-radius:var(--hq-card-r)}
[data-overlay-surface] main section.grid.gap-2 > :is(button.group.flex,div.group.grid).rounded-\\[6px\\]:not(:has(+ :is(button.group.flex,div.group.grid).rounded-\\[6px\\])){border-bottom-left-radius:var(--hq-card-r);border-bottom-right-radius:var(--hq-card-r)}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat){margin-bottom:20px}
[data-overlay-surface] main .px-2.py-1\\.5:has(> section > button.group\\/kbd-cat){padding:0}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat) > .flex.rounded-lg{padding:8px 16px;border-radius:0;background-color:var(--hq-cell)}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat) > .flex.rounded-lg + .flex.rounded-lg{background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-size:calc(100% - 32px) .5px;background-position:16px 0;background-repeat:no-repeat}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat) > .flex.rounded-lg:first-of-type{border-top-left-radius:var(--hq-card-r);border-top-right-radius:var(--hq-card-r)}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat) > .flex.rounded-lg:last-child{border-bottom-left-radius:var(--hq-card-r);border-bottom-right-radius:var(--hq-card-r)}
[data-overlay-surface] main section:has(> button.group\\/kbd-cat) > .flex.rounded-lg > span{font-size:13px}
[data-overlay-surface] main .grid:has(> .\\@container + .\\@container > .grid.gap-3.py-3):not(.grid.gap-1){row-gap:0}
[data-overlay-surface] main section > :is(.divide-y,.grid).rounded-md.border{border:0;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main .mx-auto.max-w-2xl > .rounded-xl.border{padding:9px 14px;border:0;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main .mx-auto.max-w-2xl > .rounded-xl.border .mt-1.flex-col.gap-2{gap:0;margin-top:6px}
[data-overlay-surface] main .mx-auto.max-w-2xl > .rounded-xl.border button.items-start.rounded-lg.border{padding:11px 0;border:0;border-radius:0;background:none}
[data-overlay-surface] main .mx-auto.max-w-2xl > .rounded-xl.border button.items-start.rounded-lg.border + button{box-shadow:0 -.5px 0 var(--hq-sep)}
[id^='setting-field-']:not(.overflow-y-auto > *),.grid.gap-1 > .scroll-mt-6.rounded-lg{border-radius:0}
[data-overlay-surface] .grid.gap-1:has(> :is(.scroll-mt-6.rounded-lg,.\\@container) .grid.gap-3.py-3) + *{margin-top:20px}
:is([id^='setting-field-'],.grid.gap-1 > .scroll-mt-6.rounded-lg,.grid.gap-1 > .\\@container) + :is([id^='setting-field-'],.scroll-mt-6.rounded-lg,.\\@container){box-shadow:0 -.5px 0 var(--hq-sep)}
/* t11-sidebar */
button.group\\/section-label > span.tracking-\\[0\\.16em\\]{padding-left:4px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:0;color:var(--hq-label-2)}
.dither.size-2{display:none}
[data-slot='sidebar-wrapper'] .border-b:has(> input[placeholder^='Search']){display:flex;width:100%;height:28px;padding:0 8px;border:0;border-radius:8px;background:var(--hq-fill-3);opacity:1}
[data-slot='sidebar-wrapper'] .border-b:has(> input[placeholder^='Search']) > input{font-size:13px;field-sizing:fixed}
[data-slot='bots-roster'] .grid:has(> [data-roster-key]){gap:0}
[data-slot='bots-section']{margin-left:0;padding-left:0;border-left:0}
[data-slot='bots-roster'] button.tracking-wider{gap:5px;margin-top:6px;padding:5px 8px 5px 10px;font-size:12px;font-weight:600;letter-spacing:0;text-transform:none;color:var(--hq-label-2)}
[data-slot='bots-roster'] button.tracking-wider > .codicon:not(.codicon-chevron-right){display:none}
[data-slot='bots-roster'] button.tracking-wider > .codicon-chevron-right{order:3;font-size:11px !important;opacity:.6}
[data-slot='bots-roster'] button.tracking-wider > .tabular-nums{order:1;color:inherit}
[data-slot='bots-roster'] button.tracking-wider > .tabular-nums::before{content:'· '}
[data-slot='bots-roster'] button.tracking-wider > .flex-1{order:2}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger']{position:relative;gap:10px;min-height:48px;padding:5px 8px;border-radius:10px}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] img{width:34px !important;height:34px !important;border-radius:50% !important}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] :is(.w-\\[34px\\]){width:34px}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] .size-8{width:34px;height:34px;border-radius:50%}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] .font-medium{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.01em}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] .codicon-pinned{display:none}
[data-slot='bots-roster'] button[data-slot='context-menu-trigger'] .text-xs > .truncate{white-space:normal;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
[data-slot='bots-roster'] [data-roster-key] span.size-3\\.5{display:none}
[data-slot='bots-roster'] [data-roster-key] span.size-3\\.5:has([role='status']){display:grid;position:absolute;right:12px;bottom:17px}
[data-slot='bots-roster'] [data-roster-key]:has([role='status']) .text-xs{padding-right:18px}
[data-slot='bots-roster'] [data-roster-key] [role='status'][class~='bg-(--ui-success)']{background:var(--hq-tint)}
[data-slot='bots-roster'] [data-roster-key] + [data-roster-key]::before{content:'';position:absolute;top:0;left:54px;right:10px;border-top:.5px solid var(--hq-sep);pointer-events:none}
[data-slot='bots-roster'] .grid:has(> button[data-slot='context-menu-trigger']) > .flex-col{opacity:0;transition:opacity .15s}
[data-slot='bots-roster'] .grid:has(> button[data-slot='context-menu-trigger']):hover > .flex-col{opacity:1}
[data-slot='bots-roster'] :is([data-roster-key][class~='bg-(--ui-row-active-background)'],[data-roster-key]:hover)::before,[data-slot='bots-roster'] :is([data-roster-key][class~='bg-(--ui-row-active-background)'],[data-roster-key]:hover) + [data-roster-key]::before{border-color:transparent}
:is([data-slot='pane-tab'],[role='tab'][data-tree-tab]){font-size:12px;border-left-color:transparent}
:is([data-slot='pane-tab'],[role='tab'][data-tree-tab]):not([data-vertical]){height:22px;margin:auto 1px;border-radius:999px}
:is([data-slot='pane-tab'],[role='tab'][data-tree-tab])[data-vertical][data-active='true']{border-radius:999px}
[data-slot='pane-tab'][data-vertical]:first-child{margin-top:12px}
/* t12-bubbles */
body{--composer-width:52rem}
body{--conversation-turn-gap:6px;--turn-block-gap:8px;--tool-row-gap:4px}
/* t13-sidebar */
:root[data-hermes-glass][data-hermes-glass-scope='sidebar'] body:has([data-tree-group]){background:color-mix(in srgb,var(--ui-bg-chrome) var(--translucency-glass-keep,100%),transparent)}
:root[data-hermes-glass][data-hermes-glass-scope='sidebar'] [data-tree-group]:not(:has([data-slot='bots-roster'],[data-slot='sidebar'])){background-color:var(--ui-bg-chrome)}
:root[data-hermes-glass][data-hermes-glass-scope='sidebar'] :is([data-slot='bots-roster'],[data-slot='sidebar']){--ui-row-active-background:var(--hq-fill-2);--chrome-action-hover:var(--hq-fill-3)}
/* t14-chrome */
:is([data-slot='pane-tab'],[role='tab'][data-tree-tab]){font-size:12px}
:is([data-slot='pane-tab'],[role='tab'][data-tree-tab]):not([data-vertical]){height:24px;padding-inline:4px}
[role='tablist']:has(> .contents > [data-tree-tab='workspace']) > .contents > :first-child{margin-left:auto}
[role='tab'][data-tree-tab='workspace']{max-width:24rem;font-size:12px;color:var(--hq-label-2)}
[role='tab'][data-tree-tab='workspace'][data-active='true']{font-weight:600;color:var(--foreground)}
[role='tab'][data-tree-tab='workspace'] .tab-key-hint-icon:has(> * > [class~='bg-(--ui-text-quaternary)']){display:none}
/* t15-settings-a */
[id^='setting-field-'] > * > *{min-height:30px}
[data-overlay-surface] aside button:not([data-slot='button']){height:auto;min-height:28px;font-size:13px;border-radius:10px;border-color:transparent}
[data-overlay-surface] aside button:not([data-slot='button']):not([aria-current='page']){background:transparent}
[data-overlay-surface] aside button:not([data-slot='button']):not([aria-current='page']):hover{background:var(--hq-fill-3)}
[data-overlay-surface] aside button[class~='bg-(--ui-bg-tertiary)']{font-weight:600}
[data-overlay-surface] aside button[aria-current='page']{background:var(--hq-tint);color:#fff;font-weight:500}
[data-overlay-surface] aside button[aria-current='page'] :is(svg,i){color:#fff}
/* t16-global */
[data-slot='button'][data-size='lg']{padding:9px 20px;font-size:12px}
[data-slot='select-trigger'] > span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis}
:is([data-slot='dropdown-menu-content'],[data-slot='context-menu-content'],[data-slot='select-content'],[data-slot='dropdown-menu-sub-content'],[data-slot='context-menu-sub-content']){padding:5px}
[data-slot='tabs-trigger']{height:26px;padding-inline:12px;font-size:12px}
/* t17-pages-ops */
[data-overlay-surface] .group\\/row:has(> [data-slot='row-button']){height:32px;flex-shrink:0;font-size:12px;border-radius:8px}
@media (min-width:47.5rem){[data-overlay-surface] .shrink-0.flex-col:has(> * > .group\\/row > [data-slot='row-button']){width:16rem}
}
[data-overlay-surface] header > .min-w-0 > h2.text-sm.font-semibold{font-size:17px;line-height:22px;font-weight:700;letter-spacing:-.02em}
[data-overlay-surface] header > .min-w-0 > h2 + *{font-size:12px;color:var(--hq-label-2)}
[data-overlay-surface] .inline-flex.border-b:has(> input){height:32px;margin-bottom:8px;padding:0 10px;border:0;border-radius:10px;background:var(--hq-cell)}
[data-overlay-surface] .overflow-y-auto:has(> .group\\/row > [data-slot='row-button']){padding:4px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] .space-y-4 > header > dl{grid-template-columns:8rem 1fr;gap:0;padding:0 16px;border-radius:var(--hq-card-r);background:var(--hq-cell);font-size:12px}
[data-overlay-surface] .space-y-4 .tracking-wider + .flex.flex-col.gap-px{gap:0;padding:0 4px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main ul:has(> li.group.py-2){margin-block:4px 24px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main ul > li.group.py-2{position:relative;min-height:42px;padding:8px 12px 8px 16px}
[data-overlay-surface] main ul > li.group.py-2 + li::before{content:'';position:absolute;top:0;left:16px;right:0;border-top:.5px solid var(--hq-sep)}
[data-overlay-surface] main :is(section,section > div) > .flex.justify-between.gap-3.py-2{position:relative;min-height:42px;padding:7px 14px;background:var(--hq-cell)}
[data-overlay-surface] main :is(section,section > div) > :not(.py-2) + .flex.justify-between.gap-3.py-2{border-radius:var(--hq-card-r) var(--hq-card-r) 0 0}
[data-overlay-surface] main :is(section,section > div) > .flex.justify-between.gap-3.py-2:last-child{border-bottom-left-radius:var(--hq-card-r);border-bottom-right-radius:var(--hq-card-r)}
[data-overlay-surface] main :is(section,section > div) > .py-2 + .flex.justify-between.gap-3.py-2::before{content:'';position:absolute;top:0;left:16px;right:0;border-top:.5px solid var(--hq-sep)}
[data-overlay-surface] main .grid.grid-cols-2.py-2 > .min-w-0:has(> .tracking-\\[0\\.12em\\]){padding:9px 14px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main .tracking-\\[0\\.12em\\].uppercase{font-size:12px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--hq-label-2)}
[data-overlay-surface] main .tracking-\\[0\\.12em\\] + *{font-size:17px;font-weight:700;letter-spacing:-.01em}
[data-overlay-surface] main section > ul:has(> li.py-1\\.5){border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] main section > ul > li.py-1\\.5{position:relative;min-height:30px;padding:8px 16px}
[data-overlay-surface] main section > ul > li.py-1\\.5 + li::before{content:'';position:absolute;top:0;left:16px;right:0;border-top:.5px solid var(--hq-sep)}
/* t18-pages-cap */
div:has(> button.group\\/text-tab){gap:0;padding:2px;border-radius:9px;background:var(--hq-fill-3)}
button.group\\/text-tab{height:26px;padding-inline:12px;border-radius:7px;font-size:12px;color:var(--foreground)}
button.group\\/text-tab > span{text-decoration:none !important}
button.group\\/text-tab[data-active='true']{background:var(--hq-cell) !important;font-weight:600;box-shadow:0 3px 8px rgb(0 0 0/.12),0 1px 1px rgb(0 0 0/.04)}
html:root.dark button.group\\/text-tab[data-active='true']{background:#636366 !important}
/* t19-global */
.inline-grid.grid-flow-col.rounded-\\[5px\\]:has(> button[aria-pressed]){gap:0;padding:2px;border-radius:9px;background:var(--hq-fill-3)}
.inline-grid.grid-flow-col.rounded-\\[5px\\] > button[aria-pressed='true']{background:#fff;color:#000;box-shadow:var(--hq-thumb-shadow)}
html:root.dark .inline-grid.grid-flow-col.rounded-\\[5px\\] > button[aria-pressed='true']{background:#636366;color:#fff}
:is([class~='border-(--ui-stroke-tertiary)'][class~='bg-(--ui-bg-quinary)'],.rounded-xl.border[class~='bg-(--ui-surface-secondary,transparent)'],article.group\\/artifact){border-color:transparent;border-radius:var(--hq-card-r);background:var(--hq-card)}
/* t20-settings-a */
[data-overlay-surface] :is([class~='border-(--ui-stroke-tertiary)'][class~='bg-(--ui-bg-quinary)'],.rounded-xl.border[class~='bg-(--ui-surface-secondary,transparent)']){background:var(--hq-cell)}
/* t21-pages-ops */
[data-overlay-surface] main .pt-2 > .mb-2 > .tracking-\\[0\\.08em\\].uppercase{padding-inline:16px;font-size:12px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--hq-label-2)}
[data-overlay-surface] main [class*='bg-[color:var(--dt-primary)]']{background:var(--hq-tint);opacity:.85}
[data-overlay-surface] main [class*='bg-emerald-500']{background:var(--hq-green)}
.cm-editor.cm-focused{outline:none}
[data-overlay-surface] .group\\/row.h-7{height:34px;font-size:13px}
[data-overlay-surface] .tracking-\\[0\\.14em\\] + *{padding-inline:16px;font-size:12px;color:var(--hq-label-2)}
[data-overlay-surface] .flex.h-full.flex-col.overflow-hidden.rounded-md.border[class~='border-(--ui-stroke-tertiary)']{border-color:transparent;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] .grid.place-items-center:is(.py-12,.py-10) p:is(.text-xs,.text-sm + p){font-size:12px;color:var(--hq-label-2)}
[data-overlay-surface] .flex-col.gap-4 > p.shrink-0.text-\\[0\\.7rem\\]{padding-inline:16px;font-size:12px;color:var(--hq-label-2)}
[data-overlay-surface] section.grid.min-w-0.gap-3:has(> p.tracking-wider){gap:10px}
[data-overlay-surface] section.grid.min-w-0.gap-3 > p.tracking-wider{padding-inline:16px;font-size:12px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--hq-label-2)}
[data-overlay-surface] section.grid.min-w-0.gap-3 > p.tracking-wider + .grid{gap:0;padding:4px 16px;border-radius:var(--hq-card-r);background:var(--hq-cell)}
[data-overlay-surface] section.grid.min-w-0.gap-3 > p.tracking-wider + .grid > [data-slot='tool-block']{padding-block:10px}
[data-overlay-surface] section.grid.min-w-0.gap-3 > p.tracking-wider + .grid > [data-slot='tool-block'] + [data-slot='tool-block']{box-shadow:inset 0 1px 0 var(--hq-sep)}
[data-overlay-surface] [data-slot='tool-block'] .text-\\[0\\.82rem\\]{font-size:12px;line-height:16px}
[data-overlay-surface] [data-slot='tool-block'] .text-\\[0\\.66rem\\]{font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-overlay-surface] [data-slot='tool-block'] .text-\\[0\\.72rem\\]{font-size:12px}
/* t22-bubbles */
:has(> .min-w-0 > [data-slot='group-chat-message-content']){gap:8px;padding:3px 0;background:none}
:has(> .min-w-0 > [data-slot='group-chat-message-content']) > .shrink-0 > *{width:30px !important;height:30px !important}
:has(> [data-slot='group-chat-message-content']) .text-\\[0\\.7rem\\]{font-size:12px;font-weight:600;padding-left:13px}
:has(> [data-slot='group-chat-message-content']) .text-\\[0\\.625rem\\]{font-size:11px}
[data-slot='group-chat-message-content']{width:fit-content;max-width:min(88%,60rem);margin-top:2px;padding:7px 13px;border-radius:18px;background:var(--hq-bubble-bot);color:var(--foreground);font-size:12px;line-height:1.35}
.bg-\\(--chrome-action-hover\\):has(> .min-w-0 > [data-slot='group-chat-message-content']) [data-slot='group-chat-message-content']{margin-left:auto;background:var(--hq-bubble-me);color:#fff}
.flex-col:has(> .border-t > form.grid textarea[data-slot='textarea']) > .overscroll-contain > .grid{width:100%;max-width:var(--composer-width);margin-inline:auto}
.flex-col:has(> .border-t > form.grid textarea[data-slot='textarea']) > .border-t{border-top-color:transparent;padding:8px 16px 12px}
.flex-col:has(> .border-t > form.grid textarea[data-slot='textarea']) > .border-t > form{width:100%;max-width:var(--composer-width);margin-inline:auto}
.flex-col:has(> .border-t > form.grid textarea[data-slot='textarea']) textarea[data-slot='textarea']{min-height:28px;padding:7px 14px;border-radius:20px;font-size:12px;line-height:16px}
.bg-\\(--chrome-action-hover\\):has(> .min-w-0 > [data-slot='group-chat-message-content']) .flex.items-center.gap-2{justify-content:flex-end}
.bg-\\(--chrome-action-hover\\):has(> .min-w-0 > [data-slot='group-chat-message-content']) .flex.items-center.gap-2 > .ml-auto{margin-left:0;order:-1}
/* global */
body{--dt-scrollbar-thumb:#000;--hq-link:var(--hq-tint-text);--hq-label-2:rgb(60 60 67/.6);--hq-label-3:rgb(60 60 67/.3);--hq-section:var(--hq-label-2);--hq-green-text:#248a3d;--hq-orange-text:#c93400;--hq-red-text:#d70015;--ui-success:#34c759;--ui-bg-secondary:var(--hq-fill-2);--ui-bg-tertiary:var(--hq-fill-3);--ui-bg-quaternary:var(--hq-fill-4);--ui-bg-quinary:rgb(118 118 128/.06);--chrome-action-hover:var(--hq-fill-4);--ui-text-quaternary:var(--hq-label-3)}
html:root.dark body{--dt-scrollbar-thumb:#fff;--hq-label-2:rgb(235 235 245/.6);--hq-label-3:rgb(235 235 245/.3);--hq-green-text:#30d158;--hq-orange-text:#ff9f0a;--hq-red-text:#ff453a;--ui-success:#30d158;--ui-bg-quinary:rgb(118 118 128/.1)}
:is(main,[data-overlay-surface]){--ui-text-secondary:var(--hq-label-2)}
:is(main,[data-overlay-surface]:not(:has(main))){--color-muted-foreground:var(--hq-label-2)}
:is(:root[data-hermes-glass][data-hermes-glass-scope],html) [data-tree-group]:has(main):not(:has([data-slot=aui_thread-content])){--ui-editor-surface-background:var(--hq-grouped);--ui-chat-surface-background:var(--hq-grouped);--hq-card:var(--hq-cell);background-color:var(--hq-grouped)}
html:root.dark [data-tree-group]:has(main):not(:has([data-slot=aui_thread-content])){--hq-grouped:#1c1c1e;--hq-cell:#2c2c2e}
:is(main,[data-tree-group] main){--conversation-text-font-size:13px;--conversation-line-height:18px;--conversation-caption-font-size:12px;--conversation-caption-line-height:16px;--ui-text-tertiary:var(--hq-label-2);font-size:13px;line-height:18px;letter-spacing:-.08px;& .text-\\[length\\:var\\(--conversation-text-font-size\\)\\]{font-weight:400;line-height:20px;letter-spacing:-.23px;color:var(--ui-text-primary)}
& .text-\\[length\\:var\\(--conversation-caption-font-size\\)\\]:is(.text-\\(--ui-text-tertiary\\),.text-muted-foreground){color:var(--hq-label-2)}
& [id^=setting-field-] .min-w-0>.text-\\[length\\:var\\(--conversation-caption-font-size\\)\\]:not(#\\#){font-size:12px;line-height:16px;letter-spacing:-.08px}
& .text-sm.font-medium:not([data-slot],button){font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px}
}
html:root body .grid.gap-2:has(> .flex.flex-wrap>button.rounded-full.border)>.font-medium:first-child,html:root body :is(main,[data-tree-group] main) h4.uppercase,html:root body :is(main,[data-overlay-surface]:not(:has(main))) .uppercase:is([class*='text-[0.6'],[class*='text-[0.7'],[class*=tracking-]):not([data-slot],button,span){font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section);padding-inline:0;margin-bottom:6px}
html:root body [data-overlay-surface]:not(:has(main)) .uppercase:is([class*='text-[0.6'],[class*='text-[0.7']):not([data-slot],button,span){padding-left:16px}
html:root body [data-overlay-surface] main :is(p.text-xs.text-muted-foreground,div.text-right[class*='text-[0.65rem]']):not([id^=setting-field-] *,.flex>*){color:var(--hq-section);padding-inline:16px}
:is(main,[data-tree-group]:has(main),[data-overlay-surface]:not(:has(main))){& .text-xs:not([data-slot=sidebar] *,[data-slot],button,input){font-size:12px;line-height:16px;letter-spacing:-.08px}
& .text-sm:not([data-slot=sidebar] *,[data-slot],button,input){font-size:12px;line-height:16px}
& :is([class*='text-[0.6'],[class*='text-[0.7'],[class*='text-[10px]'],[class*='text-[11px]']):not([data-slot=sidebar] *,[data-slot=row-button] *,[data-slot],button,input,kbd){font-size:12px;line-height:16px;letter-spacing:0}
}
:is(main,[data-overlay-surface]:not(:has(main))) :is(:is(pre,code).font-mono,.font-mono[class*='text-[']){font-size:12px;line-height:16px;letter-spacing:0}
:is(main,[data-overlay-surface]:not(:has(main))) h3.font-semibold[class*='text-[0.9']{font-size:18px;line-height:22px;letter-spacing:-.45px}
[data-overlay-surface] main :is(label.grid.text-xs:has(> :is(input,textarea,[data-slot])),fieldset.text-xs>legend){letter-spacing:-.08px}
[data-slot=button]:not([data-slot=composer-bounds] *){&:is([data-size=default],[data-size=sm]){min-height:32px;padding:0 16px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px}
&[data-size=sm]{min-height:32px;padding-inline:14px}
&[data-size=lg]{min-height:30px;padding:0 20px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px}
&:is([data-size=default],[data-size=sm],[data-size=lg]) svg{width:16px;height:16px}
}
[data-slot=button][data-variant=ghost]:not([data-size^=icon]){color:var(--hq-link);&:hover{background:var(--hq-fill-3);color:var(--hq-link)}
}
[data-slot=button][data-variant=default]:disabled{opacity:1;background:var(--hq-fill-2);color:var(--hq-label-3)}
[data-slot=button]:is([data-variant=link],[data-variant=text],[data-variant=textStrong]),[data-slot=button]:is([data-variant=link],[data-variant=text],[data-variant=textStrong]):hover,:is([data-overlay-surface],[data-tree-group] main) a[href]:not([data-slot=button]){color:var(--hq-link)}
[data-overlay-surface] main [id^=setting-field-] [data-slot=button][data-variant=text]{font-size:12px;line-height:16px;font-weight:400}
[data-slot=switch],[data-slot=switch].w-7{width:40px;height:20px;border:0}
html:root.dark [data-slot=switch][data-state=unchecked]{background:rgb(120 120 128/.32)}
[data-slot=switch] [data-slot=switch-thumb],[data-slot=switch].w-7 [data-slot=switch-thumb]{width:22px;height:16px;border-radius:999px}
[data-slot=switch] [data-slot=switch-thumb][data-state=checked],[data-slot=switch].w-7 [data-slot=switch-thumb][data-state=checked]{translate:14px 0}
:is([data-slot=input],input.desktop-input-chrome):not([data-slot=composer-rich-input]){min-height:28px;padding-inline:12px;border-radius:999px;font-size:12px;line-height:16px;letter-spacing:-.08px}
[data-slot=textarea]:not([data-slot=composer-rich-input]){border-radius:var(--hq-card-r)}
:is([data-slot=input],[data-slot=textarea],input.desktop-input-chrome)::placeholder{color:var(--hq-label-3)}
:is([data-slot=input],[data-slot=textarea],[data-slot=select-trigger],.desktop-input-chrome):not([data-slot=composer-rich-input]):is(:focus,:focus-within,[data-state=open]){border-color:transparent;box-shadow:0 0 0 3px color-mix(in srgb,var(--hq-tint) 30%,transparent);caret-color:var(--hq-tint)}
:is([data-slot=input],[data-slot=textarea]):not([data-slot=composer-rich-input]):focus:not(:focus-visible){box-shadow:none}
[data-overlay-surface] main{& :is([id^=setting-field-],.\\@container:not(:has(label))) :is([data-slot=input],input.desktop-input-chrome):not([role=combobox]){min-height:24px;height:24px;padding:0 10px;border-radius:999px;background:var(--hq-fill-3);text-align:right;color:var(--ui-text-primary)}
& :is([id^=setting-field-],.\\@container:not(:has(label))) input[role=combobox]:not(:focus){background:transparent;text-align:right}
& [data-slot=popover-anchor]:not(#\\#)>input[role=combobox]{padding-right:15px;color:var(--hq-link)}
& [data-slot=popover-anchor]>input[role=combobox] + button{right:0;color:var(--hq-link)}
& input[type=number]::-webkit-inner-spin-button{-webkit-appearance:none;margin:0}
}
:is([data-overlay-surface],[data-tree-group]:has(main)) div.inline-flex.border-b:not([data-slot=sidebar] *):has(> input[class*=field-sizing]){min-height:32px;min-width:min(240px,100%);padding:0 12px 0 10px;border:0;border-radius:999px;background:var(--hq-fill-3);opacity:1;&>input{flex:1 1 auto;height:32px;font-size:13px;line-height:18px;letter-spacing:-.08px;&::placeholder{color:var(--hq-label-2);opacity:.8}
}
&>svg{width:17px;height:17px;color:var(--hq-label-2)}
}
[data-slot$=select-trigger]:not([data-slot=composer-rich-input]){min-height:32px;padding-inline:8px;border-radius:999px;background:transparent;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-link)}
[data-overlay-surface] main :is([id^=setting-field-],.\\@container) :is([data-slot$=select-trigger],[data-slot=popover-trigger][data-variant=outline]){width:auto;min-width:0;max-width:100%;margin-left:auto;min-height:28px;padding:0 0 0 8px;justify-content:flex-end;gap:6px;background:transparent;font-size:13px;line-height:18px;letter-spacing:-.08px;&:is(:hover,:focus,:focus-within,[data-state=open]){background:transparent;box-shadow:none;color:var(--hq-link)}
}
:is([id^=setting-field-],[data-slot$=select-trigger],[data-slot=popover-anchor]) .codicon-chevron-down{&:not(#\\#){position:relative;flex:none;width:9px;height:14px;font-size:0!important;opacity:1}
&::before,&::after{content:'';position:absolute;left:2px;width:4px;height:4px;border:solid currentColor;transform:rotate(45deg)}
&::before{top:2px;border-width:1.6px 0 0 1.6px}
&::after{bottom:2px;border-width:0 1.6px 1.6px 0}
}
:is([data-overlay-surface] [data-slot=button]:has(>.codicon-close),[data-slot=dialog-close-button]):not(#\\#){width:30px;height:30px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-label-2)}
.inline-grid.auto-cols-fr.grid-flow-col:has(> button[aria-pressed]){border-radius:999px}
.inline-grid.auto-cols-fr.grid-flow-col>button[aria-pressed]{min-height:28px;padding:0 14px;border-radius:999px;color:var(--ui-text-primary);&[aria-pressed=true]{box-shadow:0 3px 8px rgb(0 0 0/.12),0 3px 1px rgb(0 0 0/.04)}
}
:is(div:has(> button.group\\/text-tab),[data-slot=tabs-list]){border-radius:999px}
:is(button.group\\/text-tab,[data-slot=tabs-trigger]){height:28px;padding-inline:14px;border-radius:999px}
:is(.inline-grid.auto-cols-fr.grid-flow-col>button[aria-pressed],button.group\\/text-tab,[data-slot=tabs-trigger]):not(#\\#){font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;&:is([aria-pressed=true],[data-active=true],[data-state=active]){font-weight:600}
}
button.group\\/text-tab>span + span{font-size:12px;color:var(--hq-label-3)}
:is(main,[data-overlay-surface]) [data-slot=badge]{&:not([aria-hidden=true]){border-radius:999px;padding-inline:8px;font-size:12px;line-height:16px;letter-spacing:0}
&[class*=bg-muted]{background:var(--hq-fill-3);color:var(--hq-label-2)}
&[class*='bg-primary/10']{background:color-mix(in srgb,var(--hq-tint) 12%,transparent)}
&[class*=emerald]{background:rgb(52 199 89/.14);color:var(--hq-green-text)}
&[class*=amber]{background:rgb(255 149 0/.14);color:var(--hq-orange-text)}
&[class*=destructive]{background:rgb(255 59 48/.12);color:var(--hq-red-text)}
}
.grid.gap-2>.flex.flex-wrap{gap:6px;&>button.rounded-full.border{flex:none;min-height:24px;padding:0 10px;border:0;font-size:12px;line-height:18px;letter-spacing:-.08px;background:var(--hq-fill-3);color:var(--ui-text-primary);&:hover{background:var(--hq-fill-2)}
&[class*=ui-bg-tertiary]:not(#\\#){background:color-mix(in srgb,var(--hq-link) 15%,transparent);color:var(--hq-link);font-weight:600}
}
}
input[data-slot=slider]{border-radius:999px;background:var(--hq-fill);&::-webkit-slider-thumb{-webkit-appearance:none;appearance:none;width:20px;height:20px;border:0;border-radius:50%;background:#fff;box-shadow:var(--hq-thumb-shadow),0 0 0 .5px rgb(0 0 0/.04)}
}
:is(main,[data-overlay-surface]){& :is(kbd[class*=dt-font-kbd],[data-slot=kbd]){min-width:0;height:auto;padding:0;border:0;background:transparent;box-shadow:none;font-size:12px;line-height:16px;color:var(--hq-label-3)}
& [data-slot=kbd-group]{gap:1px}
}
:is([data-slot=button],[data-slot=switch],[data-slot=checkbox]):focus-visible{outline:2px solid color-mix(in srgb,var(--hq-tint) 60%,transparent);outline-offset:2px;box-shadow:none}
::-webkit-scrollbar-thumb{border:2px solid transparent;background-clip:padding-box;border-radius:999px}
section:has(>.flex-wrap>[data-slot=select-trigger]){display:flex;flex-direction:column;&>.flex.flex-wrap:not(.mt-3){gap:0;padding-left:16px;border-radius:var(--hq-card-r);background:var(--hq-cell);overflow:hidden;&>[data-slot=select-trigger]{min-height:32px;padding:0 16px 0 0;border:0;border-radius:0;background:transparent;font-size:13px;line-height:18px;letter-spacing:-.08px}
&>* + *{box-shadow:0 -.5px 0 var(--hq-sep)}
&>[data-slot=button]{margin-right:16px;box-shadow:none}
}
&>p{order:1;margin:6px 0 0}
&>.mt-3{order:2;margin-top:20px;display:grid;gap:8px;html:root body &>span.text-xs{padding-left:16px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
&>.flex{min-height:32px;padding-inline:16px;border-radius:var(--hq-card-r);background:var(--hq-cell);html:root body &.items-center.gap-2>span.shrink-0{font-size:13px;line-height:18px;letter-spacing:-.08px}
&>[data-slot=select-trigger]{width:auto;min-width:0;margin-left:auto;padding:0;gap:6px;border:0;background:transparent;font-size:13px}
}
}
}
main .grid>.group.relative>button.text-left{--conversation-text-font-size:13px;--conversation-caption-font-size:13px;--conversation-caption-line-height:18px;html:root body &>.mt-3>.truncate{line-height:18px;font-weight:600;letter-spacing:-.08px}
}
[data-overlay-surface] main [id^=credential-key-]{& .grid.items-start{align-items:center}
& .grid:has(> input:only-child){column-gap:0}
}
[data-overlay-surface]:not(:has(main)) span.font-medium[class*='text-foreground/85']{font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--ui-text-primary)}
[data-overlay-surface] header>.min-w-0>h2.text-sm.font-semibold{font-size:18px;line-height:24px;letter-spacing:.1px;&+p{font-size:12px;line-height:16px;letter-spacing:-.08px}
}
:is([data-overlay-surface],[data-tree-group] main) span[class*='text-[0.66rem]'].text-primary:not(.rounded-full){font-size:12px;line-height:16px;font-weight:400}
[data-tree-group]:has(main){& :is(aside>div.overflow-y-auto:has(> .group\\/row),ul.space-y-1:has(> li>button.row-hover)){background:var(--hq-cell);border-radius:var(--hq-card-r);overflow-x:hidden}
& :is(.group\\/row,ul.space-y-1>li) + :is(.group\\/row,li),& main .grid.gap-1>button[aria-pressed] + button{background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-size:calc(100% - 16px) .5px;background-position:16px 0;background-repeat:no-repeat}
& :is(.group\\/row,ul.space-y-1>li>button.row-hover){border-radius:0}
& .group\\/row>[data-slot=row-button]{padding-left:16px}
& .group\\/row>[role=switch]{margin-right:16px}
& [data-slot=button][class*='text-[0.6875rem]']{padding:0 6px;font-size:12px;line-height:16px;letter-spacing:-.08px}
}
.group\\/row>[data-slot=row-button]{&:has(+ [role=switch]) .text-\\[0\\.78rem\\]{font-weight:600;color:var(--ui-text-primary)}
&:has(+ [role=switch])>span.shrink-0.rounded{padding:0;background:transparent;font-size:12px;line-height:16px;color:var(--hq-label-3)}
& .text-\\[0\\.62rem\\]>[data-slot=badge]{padding:0;background:transparent;font-size:12px;line-height:16px;font-weight:400;color:var(--hq-label-3);&::before{content:'· '}
}
}
[data-tree-group] main{& .grid:has(>.grid.gap-1>button[aria-pressed])>.flex>span.font-medium{padding-left:16px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
& :is(.grid.gap-1:has(> button[aria-pressed]),section>h4 + .mt-3.grid){gap:0;border-radius:var(--hq-card-r);background:var(--hq-cell);overflow:hidden}
& section>h4 + .mt-3.grid{padding-inline:16px}
& .grid.gap-1>button[aria-pressed]{position:relative;padding:7px 44px 7px 14px;border:0;border-radius:0;background-color:transparent;&[aria-pressed=true]::after{content:'';position:absolute;right:20px;top:50%;width:6px;height:12px;margin-top:-8px;border:solid var(--hq-tint);border-width:0 2.2px 2.2px 0;transform:rotate(45deg)}
& .text-xs.font-medium{font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px}
}
& .grid.rounded-lg>.flex.gap-2[class*='text-[0.68rem]']>span.font-medium{width:7.5rem;font-weight:400}
}
:is(button,a[href],[role=button],[role^=menuitem],[role=option],[role=tab],[data-slot$=-item],[data-slot=pane-tab],[data-slot=context-menu-trigger],[data-roster-key],.row-hover):hover{transition-property:color,background-color,border-color,box-shadow,opacity,transform,translate,scale;transition-duration:0s}
:is(:is([data-slot=pane-tab],[class~='group/tab']):not([aria-pressed=true]),:is([data-slot=pane-tab],[class~='group/tab']):not([aria-pressed=true]) *,[class*='group/pane-header'],[class*='group/pane-header'] > div,button.popover-anchor.cursor-grab,button.popover-anchor.cursor-grab *,span.group\\/handle,span.group\\/handle *){cursor:pointer!important}
:is(button,[role=button]):not(:disabled,[aria-disabled=true]):active{filter:brightness(.93)}
html.dark :is(button,[role=button]):not(:disabled,[aria-disabled=true]):active{filter:brightness(1.18)}
:is(.transition-colors,.row-hover,[class*='transition-[background'],[class*='transition-[color'],button.transition-all):not(:hover){transition-duration:60ms}
html.dark img[src*='AAAAGHRFWHRoZXJtZXMtaHEAaW52ZXJ0LW9uLWRhcmu4VO/y']{filter:invert(1)!important}
/* bubbles */
html:root body [data-slot='aui_thread-content']{--hq-chat-scale:calc(var(--chat-text-scale,1.1) / 1.1);--conversation-text-font-size:calc(14px * var(--hq-chat-scale));--conversation-tool-font-size:calc(12px * var(--hq-chat-scale));--conversation-caption-font-size:12px;--conversation-line-height:21px;--dt-line-height:1.5;--message-text-indent:0px;--turn-block-gap:6px;--scaffold-block-gap:0px;--tool-row-gap:0px;--conversation-scaffold-text:var(--hq-label-2);--disclosure-caret-rest:1;max-width:52rem;padding-inline:12px}
:is([data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container),[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md)){padding:6px 11px;font-size:var(--conversation-text-font-size);line-height:1.333;letter-spacing:-.23px;max-width:80%}
[data-slot='aui_assistant-message-content'] .aui-md > .space-y-4 > *{margin-block:0}
[data-slot='aui_assistant-message-content'] .aui-md > .space-y-4 > * + *{margin-block-start:8px}
html:root body [data-slot='aui_user-message-root']{--human-msg-line-height:1.333}
html:root body [data-slot='aui_user-message-root'] .composer-human-message .sticky-human-clamp{max-height:10lh;-webkit-mask-image:none;mask-image:none}
html:root body [data-slot='aui_user-message-root'] .composer-human-message .sticky-human-clamp[data-clamped='true']{-webkit-mask-image:linear-gradient(#000 calc(100% - 1lh),transparent);mask-image:linear-gradient(#000 calc(100% - 1lh),transparent)}
:is([data-slot='aui_user-message-root'] .composer-human-message:not(.ui-prompt-input__container),[data-slot='aui_assistant-message-content'] .aui-md:not(.aui-md .aui-md,details .aui-md))::after{height:15px}
html:root body [data-slot='aui_user-message-root']{position:relative;top:auto;z-index:auto;padding-top:0;padding-bottom:0}
html:root body [data-sticky-prompt-clip]{clip-path:none}
[data-slot='aui_assistant-message-root']{position:relative;& > :has(> * > [data-slot='aui_msg-actions']){min-height:0;height:0;overflow:visible;position:relative;z-index:2;align-items:flex-start;& > *{position:absolute;top:2px;left:0;width:auto;justify-content:flex-start}
}
&:is(:hover,:focus-within){overflow-clip-margin:44px}
}
[data-slot='aui_msg-actions']{justify-content:flex-start;gap:2px;padding:0 4px;border-radius:999px;background:var(--hq-raised);box-shadow:0 0 0 .5px var(--hq-sep),0 4px 14px rgb(0 0 0/.1);& button{width:24px;height:24px;border-radius:999px;color:var(--hq-label-2)}
& button[aria-label^='Branch']{order:5}
& button svg{width:14px;height:14px}
& time{order:9;margin:0 6px 0 4px;padding:0;font-size:12px;font-variant-numeric:tabular-nums;color:var(--hq-label-2)}
}
[data-slot='aui_message-group']{overflow-clip-margin:12px}
[data-slot='aui_message-group']:has([data-slot='aui_assistant-message-root']:is(:hover,:focus-within)){overflow-clip-margin:44px;position:relative;z-index:3}
[data-slot='aui_thread-content'] > [data-slot='aui_message-group']:nth-child(1 of [data-slot='aui_message-group']){padding-top:12px}
[data-slot='aui_thread-content'] > [data-slot='aui_message-group']:nth-last-child(1 of [data-slot='aui_message-group']) [data-slot='aui_turn-pair']:last-child [data-slot='aui_assistant-message-root']:last-child{& > :has(> * > [data-slot='aui_msg-actions']){height:auto;z-index:auto;& > *{position:static}
}
& [data-slot='aui_msg-actions']{opacity:1;pointer-events:auto;padding:4px 0 0;background:none;box-shadow:none;border-radius:0;gap:2px;margin-left:-5px;& button{width:24px;height:24px}
}
}
[data-slot='aui_thread-content'] [data-slot='tool-block']{grid-template-columns:minmax(0,1fr);margin-block:0;& .grid.size-3\\.5{width:14px;height:14px;color:var(--hq-label-2);& > svg{width:14px !important;height:14px !important;color:inherit}
&:has(> svg path:is([d^='M216,40H40'],[d^='M128,24h0A104'])){& > svg{opacity:0}
&::before{grid-area:1/1;place-self:center;content:'\\ea85';font:normal 14px/1 codicon;color:var(--hq-label-2)}
}
&:has(> svg path[d^='M128,24h0A104'])::before{content:'\\eb01'}
}
& .group\\/disclosure-row .text-\\[0\\.625rem\\]{font-size:12px;color:color-mix(in srgb,var(--hq-ink) 36%,transparent)}
}
[data-slot='aui_thread-content'] :is([data-slot='tool-block'],[data-slot='aui_thinking-disclosure']) + :is([data-slot='tool-block'],[data-slot='aui_thinking-disclosure']){margin-top:-2px}
:is([data-slot='aui_thread-content'] [data-slot='tool-block'],[data-slot='aui_thinking-disclosure']){& .group\\/disclosure-row{min-height:24px;align-items:center;padding-inline:2px;color:var(--hq-label-2);& > button{max-width:none;flex:1 1 auto;min-width:0;align-items:center;gap:8px;& > span{min-width:0}
& > span:last-child:not(:first-child){margin-left:auto}
& > span:first-child > span{gap:8px}
&:disabled{padding-right:22px}
}
& :is(.truncate,.whitespace-nowrap){font-size:var(--conversation-tool-font-size);line-height:18px;letter-spacing:-.08px;color:var(--hq-label-2)}
&:is(:hover,:focus-within):has(> button ~ span:not(:empty)) > button{padding-right:84px}
& > button ~ span{position:absolute;right:22px;top:50%;transform:translateY(-50%);padding:0}
}
& .codicon-chevron-right{font-size:13px !important;color:color-mix(in srgb,var(--hq-ink) 36%,transparent)}
}
[data-slot='aui_thread-content'] :is([data-tool-summary],[data-tool-row]) .group\\/disclosure-row > button > span:first-child > span:not(:has(> .grid))::before{content:'\\eb6d';font:normal 14px/1 codicon;width:14px;flex:none;text-align:center;color:var(--hq-label-2)}
[data-slot='aui_thinking-disclosure'] [role='region']{background:var(--hq-fill-4);border-radius:14px;padding:7px 12px;font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-slot='aui_assistant-message-content'] .aui-md{& > div > * + *{margin-top:11px}
& > div > *{margin-bottom:0}
& :is(ul,ol){margin:11px 0 0;padding-left:28px}
& li{margin:7px 0 0;padding-left:0}
& li:first-child{margin-top:0}
& li > :is(ul,ol){margin-top:7px}
& li > p{margin:0}
& li::marker{color:color-mix(in srgb,var(--hq-ink) 36%,transparent);font-size:14px}
& h1{font-size:21px;line-height:26px;margin:23px 0 7px;font-weight:600;letter-spacing:-0.4px}
& h2{font-size:15px;line-height:20px;margin:21px 0 7px;font-weight:600;letter-spacing:-0.45px}
& :is(h3,h4,h5,h6){font-size:14px;line-height:22px;margin:20px 0 6px;font-weight:600;letter-spacing:-0.44px}
& :is(h1,h2,h3,h4,h5,h6):first-child{margin-top:0}
& :is(h1,h2,h3,h4,h5,h6) + *{margin-top:0}
& a{color:var(--hq-tint-text);text-decoration:none}
& :not(pre) > code{font-size:12px;padding:1px 1.5px;border-radius:5px;background:var(--hq-fill-3);color:inherit;letter-spacing:0}
& blockquote{margin:11px 0 0;padding:0 0 0 12px;border-left:0;font-style:normal;font-weight:inherit;color:inherit;position:relative;quotes:none}
& blockquote::before{content:'';position:absolute;left:0;top:2px;bottom:2px;width:2px;border-radius:1px;background:color-mix(in srgb,var(--hq-ink) 36%,transparent)}
& blockquote p::before,& blockquote p::after{content:none}
& img{box-shadow:none;border-radius:12px}
& :is(pre,table){letter-spacing:0}
& :is(.aui-md-table,:not(.aui-md-table) > table){border:0;border-radius:10px;background:var(--hq-fill-4);box-shadow:none}
& table{border-collapse:collapse;overflow:hidden}
& :is(th,td){font-size:12px;line-height:19px;padding:6px 10px;border:0;letter-spacing:-0.08px}
& th{font-weight:600;color:var(--hq-label-2);background:transparent}
& tr:has(> th){background:var(--hq-fill-4)}
& :is(thead tr,tbody tr){border:0}
& tbody tr + tr{border-top:.5px solid var(--hq-sep)}
}
[data-slot='aui_user-message-root'] .composer-human-message :not(pre) > code{background:rgb(255 255 255/.18);color:inherit;border-radius:5px;padding:1px 1.5px}
html:root body [data-slot='group-chat-message-content']{border-radius:12px;padding:7px 13px;font-size:14px;line-height:20px;letter-spacing:-.23px}
html:root body :has(> [data-slot='group-chat-message-content']) > div:first-child > .text-\\[0\\.7rem\\]{font-size:12px;font-weight:600}
[data-slot='thread-timeline']{opacity:.3;transition:opacity .2s}
[data-slot='thread-timeline']:is(:hover,:focus-within){opacity:1}
[data-slot='aui_thread-content'] .group\\/disclosure-row:not(:hover,:focus-within):not(:has([aria-expanded=true])) .codicon-chevron-right{opacity:0}
/* chrome */
body{--hqc-ink3:rgb(31 35 40/.36);--hqc-rim:0 0 0 .5px rgb(0 0 0/.1);--hqc-lift:0 2px 10px rgb(0 0 0/.07);--hqc-off:#e9e9ea;--composer-shell-pad-block-end:14px}
html:root.dark body{--hqc-ink3:rgb(230 237 243/.36);--hqc-rim:0 0 0 .5px rgb(255 255 255/.18);--hqc-lift:0 2px 12px rgb(0 0 0/.45);--hqc-off:rgb(47 49 55)}
[data-tree-group][data-window-top] > [data-panel-header]:has([data-tree-tab='workspace']){height:38px !important}
[role='tablist']:has([data-tree-tab='workspace']){padding-left:146px;align-items:center;> :first-child{margin-left:auto}
> :last-child{margin-right:auto}
[role='tab']{max-width:min(24rem,66%);&:not([data-vertical]){height:28px;padding-inline:12px;border-radius:14px;margin-block:0}
&[data-closeable][data-active='true']{padding-inline:24px}
&[data-closeable] span:has(> button[aria-label='Close']){align-items:center;padding-right:6px}
&[data-closeable] button[aria-label='Close']{width:16px;height:16px;border-radius:99px;color:var(--hq-label-2);&:hover{background:var(--hq-fill-2);color:var(--foreground)}
.codicon{font-size:10px !important}
}
.pane-tab-content > .ml-2{margin:0}
.pane-tab-content > .ml-2:has([aria-label^='Draft']){margin-left:2px}
.truncate{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.01em;text-transform:none;color:var(--hq-label-2);text-overflow:ellipsis}
.tab-key-hint-icon [aria-label^='Draft']{width:6px;height:6px;border:1px solid var(--hqc-ink3)}
.tab-key-hint-icon [aria-hidden='true']:not([style]){display:none}
&:not([data-active='true']){--tab-bg:transparent;box-shadow:none !important;max-width:min(14rem,30%)}
}
.contents ~ .contents > [role='tab']{margin-left:4px}
[role='tab'][data-active='true']{--tab-bg:var(--hq-raised);box-shadow:var(--hqc-rim),var(--hqc-lift) !important;.truncate{font-size:12px;line-height:16px;font-weight:600;color:var(--foreground)}
}
}
[role='tablist'] button[aria-label='New session tab']{width:28px;height:28px;margin-left:6px;border-radius:99px;background:var(--hq-raised);box-shadow:var(--hqc-rim),var(--hqc-lift);color:var(--foreground);opacity:1 !important;.codicon{font-size:13px !important;color:var(--foreground) !important;opacity:1 !important}
}
[data-titlebar-cluster='right']{top:5px !important;right:12px !important;height:28px;padding-inline:4px;gap:0;border-radius:99px;background:var(--hq-raised);box-shadow:var(--hqc-rim),var(--hqc-lift);> button[data-size='icon-titlebar']{width:30px;height:28px;border-radius:99px;color:var(--foreground);opacity:1;.codicon{font-size:13px !important}
}
}
body:not(:has([data-chat-surface])) [data-titlebar-cluster='right']{background:none;box-shadow:none}
:root:has([data-overlay-surface]) :is([role='tab'][data-closeable],[data-titlebar-cluster='right'],[aria-label='New session tab']){box-shadow:none !important}
[data-chat-surface] [data-slot='aui_thread-viewport']{mask-image:linear-gradient(to bottom,transparent 8px,#0003 18px,#000 30px)}
[data-chat-surface] [data-slot='composer-dock']:not([data-popped-out])::before{content:'';position:absolute;inset:-20px -24px 0;z-index:-1;pointer-events:none;background:linear-gradient(to bottom,transparent,var(--hq-page) 20px)}
[data-chat-surface] [data-slot='aui_thread-content']{padding-top:20px;> [data-slot='aui_composer-clearance']{order:1}
}
[data-chat-surface] .thread-timeline-tick{[data-slot='timeline-bar']{height:2px;width:10px;background:var(--hqc-ink3);opacity:1}
&[aria-current] [data-slot='timeline-bar']{background:var(--hq-tint);width:14px}
}
html:root body [data-slot='composer-root']{--composer-control-gap:6px;--composer-surface-pad-x:0px;--composer-surface-pad-y:0px;--composer-input-min-height:22px;--composer-fill:transparent;padding-inline:20px}
html:root body [data-slot='composer-surface']{overflow:visible;border-radius:17px;box-shadow:none !important}
[data-slot='composer-surface'] > :first-child:not([data-slot]){left:40px;right:40px;inset-block:0;border-radius:17px;background:var(--hq-raised) !important;box-shadow:var(--hqc-rim),var(--hqc-lift)}
[data-slot='composer-surface']:focus-within > :first-child:not([data-slot]){box-shadow:0 0 0 1px var(--hq-sep),var(--hqc-lift)}
[data-slot='composer-fade']{overflow:visible;min-height:28px;opacity:1 !important;> div{min-height:28px;align-items:end;> div:first-child{translate:0 0;align-self:end}
> div:has([data-slot='composer-rich-input']){padding:4px 0 4px 14px;align-self:center}
> div:last-child{align-self:center;height:34px}
}
}
[data-slot='composer-surface']{button[aria-label='Add context']{width:34px;height:34px;border-radius:99px;background:var(--hq-raised);box-shadow:var(--hqc-rim),var(--hqc-lift);color:var(--hq-label-2);.codicon{font-size:14px !important}
}
:is([data-tour='model-pill'],[data-testid='reasoning-pill']){height:28px;padding-inline:6px;gap:3px;border-radius:99px;font-size:12px;color:var(--hq-label-2);background:transparent;&:is(:hover,[data-state='open']){background:var(--hq-fill-4)}
svg{opacity:1;color:var(--hqc-ink3)}
}
button[aria-label='Voice dictation']{width:28px;height:28px;border-radius:99px;color:var(--hq-label-2);.codicon{font-size:14px !important}
}
[data-slot='fan-menu-anchor'] > i{opacity:0}
button[aria-label='Voice chat engine']{order:-1;width:14px;height:32px;min-width:0;margin:0 14px 0 -10px;padding:0;border-radius:99px;background:transparent !important;color:var(--hqc-ink3);:is(svg,.codicon){width:10px;height:10px;font-size:10px !important}
}
button[data-variant='default'][data-size='icon']{width:34px;height:34px;margin:0;border-radius:99px;background:var(--hq-tint) !important;color:#fff !important;svg{width:15px;height:15px;stroke-width:2.4}
&:disabled{background:var(--hqc-off) !important;color:var(--hqc-ink3) !important;opacity:1}
}
}
[data-slot='composer-rich-input']{font-size:13px !important;line-height:18px !important}
[data-slot='composer-rich-input'][data-empty]::before{color:var(--hqc-ink3) !important}
[data-slot='composer-status-stack']{padding-top:10px;> div{margin:0 60px 10px;padding:4px 0;border:0;border-radius:14px;background:var(--hq-raised);box-shadow:var(--hqc-rim),var(--hqc-lift);backdrop-filter:none;-webkit-backdrop-filter:none}
.status-row{margin-inline:4px;padding-block:4px;border-radius:8px;.status-row-content > span{font-size:12px;line-height:16px}
}
.status-row:has(> .status-row-icon :is(.codicon-graph,.codicon-account)){row-gap:8px;padding-block:6px;background:none;.status-row-content > span{white-space:normal;overflow:visible;text-overflow:clip}
.status-row-actions{grid-column:3 / 5;grid-row:2;gap:6px;flex-wrap:wrap}
.status-row-actions > button{margin:0;height:24px;padding:0 10px;border-radius:99px;background:var(--hq-fill-3);color:var(--foreground) !important;font-size:12px;text-decoration:none;&:hover{background:var(--hq-fill-2)}
}
.status-row-actions > button:last-child{margin-left:auto;padding:0 4px;background:none;color:var(--hq-tint-text) !important}
}
}
[data-slot='composer-root'][data-status-stack] .status-drawer-toggle{top:-10px;height:10px}
.thread-jump-button{width:36px;height:32px;padding:0;gap:0;justify-content:center;border-radius:99px !important;-webkit-backdrop-filter:none !important;backdrop-filter:none !important;background:var(--hq-raised) !important;border:0 !important;box-shadow:var(--hqc-rim),var(--hqc-lift);color:var(--hq-label-2);> span{display:none}
.codicon{font-size:13px !important}
}
[data-slot='aui_intro']{translate:0 -20px}
:is([data-slot='aui_intro'],[data-slot='bot_chat_empty']){.wordmark{display:block !important;width:auto !important;margin:0 auto 6px !important;text-align:center;color:var(--foreground) !important;mix-blend-mode:normal !important;&,*{font:400 18px/24px -apple-system,system-ui,sans-serif !important;letter-spacing:0 !important;text-transform:none !important}
span:not([aria-hidden]){display:block !important}
> [aria-hidden='true']{display:none}
}
p.m-0{font-size:12px;line-height:16px;letter-spacing:0;color:var(--hq-label-2);max-width:30rem;margin-inline:auto;text-wrap:balance}
}
[data-slot='aui_intro'] .wordmark,[data-slot='aui_intro'] .wordmark *{text-transform:lowercase !important}
[data-slot='aui_intro'] .wordmark span:not(:has(span))::first-letter{text-transform:uppercase !important}
[data-slot='bot_chat_empty'] > div > :first-child{margin-bottom:10px !important;> *{width:80px !important;height:80px !important}
svg{width:100%;height:100%}
}
/* sidebar */
[role='tablist']:has(> [data-tree-tab='sessions']){flex:1 1 auto;width:auto;min-width:0;height:28px;box-sizing:border-box;margin:auto 16px;padding:2px;gap:0;border-radius:999px;background:var(--hq-fill-3);overflow:visible;& + button[aria-label='Minimize']{display:none}
> [data-tree-tab]{flex:1 1 0;min-width:84px;height:24px;margin:0;justify-content:center;font-size:12px;color:var(--foreground);.pane-tab-content{justify-content:center}
.truncate{font-weight:inherit;letter-spacing:-.08px}
&[data-active='true']{--tab-bg:var(--hq-raised);box-shadow:0 3px 8px rgb(0 0 0/.12),0 3px 1px rgb(0 0 0/.04),0 0 0 .5px rgb(0 0 0/.04);font-weight:600;:root.dark &{--tab-bg:#5c5c60;box-shadow:inset 0 .5px 0 rgb(255 255 255/.14),0 1px 3px rgb(0 0 0/.3)}
}
}
}
:is([data-slot='sidebar'],:has(> [data-slot='bots-roster'])){--hq-label-2:rgb(60 60 67/.6);--ui-text-tertiary:var(--hq-label-2)}
html.dark :is([data-slot='sidebar'],:has(> [data-slot='bots-roster'])){--hq-label-2:rgb(235 235 245/.6)}
:root:root:root :is([data-slot='sidebar'],[data-slot='bots-roster']){--ui-row-active-background:color-mix(in srgb,var(--hq-tint) 11%,transparent)}
:root.dark:root:root :is([data-slot='sidebar'],[data-slot='bots-roster']){--ui-row-active-background:color-mix(in srgb,var(--hq-tint) 22%,transparent)}
@keyframes hq-unfade{0%{-webkit-mask-image:var(--hq-fade-mask);mask-image:var(--hq-fade-mask)}
1%,97%{-webkit-mask-image:var(--hq-fade-mid);mask-image:var(--hq-fade-mid)}
100%{-webkit-mask-image:var(--hq-fade-end);mask-image:var(--hq-fade-end)}
}
:is([data-slot='sidebar'] [data-slot='sidebar-content'] > .overflow-y-auto,:has(> [data-slot='bots-roster'])){--hq-fade-mask:linear-gradient(#000 calc(100% - 28px),transparent);--hq-fade-mid:linear-gradient(transparent,#000 14px,#000 calc(100% - 28px),transparent);--hq-fade-end:linear-gradient(transparent,#000 14px);-webkit-mask-image:var(--hq-fade-mask);mask-image:var(--hq-fade-mask);animation-name:hq-unfade;animation-duration:auto;animation-timing-function:linear;animation-fill-mode:both;animation-timeline:scroll(self block)}
[data-slot='sidebar'] [data-slot='sidebar-content'] > .overflow-y-auto{margin-right:-8px}
[data-titlebar-cluster='left']{> button{width:28px;height:28px;translate:0 -2px;border-radius:999px;color:var(--hq-label-2);background:none;box-shadow:none;&:hover{background:var(--hq-fill-3);color:var(--foreground)}
}
> button .codicon{font-size:15px !important}
[data-slot='badge']{height:15px;min-width:15px;padding:0 4px;justify-content:center;border-radius:999px;background:#ff3b30;color:#fff;font-size:10.5px;line-height:15px;font-weight:600;:root.dark &{background:#ff453a}
}
.absolute:has(> [data-slot='badge']){top:-4px;right:-9px}
}
:is([data-slot='sidebar'],:has(> [data-slot='bots-roster'])){anchor-name:--hq-side}
[data-titlebar-cluster='left']:has(> button[aria-label^='Hide sidebar']){position-anchor:--hq-side;position-visibility:always;left:calc(anchor(right,calc(var(--titlebar-controls-left) + 44px)) - 44px)}
[data-slot='sidebar'] [data-slot='sidebar-content'] > [data-sidebar='group']:first-child{container-type:inline-size;flex-direction:row;align-items:center;gap:8px;padding:12px 6px 2px;> [data-sidebar='group-content']{width:auto;flex:none;margin-left:auto}
&::before{content:'Sessions' / '';flex:1 1 auto;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;font-size:20px;line-height:26px;font-weight:700;letter-spacing:-.2px;color:var(--foreground)}
}
[data-slot='sidebar'] [data-sidebar='menu']{flex-direction:row;gap:0;width:auto;height:28px;align-items:center;padding:0 3px}
[data-slot='sidebar'] [data-sidebar='menu-button']{position:relative;flex:none;width:26px;height:24px;padding:0;justify-content:center;border:0 !important;border-radius:999px;color:var(--foreground);> i.codicon{width:17px;height:17px;font-size:15px !important;line-height:17px;color:var(--foreground) !important}
> :is(span.truncate,[data-slot='kbd-group']){position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
> .codicon-robot::before{content:'\\ea73'}
> .codicon-symbol-misc::before{content:'\\eae6'}
> .codicon-comment::before{content:'\\eac7'}
}
[data-slot='sidebar'] [data-sidebar='menu'] > :has(.codicon-robot){order:3}
[data-slot='sidebar'] [data-sidebar='menu-button'][class~='bg-(--ui-control-active-background)'] > i.codicon{color:var(--hq-tint) !important}
:is([data-slot='sidebar'] [data-sidebar='menu'],:has(> [data-slot='bots-roster']) > .justify-between:first-child > .flex){gap:2px;border-radius:0;background:none;box-shadow:none}
[data-slot='sidebar'] [data-sidebar='menu-button']{> i.codicon{color:var(--hq-label-2) !important}
&:hover{background:var(--hq-fill-3)}
&:hover > i.codicon{color:var(--foreground) !important}
}
:has(> [data-slot='bots-roster']) > :is(.justify-between:first-child > .flex > button,:nth-child(2) > button[aria-label='Filter roster']){color:var(--hq-label-2) !important;&:hover{background:var(--hq-fill-3);color:var(--foreground) !important}
}
:is([data-slot='sidebar'],:has(> [data-slot='bots-roster'])) .border-b:has(> input[placeholder]){height:32px;padding:0 6px 0 10px;gap:6px;border-radius:999px;background:var(--hq-fill-3);> input{font-size:13px;letter-spacing:-.08px;text-overflow:ellipsis}
> input::placeholder{color:var(--hq-label-2);opacity:.8;text-overflow:ellipsis}
> svg{width:15px;height:15px;color:var(--hq-label-2)}
}
[data-slot='sidebar'] [data-slot='sidebar-content'] > .shrink-0.px-2:has(input){margin-right:6px;padding:2px 0 4px 6px}
[data-slot='sidebar']{.group\\/section{min-height:26px;padding:6px 7px 0 0}
[data-sidebar='group']{padding-bottom:0}
[data-sidebar='group-content']{padding-block:0}
.group\\/section button[data-size='icon-xs']{width:28px;height:28px;border-radius:999px;color:var(--hq-label-2);.codicon{font-size:14px !important}
}
[data-slot='sidebar-group-content']{gap:0}
}
button.group\\/section-label > span.tracking-\\[0\\.16em\\]{padding-left:10px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px}
button.group\\/section-label:has(> span.size-4){gap:0}
button.group\\/section-label > span.size-4.rounded-\\[4px\\]{width:0;min-width:0;overflow:hidden;margin:0;background:transparent !important}
.group\\/workspace{min-height:26px;padding:8px 8px 0 28px}
.group\\/workspace .tracking-\\[0\\.12em\\]{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;opacity:1;color:var(--hq-label-2)}
.group\\/workspace span.h-px.flex-1{background:transparent}
[data-slot='sidebar'] .hover-marquee .hover-marquee-inner{display:inline;animation:none !important;transform:none !important}
[data-slot='sidebar'] .row-hover{min-height:28px;padding-right:10px;border-radius:10px;> div:first-child{padding-right:6px}
.hover-marquee{font-size:13px !important;line-height:18px;letter-spacing:-.08px;color:var(--foreground);text-overflow:ellipsis}
span.size-1.rounded-full{opacity:0}
[aria-label$='unread']{width:8px;height:8px;background:var(--hq-tint)}
:is([aria-label='Needs your input'],[aria-label='Waiting for your answer']){width:8px;height:8px;background:#ff9500;:root.dark &{background:#ff9f0a}
}
[aria-label^='Draft']{width:8px;height:8px;border:1.5px dashed var(--hq-label-2);opacity:.5}
[data-row-actions] .text-\\[0\\.625rem\\]{font-size:12px;line-height:16px;letter-spacing:-.08px;font-variant-numeric:tabular-nums;color:var(--hq-label-2)}
&:has([aria-label$='unread']){.hover-marquee{font-weight:600}
[data-row-actions] .text-\\[0\\.625rem\\]{color:var(--hq-tint-text)}
}
[aria-label^='Profile:']{width:16px;height:16px;margin-right:2px;border-radius:50%;font-size:9px;background:var(--hq-fill-3) !important;color:var(--hq-label-2) !important}
.codicon-kebab-vertical::before{content:'\\ea7c'}
&:hover button[aria-label='Session actions']{color:var(--hq-label-2)}
button[aria-label='Session actions'] .codicon{font-size:14px !important}
}
[data-slot='sidebar'] [data-sidebar='group-content'] > button[aria-label^='Load']{display:inline-flex;align-items:center;align-self:flex-start;margin:4px 0 6px 20px;width:auto;height:28px;padding:0 12px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-tint-text);.codicon{display:none}
&::after{content:attr(aria-label);font-size:13px;line-height:18px;letter-spacing:-.08px;white-space:nowrap}
}
[data-slot='sidebar-content'] > .overflow-y-auto:not(:has([data-index])) > [data-sidebar='group']{flex:none;min-height:0;overflow:visible;> [data-sidebar='group-content']{flex:none;max-height:none;overflow:visible}
}
[data-slot='sidebar-content'] > .overflow-y-auto > :nth-child(n+3) .group\\/section{padding-top:12px}
[data-slot='sidebar'] [data-slot='sidebar-content'] > .shrink-0:has(> [data-slot='profile-rail']){margin:0 -10px;padding:8px 12px 8px 14px;box-shadow:0 -.5px 0 var(--hq-sep)}
[data-slot='profile-rail']{flex-wrap:wrap;row-gap:4px;column-gap:10px;> .overflow-x-auto{order:-1;flex:1 0 100%;height:32px;padding-right:14px;--hq-fade-mask:linear-gradient(to right,#000 calc(100% - 36px),transparent);--hq-fade-mid:linear-gradient(to right,transparent,#000 24px,#000 calc(100% - 36px),transparent);--hq-fade-end:linear-gradient(to right,transparent,#000 24px);-webkit-mask-image:var(--hq-fade-mask);mask-image:var(--hq-fade-mask);animation-name:hq-unfade;animation-duration:auto;animation-timing-function:linear;animation-fill-mode:both;animation-timeline:scroll(self inline)}
> .overflow-x-auto > div{gap:4px}
> button:first-child{margin-right:auto}
:is([data-slot='profile-rail-gateway'],[data-slot='profile-rail-gateway'] > .relative){gap:6px}
[data-slot='profile-rail-divider']{margin:0 2px;gap:2px}
[data-slot='profile-rail-divider'] > .w-px{width:0;background:transparent}
> .overflow-x-auto > div > [data-slot='profile-rail-divider']:not(:first-child){margin-left:8px}
:is(button[data-size='icon-xs'],button.size-5:not([data-slot='popover-anchor'])){width:28px;height:28px;border-radius:999px;opacity:1;color:var(--hq-label-2);&:hover{background:var(--hq-fill-3);color:var(--foreground)}
}
button[aria-pressed='true']:not([data-slot='popover-anchor']){background:transparent;color:var(--hq-tint)}
.codicon{font-size:16px !important}
> .overflow-x-auto button[data-size='icon-xs']{width:28px;height:28px;color:var(--hq-label-2)}
> .overflow-x-auto .codicon{font-size:16px !important}
[data-slot='connection-glyph']{width:15px;height:15px;color:var(--hq-label-3)}
.codicon-cloud-download::before{content:'\\ebfc'}
[data-slot='connection-glyph'] svg{width:13px;height:13px}
[data-slot='profile-rail-unreachable']{width:6px;height:6px;background:#ff9500;:root.dark &{background:#ff9f0a}
}
button[data-slot='popover-anchor']{width:24px;height:24px;border-radius:50%;font-size:12px;font-weight:600;opacity:1}
button[data-slot='popover-anchor'][aria-pressed='true']{box-shadow:0 0 0 2px var(--hq-tint)}
[data-slot='profile-status-dot']{display:block;width:5px;height:5px;background:var(--hq-tint);box-shadow:0 0 0 1.5px var(--background)}
button > span.absolute:has(> [data-slot='profile-status-dot']){top:-1px;right:-1px;bottom:auto;line-height:0}
button[data-size='icon-xs'] > span.absolute:has(> [data-slot='profile-status-dot']){top:5px;right:5px}
}
:has(> [data-slot='bots-roster']){position:relative;> .justify-between:first-child{container-type:inline-size;gap:8px;padding:12px 16px 2px;> span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:20px;color:var(--foreground);text-transform:none;line-height:26px;font-weight:700;letter-spacing:-.2px}
> .flex{anchor-name:--hq-bots-tools;flex:none;gap:0;height:28px;align-items:center;padding:0 3px 0 29px}
> .flex > button{width:26px;height:24px;border-radius:999px;color:var(--foreground)}
> .flex .codicon{font-size:15px !important}
}
> :nth-child(2){gap:0;padding:2px 16px 4px;> button[aria-label='Filter roster']{position:absolute;top:anchor(--hq-bots-tools top,13px);left:anchor(--hq-bots-tools left,calc(100% - 100px));margin:2px 0 0 3px;width:26px !important;height:24px !important;border-radius:999px;color:var(--foreground);.codicon{font-size:15px !important}
}
}
}
[data-slot='bots-roster']{[data-slot='bots-section-heading'] > .group\\/section{position:relative;margin-top:2px;padding-right:0;> button[aria-haspopup]{position:absolute;right:30px}
}
:is([data-slot='bots-section-heading'] button,[data-slot='bots-section'] > button).tracking-wider,> div > .border-t > button{min-height:30px;padding:0 10px 0 14px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;color:var(--hq-label-2)}
[data-slot='bots-section'] > button.tracking-wider{margin-top:2px}
> div > .border-t:has(> button[aria-expanded]){margin-top:2px;border-top-width:0;> button{gap:6px;font-weight:400;> span:last-child{color:inherit}
> .codicon{order:1}
}
}
:is(button.tracking-wider,.border-t > button) > .codicon-chevron-right{font-size:12px !important;opacity:1;color:rgb(60 60 67/.36);:root.dark &{color:rgb(235 235 245/.36)}
}
button.tracking-wider:not([data-slot='row-button']):has(> [data-slot='connection-glyph']){margin-top:2px;padding:4px 10px 4px 14px;font-size:12px;line-height:16px;font-weight:400;> [data-slot='connection-glyph']{display:grid;color:inherit}
}
button[data-slot='context-menu-trigger']{gap:10px;min-height:48px;padding:5px 10px;img{width:34px !important;height:34px !important}
> .shrink-0:has(> svg),> .shrink-0 > svg,:is(.size-8,.w-\\[34px\\]){width:34px;height:34px}
.font-medium{font-size:13px;line-height:18px;letter-spacing:-.08px}
.items-baseline > .shrink-0{font-size:12px;line-height:16px;letter-spacing:0;font-variant-numeric:tabular-nums;color:var(--hq-label-2)}
.text-xs{margin-top:0;font-size:12px;line-height:15px;letter-spacing:-.08px}
}
[data-roster-key]{& + &::before{left:52px;right:0;border-top-width:.5px}
[role='status']{width:12px;height:12px}
span.size-3\\.5:has([role='status']){right:10px;bottom:auto;top:26px}
}
}
[data-slot='bots-section']:has([data-section-id='hermes-hq-pinned']){> .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(72px,1fr));gap:2px;padding:2px 0 0}
[data-roster-key]{flex-direction:column;align-items:center;gap:4px;min-height:0;padding:4px 2px 6px;border-radius:var(--hq-card-r);background:transparent !important;&::before{display:none}
img,> .shrink-0:has(> svg),> .shrink-0 > svg{width:40px !important;height:40px !important;border-radius:50%}
:root.dark & img{filter:drop-shadow(0 0 .5px rgb(255 255 255/.5))}
> .min-w-0{flex:none;width:100%;text-align:center}
.items-baseline{justify-content:center}
.items-baseline > .min-w-0{justify-content:center;max-width:100%}
.font-medium{font-size:12px;line-height:16px;font-weight:500;letter-spacing:-.08px}
:is(.items-baseline > .shrink-0,.text-xs){display:none}
span.size-3\\.5:has([role='status']){top:4px;right:calc(50% - 30px)}
&[class~='bg-(--ui-row-active-background)'] .font-medium{color:var(--hq-tint-text);font-weight:600}
}
}
/* overlays */
:is([data-slot*=menu-][data-slot$=content],[data-slot=select-content],[data-slot=popover-content]){-webkit-backdrop-filter:none;backdrop-filter:none;html.dark body:has([data-overlay-surface]) &{background:#3a3a3c}
}
:is([data-slot=context-menu-content],[data-slot=dropdown-menu-content]){min-width:180px}
:is([data-slot^=context-menu-],[data-slot^=dropdown-menu-])[role^=menuitem],[data-slot=select-item]{min-height:24px;padding-block:0;padding-inline:8px;gap:8px;font-size:12px;line-height:16px;letter-spacing:-.08px}
:is([data-slot^=context-menu-],[data-slot^=dropdown-menu-])[role^=menuitem] > :is(i.codicon,svg):first-child{width:16px;height:16px;font-size:13px!important;line-height:16px;text-align:center;flex:none;color:currentColor}
:is([data-slot^=context-menu-],[data-slot^=dropdown-menu-])[role=menuitem] > svg:first-child{padding:1px;stroke-width:1.9}
:is([data-slot^=context-menu-],[data-slot^=dropdown-menu-])[role^=menuitem] > i.codicon:first-child{-webkit-text-stroke:.3px currentColor}
[role=menuitem][data-variant=destructive]{&,& *{color:#ff3b30!important}
html.dark &,html.dark & *{color:#ff453a!important}
}
:is([data-slot=context-menu-separator],[data-slot=dropdown-menu-separator],[data-slot=select-separator]){height:.5px;margin:4px 8px}
:is([data-slot=context-menu-sub-trigger],[data-slot=dropdown-menu-sub-trigger]) > .codicon-chevron-right{font-size:13px!important;color:var(--foreground);opacity:.8;font-weight:600}
:is([data-slot=dropdown-menu-label],[data-slot=context-menu-label],[data-slot=select-label]){padding:6px 10px 2px;font-size:11px;font-weight:500;line-height:14px;letter-spacing:0;color:var(--hq-label-2)}
:is([data-slot=dropdown-menu-shortcut],[data-slot=context-menu-shortcut]){font-size:12px;letter-spacing:.02em;color:var(--hq-label-2)}
:is([data-slot*=menu-][data-slot$=content],[data-slot=select-content]) .codicon-check{color:var(--hq-tint-text);font-size:12px!important;font-weight:600}
[data-slot*=menu-][data-slot$=content] [data-slot=badge]{height:18px;padding:0 7px;border:0;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-label-2);font-size:12px;font-weight:500;letter-spacing:0}
[data-slot=dropdown-menu-content][data-side=top]{translate:0 -8px}
[data-slot=dropdown-menu-content][data-side=top]:not(.w-72){width:max-content;& [role^=menuitem]{min-height:28px;padding-block:4px}
& [data-slot=dropdown-menu-label]{padding-top:6px}
& [data-slot=dropdown-menu-separator]{margin-block:4px}
& > div:not([data-slot]):last-child{padding:4px 14px 6px;font-size:12px;line-height:16px;white-space:nowrap}
}
[data-slot=dropdown-menu-content][data-side=bottom]{translate:0 4px}
[data-slot=dropdown-menu-search]{position:relative;padding:4px 0 6px}
[data-slot=dropdown-menu-search]::before{content:'\\ea6d';position:absolute;left:14px;top:4px;width:20px;font:14px/36px codicon;text-align:center;color:var(--hq-label-2);pointer-events:none}
[data-slot=dropdown-menu-search] input{height:28px;padding:0 12px 0 40px;border-radius:999px;background:var(--hq-fill-3);font-size:12px;line-height:18px;letter-spacing:-.02em}
[data-slot=dropdown-menu-search] + [data-slot=dropdown-menu-separator]{background:transparent;margin:0}
[data-slot=dropdown-menu-content].w-72{width:300px;max-height:min(540px,calc(var(--radix-dropdown-menu-content-available-height) - 16px))}
[data-slot=dropdown-menu-content].w-72{& [data-slot=dropdown-menu-search] ~ div.overflow-y-auto{max-height:max(160px,min(248px,30dvh,calc(var(--radix-dropdown-menu-content-available-height) - 260px)))}
& :is([data-slot=dropdown-menu-sub-trigger],[data-slot=dropdown-menu-item]){min-height:24px;padding-inline:8px;gap:8px}
& [data-slot=dropdown-menu-sub-trigger] > button[data-slot=tooltip-trigger]{width:24px;height:24px;flex:none;color:var(--hq-label-2)}
& [data-slot=dropdown-menu-sub-trigger] > button[data-slot=tooltip-trigger] .codicon{font-size:13px!important}
& [data-slot=dropdown-menu-sub-trigger] > button[aria-pressed=false]{opacity:0}
& [data-slot=dropdown-menu-sub-trigger]:is(:hover,[data-highlighted]) > button[aria-pressed=false]{opacity:.6}
& [data-slot=dropdown-menu-search] ~ div.overflow-y-auto{scroll-padding-block:12px;-webkit-mask-image:linear-gradient(transparent,#000 10px,#000 calc(100% - 14px),transparent);mask-image:linear-gradient(transparent,#000 10px,#000 calc(100% - 14px),transparent);padding-block:4px 8px}
& [data-slot=dropdown-menu-sub-trigger] > button[aria-pressed=true]{color:var(--hq-tint-text)}
& [data-slot=dropdown-menu-sub-trigger] > .codicon-chevron-right{font-size:12px!important;color:var(--hq-label-2);opacity:1}
& [data-slot=dropdown-menu-search]{padding-inline:6px;&::before{left:10px}
& input{padding-left:36px}
}
& [data-slot=dropdown-menu-item]:not(.group\\/label):not(:has(> svg,> i.codicon,> button,> span > svg)){padding-inline-start:32px}
& [data-slot=dropdown-menu-sub-trigger]:has(.codicon-check):not([data-highlighted],[data-state=open],:hover){background:transparent}
}
[data-slot=dropdown-menu-content] [data-slot=dropdown-menu-item].group\\/label{min-height:0;padding:8px 10px 2px;font-size:11px;font-weight:500;line-height:14px;letter-spacing:0;color:var(--hq-label-2);background:none}
[data-slot=dropdown-menu-content] [data-slot=dropdown-menu-item].group\\/label [data-slot=tooltip-trigger]{font-size:12px}
[data-slot=dropdown-menu-content] [data-slot=dropdown-menu-item][class~='text-(--ui-text-tertiary)'],[data-slot=dropdown-menu-content] [data-slot=dropdown-menu-item][class~='text-(--ui-text-tertiary)'] > *{color:var(--hq-tint-text)}
[data-slot=select-content]{min-width:max(240px,var(--radix-select-trigger-width));max-height:min(27rem,var(--radix-select-content-available-height))}
:is([data-slot=select-content],[data-slot=popover-content]:has(> [data-slot=command]))[data-side=bottom]{translate:0 4px}
[data-slot=select-item]{padding-inline:36px 16px}
[data-slot=select-item] > span.absolute{left:10px;right:auto;top:50%;width:20px;height:20px;translate:0 -50%}
[data-slot=select-item] > span.absolute .codicon{display:block;line-height:18px}
[data-slot=popover-content]:has(> [data-slot=command]){width:max(var(--radix-popover-trigger-width),260px);max-width:300px;max-height:var(--radix-popover-content-available-height);padding:6px;& [cmdk-root]{border-radius:0}
}
[data-slot=popover-content] [data-slot=command-input-wrapper]{height:auto;margin:0 0 6px;padding:0 12px;gap:8px;border:0;border-radius:999px;background:var(--hq-fill-3)}
[data-slot=popover-content] [data-slot=command-input]{height:28px;padding:0;font-size:12px;line-height:16px;letter-spacing:-.08px}
[data-slot=popover-content] [data-slot=command-item]{min-height:24px;padding-inline:8px;gap:8px;font-size:12px;line-height:16px;letter-spacing:-.08px}
[data-slot=popover-content] [data-slot=command-item] svg{color:var(--hq-tint-text)}
[data-slot=popover-content] [data-slot=command-item][data-selected=true]{background:color-mix(in srgb,currentColor 6%,transparent)}
[data-slot=command-input-wrapper]:not(:has(> svg))::before{content:'\\ea6d';font:16px/1 codicon;color:var(--hq-label-2);flex:none}
[role=dialog]:not([data-slot]):has(> [data-slot=command]){--hq-grouped:#f2f2f7;--hq-cell:#fff;background:var(--hq-grouped);top:56px;border:0;border-radius:var(--hq-card-r);box-shadow:var(--hq-menu-shadow)}
html.dark [role=dialog]:not([data-slot]):has(> [data-slot=command]){--hq-grouped:#1c1c1e;--hq-cell:#2c2c2e}
[role=dialog]:not([data-slot]) > [data-slot=command]{background:var(--hq-grouped);border-radius:var(--hq-card-r);& > [data-slot=command-input-wrapper]{height:auto;margin:10px 10px 2px;padding:0 10px;gap:7px;border:0;border-radius:999px;background:var(--hq-cell)}
& [data-slot=command-input]{height:30px;padding:0;font-size:13px;line-height:18px;letter-spacing:-.15px;background:transparent}
& > [data-slot=command-input-wrapper] > svg{width:15px;height:15px;color:var(--hq-label-2)}
& [data-slot=command-list]{max-height:min(37rem,70vh);padding:0 10px 14px;scroll-padding-block:32px 14px;-webkit-mask-image:linear-gradient(#000 calc(100% - 12px),transparent);mask-image:linear-gradient(#000 calc(100% - 24px),transparent)}
& [data-slot=command-group]{padding:0}
& [cmdk-group-heading]{position:static;padding:10px 12px 4px;font-size:11px;line-height:14px;font-weight:500;background:transparent}
& [cmdk-group-items]{padding:0;overflow:hidden;border-radius:var(--hq-card-r);background:var(--hq-cell)}
& [data-slot=command-item]{position:relative;min-height:26px;padding-inline:10px;gap:8px;font-size:12px;line-height:16px;letter-spacing:-.08px;border-radius:0}
& [data-slot=command-item][data-selected=true]{background:#e5e5ea;color:var(--foreground)}
html.dark & [data-slot=command-item][data-selected=true]{background:var(--hq-fill-3)}
& [data-slot=command-item] > svg:first-child{width:16px;height:16px;color:var(--foreground);opacity:.85;stroke-width:1.8}
& [data-slot=command-item] > i.codicon:first-child{width:16px;height:16px;font-size:13px!important;line-height:16px;text-align:center;color:var(--foreground);opacity:.85}
}
[data-slot=command-item] [data-slot=kbd-group]{gap:0;opacity:1}
[data-slot=command-item] [data-slot=kbd-group] > kbd{width:auto;min-width:0;height:auto;padding:0;border:0;background:none;box-shadow:none;font:400 12px/16px -apple-system,system-ui,sans-serif;color:var(--hq-label-2)}
body > .fixed.inset-0[data-state=open]:has(+ [role=dialog]:not([data-slot]) > [data-slot=command]){background:rgb(0 0 0/.2)}
html.dark body > .fixed.inset-0[data-state=open]:has(+ [role=dialog]:not([data-slot]) > [data-slot=command]){background:rgb(0 0 0/.48)}
[data-slot=dialog-content].max-w-md:has(> .grid > [data-slot=dialog-footer]):not(:has(label,textarea,select,[role=combobox],[role=radiogroup],[role=switch],> .grid > :nth-child(5))){max-width:360px;border-radius:var(--hq-card-r);& > .grid{gap:16px;padding:22px 16px 16px}
& [data-slot=dialog-header]{gap:4px;padding:0 44px 0 14px;text-align:left}
& [data-slot=dialog-title]{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.02em}
& [data-slot=dialog-description]{font-size:12px;line-height:16px;letter-spacing:-.01em;color:var(--hq-label-2)}
& [data-slot=input]{height:36px;padding:0 16px;border:0;border-radius:999px;font-size:13px;line-height:18px;letter-spacing:-.02em}
& [data-slot=dialog-footer]{display:grid;grid-auto-flow:column;grid-auto-columns:1fr;gap:10px}
&:has(> .grid > [data-slot=dialog-footer] > :nth-child(3)) [data-slot=dialog-footer]{display:flex;flex-direction:column-reverse}
& [data-slot=dialog-footer] [data-slot=button]{height:38px;padding:0 16px;border:0;border-radius:999px;font-size:13px;line-height:18px;letter-spacing:-.02em;font-weight:400;box-shadow:none}
& [data-slot=dialog-footer] [data-slot=button]:is([data-variant=ghost],[data-variant=outline],[data-variant=secondary]){background:var(--hq-fill-3);color:var(--foreground)}
& [data-slot=dialog-footer] [data-slot=button]:is([data-variant=default],[data-variant=destructive]){font-weight:600}
& [data-slot=dialog-footer] [data-slot=button][data-variant=destructive]{background:#ff3b30;color:#fff}
html.dark & [data-slot=dialog-footer] [data-slot=button][data-variant=destructive]{background:#ff453a}
& [data-slot=dialog-close-button]{top:16px;right:16px;width:26px;height:26px;opacity:.75}
& [data-slot=dialog-close-button] svg{width:11px;height:11px}
}
[data-slot=dialog-close-button] svg{width:13px;height:13px;stroke-width:2.6}
[data-slot=tooltip-content]{padding:5px 10px;max-width:min(320px,calc(100vw - 16px));border-radius:14px;background:var(--hq-raised);color:var(--foreground);font-size:12px;font-weight:400;line-height:16px;letter-spacing:0;box-shadow:var(--hq-menu-shadow)}
html.dark [data-slot=tooltip-content]{background:#3a3a3c}
[data-slot=tooltip-content] [data-slot=tooltip-arrow]{visibility:hidden}
[data-slot=tooltip-content][data-side=bottom]{translate:0 9px}
[data-slot=tooltip-content][data-side=top]{translate:0 -9px}
[data-slot=tooltip-content] [data-slot=tooltip-label] > .opacity-55{margin-inline-start:6px;opacity:1;color:var(--hq-label-2)}
[role=region].left-1\\/2:has(> [data-slot=card-stack]){width:min(40rem,calc(100% - 2rem))!important;transform:none!important}
[role=region].right-4 > [data-slot=card-stack] [data-slot=card-stack-surface]{margin-inline:auto 0}
[role=region] > [data-slot=card-stack]{& [data-slot=card-stack-surface]{width:fit-content;max-width:100%;margin-inline:auto;border:0;border-radius:var(--hq-card-r);background:var(--hq-raised);box-shadow:var(--hq-menu-shadow);-webkit-backdrop-filter:none;backdrop-filter:none}
& [data-slot=card-stack-edge]{inset-inline:22%;border:0;border-radius:999px}
& [data-slot=card-stack-surface] > [data-slot=alert]{display:flex!important;width:auto;min-height:30px;padding:9px 18px;gap:8px;align-items:flex-start;border-radius:inherit}
& [data-slot=alert]:has(> button:last-child){padding-inline-end:10px}
& [data-slot=alert] > .codicon:first-child{margin-top:2px!important;font-size:13px!important;font-weight:600}
& [data-slot=alert] > button:last-child{margin:-2px 0}
& [data-slot=alert] > div:has(> [data-slot=alert-title]){flex:0 1 auto;min-width:0;font-size:12px;line-height:16px;letter-spacing:-.01em}
& [data-slot=alert-title]{display:inline;max-height:none;overflow:visible;font:inherit;color:var(--foreground)}
& [data-slot=alert-description]{display:inline;font:inherit;color:var(--hq-label-2)}
& [data-slot=alert-title] + [data-slot=alert-description]::before{content:'·';margin-inline:6px;opacity:.6}
& [data-slot=alert-description] > p:first-child{display:inline}
& [data-slot=alert-description] > p + p{font-size:12px;line-height:16px}
& [data-slot=alert-description] [data-slot=button]{border-radius:999px}
}
[role=menu] :is([role^=menuitem][data-highlighted],[role=menuitem][data-state=open]){background:var(--hq-tint) !important;&,& :is(span,kbd,svg,i,.codicon){color:#fff !important}
&[data-variant=destructive]{background:#ff3b30 !important}
}
/* foundation-merge */
[role=tablist]:has(> [data-tree-tab=sessions]){height:28px;&>[data-tree-tab]{height:24px;font-size:12px;line-height:16px;font-weight:400;&[aria-selected=true]{font-weight:600}
& .truncate{font-size:12px;letter-spacing:-.08px}
}
}
:is([data-slot$=-item],[data-slot$=sub-trigger]):not([data-slot^=sidebar],[data-slot^=pagin],.group\\/label),html:root body :is([data-slot=dropdown-menu-search] input,[data-slot=popover-content] :is([data-slot=command-input],[data-slot=command-item]),[role=dialog]:not([data-slot])>[data-slot=command] :is([data-slot=command-input],[data-slot=command-item]),[role=tab][data-tree-tab=workspace] .truncate){letter-spacing:-.23px}
html:root body :is([data-slot=dialog-content].max-w-md [data-slot=dialog-description],[role=region]>[data-slot=card-stack] :is([data-slot=alert-title],[data-slot=alert-description]),[data-slot=dropdown-menu-shortcut],[data-slot=context-menu-shortcut]){letter-spacing:-.08px}
html:root body :is([data-slot=dropdown-menu-label],[data-slot=context-menu-label],[data-slot=select-label]){letter-spacing:-.08px}
/* chatcards */
[data-slot='aui_thread-content'] > .max-w-xl:not([data-approval-placement='floating']),[data-slot='aui_artifact-card']{max-width:none}
[data-slot='tool-approval-stack']:not([data-approval-placement='floating']){& [data-approval-activity]{margin:0 0 8px;& .group\\/disclosure-row :is(.truncate,.whitespace-nowrap){font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
& [data-slot='card-stack'] :is([data-slot='card-stack-surface'],[data-slot='card-stack-edge']){border:0;background:var(--hq-raised);box-shadow:0 0 0 .5px rgb(0 0 0/.1),0 1px 2px rgb(0 0 0/.05),0 4px 14px rgb(0 0 0/.06)}
html.dark & [data-slot='card-stack'] :is([data-slot='card-stack-surface'],[data-slot='card-stack-edge']){box-shadow:0 0 0 .5px rgb(255 255 255/.12),0 4px 14px rgb(0 0 0/.3)}
}
[data-slot='tool-approval-card']{& > div:first-child{padding:10px 12px 0;gap:6px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2);& > .tabular-nums{font-size:11px;letter-spacing:.06px;color:var(--hq-label-3)}
}
& > pre{margin:0;padding:8px 12px 0;font-size:12px;line-height:16px;letter-spacing:0;color:var(--foreground)}
}
[data-slot='tool-approval-actions']{gap:6px;padding:4px 10px 10px;& [data-slot='button'][data-size]{height:28px;min-height:28px;padding:0 12px;gap:5px;border-radius:999px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;box-shadow:none}
& [data-approval-deny]{color:var(--hq-label-2);background:transparent}
& [data-variant='secondary']{color:var(--foreground);background:var(--hq-fill-2);& :is(svg,.codicon){font-size:11px!important;width:11px;height:11px;font-weight:700;color:var(--foreground)}
}
& [data-approval-run] > span.opacity-60{display:none}
}
html:root.dark body :is([data-slot='tool-approval-actions'] [data-approval-run],:is([data-slot='clarify-inline'],[data-clarify-batch]) .justify-end.gap-1 > [type='submit']){background:var(--hq-tint-text)}
[data-slot='aui_changed-files']{--ui-green:var(--hq-green-text);--ui-red:var(--hq-red-text);margin-block:-4px;padding:12px 16px 0;&:first-child{margin-top:0}
& > div:first-child > span:first-child{font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;color:var(--foreground)}
& > div:first-child > :last-child:not(:first-child){font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-tint-text)}
& > div:last-child{margin:4px 0 0;padding:0;max-height:220px!important}
& .row-hover{min-height:30px;padding:0;gap:8px;border-radius:0;font-size:12px;line-height:16px;letter-spacing:-.08px;& + .row-hover{box-shadow:inset 0 .5px 0 var(--hq-sep)}
& > span.flex-1{color:var(--foreground)}
& > :is(svg,.codicon,img):first-child{width:18px;height:18px;font-size:14px;color:var(--hq-label-2)}
& > span:not(.flex-1){font-size:12px;line-height:16px;font-variant-numeric:tabular-nums;letter-spacing:-.08px}
& > span[style*='diff-add']{color:var(--ui-green)!important}
& > span[style*='diff-remove']{color:var(--ui-red)!important}
}
}
[data-slot='aui_thread-content'] :is([data-slot='diff-lines'],[data-slot='file-diff-panel']){--ui-diff-add-background:rgb(52 199 89/.12);--ui-diff-remove-background:rgb(255 59 48/.12);padding-block:8px;font-size:12px;line-height:16px;letter-spacing:0;color:var(--foreground);html:root.dark body &{--ui-diff-add-background:rgb(48 209 88/.12);--ui-diff-remove-background:rgb(255 69 58/.12)}
& :is(span.border-l-2,.line){border-left:0;padding:0 12px;min-height:18px;line-height:16px;color:var(--foreground)}
}
.rounded-3xl:has(> [data-slot='diff-lines']:only-child){padding:0;border-radius:var(--hq-card-r);overflow:hidden}
.rounded-3xl > [data-slot='diff-lines']:only-child{margin:0}
[data-slot='tool-block'][data-tool-open]{opacity:1;border:0;border-radius:var(--hq-card-r);background:var(--hq-card)!important;& > div:first-child{min-height:30px;display:flex;align-items:center;padding:7px 14px;position:relative;border-bottom:0;&::after{content:'';position:absolute;left:14px;right:14px;bottom:0;height:.5px;background:var(--hq-sep)}
& + div{gap:12px;padding:12px 14px 14px}
}
& [data-slot='file-diff-panel']{margin:-12px -14px -14px;max-height:20rem}
& p.uppercase[class*='tracking-']{margin:0 0 6px;font-size:12px;line-height:16px;font-weight:400;text-transform:none;letter-spacing:-.08px;color:var(--hq-label-2)}
& p.uppercase + div > p.uppercase:first-child{margin:-4px 0 6px;font-size:12px;line-height:16px;letter-spacing:0;color:var(--hq-label-3)}
& .text-xs.leading-relaxed{font-size:12px;line-height:16px}
& :is(pre,div)[class*='max-h-20']{max-height:240px;padding:12px;border-radius:10px;background:var(--hq-raised);font-size:12px;line-height:18px;letter-spacing:0;color:var(--foreground)}
& div.font-mono.border[class*='rounded-']{border:0;border-radius:10px;background:var(--hq-raised);padding:7px 12px;font-size:12px;line-height:18px;letter-spacing:0;& code{color:var(--foreground)}
}
& .max-w-72.border{border:0;border-radius:12px;max-width:280px}
}
[data-slot='aui_thread-content']{--hq-code-fill-bubble:rgb(224 224 226);html:root.dark body &{--hq-code-fill-bubble:#1f2023}
& [data-slot='aui_assistant-message-content'] .aui-md [data-slot='code-card']{background:var(--hq-code-fill-bubble);--expandable-fade-from:var(--hq-code-fill-bubble)}
& [data-slot='code-card-body']{font-size:12px;line-height:18px;letter-spacing:0;color:var(--hq-ink);html:root.dark body &{color:color-mix(in srgb,var(--hq-ink) 72%,transparent)}
& pre{padding:7px 12px!important;line-height:18px;color:inherit}
}
& [data-slot='aui_assistant-message-content'] [data-slot='tool-block'][data-delegate-card]{max-width:100%}
}
[data-slot='aui_assistant-message-content']{--image-preview-height:373px;& > :is([data-slot='clarify-inline'],[data-clarify-batch]):last-child{margin-bottom:0}
}
[data-slot='aui_markdown-image'].text-sm{margin:6px 0;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
[data-delegate-card]{gap:0;margin-block:8px;border-radius:var(--hq-card-r);background:var(--hq-card)!important;overflow:hidden;& > .rounded-xl.border{min-height:30px;align-content:center;gap:2px;border:0;border-radius:0;background:transparent;padding:7px 14px;& + .rounded-xl.border{background:linear-gradient(var(--hq-sep),var(--hq-sep)) no-repeat 42px 0/calc(100% - 58px) .5px}
& > div.pl-5{padding-left:26px;font-size:12px;line-height:16px}
}
& [data-conversation-scaffold]{opacity:1;gap:8px;font-size:12px;line-height:16px;letter-spacing:-.08px;& > button{color:var(--foreground)}
& > span:not(:first-child){font-size:12px;letter-spacing:-.08px;font-variant-numeric:tabular-nums;color:var(--hq-label-2)}
& > span.grid:first-child :is(.codicon,svg){font-size:13px!important;width:16px;height:16px}
& > .codicon:last-child{font-size:13px!important;color:var(--hq-label-3)}
}
}
[data-slot='aui_artifact-card']{align-items:flex-start;gap:10px;margin-block:8px;padding:9px 14px;& > span:first-child{width:22px;height:22px;margin-top:0;background:transparent;color:var(--hq-label-2);& > *{font-size:18px!important}
}
& > span.flex-1 > span:first-child{font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px}
& > span.flex-1 > span:last-child{margin-top:2px;font-size:12px;line-height:16px;letter-spacing:0;color:var(--hq-label-2)}
& > span:last-child:not(.flex-1){opacity:1;font-size:12px;font-weight:400;letter-spacing:-.08px;color:var(--hq-tint-text)}
}
[data-slot='clarify-inline']{padding:14px 16px 16px;&:not([data-clarify-batch] > *){margin-block:8px}
& .flex.items-start.gap-2 > svg.size-4[aria-hidden]:last-child{display:none}
& > .flex.items-start.gap-2 > span.flex-1{font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;color:var(--hq-label-2)}
& :has(> [role='group']){gap:10px}
& span.flex-1.font-medium{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px}
& [data-clarify-select-mode]{margin-top:2px;padding:0;background:transparent;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
& [role='group']{gap:0;border-radius:12px;background:var(--hq-raised);overflow:hidden;& > :is(button,label){min-height:30px;padding:9px 14px;gap:12px;align-items:center;border-radius:0;font-size:13px;line-height:18px;letter-spacing:-.08px;&:is(:hover,[data-highlighted]){background-color:var(--hq-fill-3)}
}
& > * + *{background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-position:50px 0;background-size:100% .5px;background-repeat:no-repeat}
& [data-slot='kbd']{position:relative;width:24px;height:24px;min-width:24px;margin:0;padding:0;border-radius:50%;border:1.5px solid color-mix(in srgb,var(--hq-ink) 30%,transparent);background:transparent;font-size:0;box-shadow:none;&.bg-primary{border-color:var(--hq-tint);background:var(--hq-tint);&::after{content:'';position:absolute;left:7px;top:3.5px;width:6px;height:11px;border:solid #fff;border-width:0 2px 2px 0;transform:rotate(45deg)}
}
}
& [data-highlighted] [data-slot='kbd']{border-color:var(--hq-tint)}
& textarea{min-height:22px;padding:0;border:0;background:transparent;box-shadow:none;font-size:13px;line-height:18px}
}
& :has(> .flex > [data-clarify-select-mode='multi']) > [role='group'] [data-slot='kbd']{border-radius:7px}
&[data-clarify-settled]{padding:7px 14px;gap:10px;& > .grid{gap:2px}
& span.font-medium{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
& [data-clarify-answer]{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--foreground)}
}
}
[data-clarify-batch]{margin-block:8px;gap:10px}
:is([data-slot='clarify-inline'],[data-clarify-batch]) .justify-end.gap-1{gap:8px;margin:0;& > [data-slot='button']{height:36px;min-height:30px;padding:0 22px;border-radius:999px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;box-shadow:none;& > span[aria-hidden]{display:none}
}
& > [data-variant='text']{padding:0 12px;font-weight:400;color:var(--hq-tint-text)}
}
/* pages-ops */
html:root body [data-overlay-surface]:is(:has(aside[data-tour=overlay-nav] > :nth-child(-n+8):last-child),:not(:has(main)):has(.group\\/row.h-7,i.codicon-hubot)) [data-glass-raised] > .absolute.top-0 > .pointer-events-auto{top:37px;right:20px;& [data-slot=button]:has(> .codicon-close){width:32px;height:32px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-label-2)}
& .codicon-close{font-size:12px!important;font-weight:700}
}
html:root body [data-overlay-surface]:has(aside[data-tour=overlay-nav] > :nth-child(-n+8):last-child){@media (min-width:47.5rem){& .grid:has(> aside){grid-template-columns:16rem minmax(0,1fr)}
& aside{margin:12px 0 12px 12px;padding:8px;gap:2px;border-radius:var(--hq-card-r);background:var(--hq-cell);box-shadow:none}
}
& aside button{height:32px;padding-inline:10px;gap:8px;border:0;border-radius:999px;font-size:12px;line-height:16px;letter-spacing:-.08px;&:not([aria-current=page]){color:var(--ui-text-primary);& svg{opacity:.7}
}
& svg{width:17px;height:17px;color:inherit}
}
& main{&{max-width:none;margin:0;padding-top:var(--ops-top,12px);--hq-label-2:var(--hq-section)}
& > div{padding-inline:24px}
& nav.text-xs{flex-wrap:wrap;row-gap:0;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
& nav.text-xs > [aria-current=page]{order:-1;flex-basis:100%;font-size:18px;line-height:24px;font-weight:700;letter-spacing:.1px;color:var(--ui-text-primary)}
& nav.text-xs > svg{width:0;margin:0;visibility:hidden}
& :has(> nav.text-xs > [aria-current=page]){align-items:flex-end;margin-bottom:16px;& > div.shrink-0{margin-right:44px;& input{text-overflow:ellipsis}
}
}
& ul > li.group.py-2{min-height:30px;padding:5px 12px 5px 16px}
& ul > li.group.py-2 > button > :first-child{font-size:13px;line-height:18px;letter-spacing:-.08px;font-weight:400}
& ul > li.group.py-2 > button > :last-child{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2);margin-top:1px}
& [data-slot=button][data-variant^=text][data-size=xs]{height:auto;min-height:30px;padding:0 12px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-link);font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;gap:6px;&:hover{background:var(--hq-fill-2)}
}
& section > .mb-1\\.5.uppercase{padding-left:16px}
& .overflow-y-auto > section:first-child > .mb-1\\.5.uppercase{margin-top:8px}
& :is(section,section > div) > .flex.justify-between.gap-3.py-2{padding:8px 14px;min-height:32px;align-items:center;& .min-w-0 > :first-child,& .min-w-0 span.font-medium{font-size:13px;line-height:18px;letter-spacing:-.08px;font-weight:400}
& .min-w-0 > :last-child:not(:first-child){margin-top:3px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
& [data-slot=badge]{position:relative;height:auto;border:0;background:transparent;padding:0 0 0 14px;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
& [data-slot=badge]::before{content:'';position:absolute;left:0;top:6px;width:8px;height:8px;border-radius:50%;background:var(--hq-green)}
}
& section > div:has(> .py-1:first-child + .flex.justify-between){display:flex;flex-direction:column}
& section > div > .py-1:first-child:has(+ .flex.justify-between){order:9;margin:0;padding:6px 16px 0;font-size:12px;line-height:16px;color:var(--hq-section)}
& .flex.items-start.justify-between:has(> .min-w-0 > div > span.size-2.rounded-full + span.font-medium){padding:9px 14px;border-radius:var(--hq-card-r);background:var(--hq-cell);align-items:center}
& span.size-2.rounded-full + span.font-medium{font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px}
& .mb-2.flex.flex-wrap:has(> span.tracking-\\[0\\.08em\\]){flex-direction:column;align-items:stretch;gap:8px}
& button.group\\/text-tab{font-size:12px;line-height:16px;letter-spacing:-.08px;font-weight:500;text-transform:capitalize}
& .group\\/logs{padding:36px 16px 10px;border:0;& > .overflow-y-auto{-webkit-mask-image:linear-gradient(transparent,#000 12px)}
& span.block{font-size:12px;line-height:16px;padding-block:2px;color:var(--ui-text-primary);opacity:1;overflow-wrap:anywhere}
& span.block[class*='ui-yellow']{color:var(--hq-orange-text)}
& span.block[class*='ui-red']{color:var(--hq-red-text)}
& span.block::before{display:none}
& > .absolute.z-10{top:6px;right:10px;& button{min-width:28px;min-height:28px;opacity:1;color:var(--hq-link)}
& svg{width:15px;height:15px}
}
}
& .grid.grid-cols-2.py-2:has(> .min-w-0 > .tracking-\\[0\\.12em\\]){gap:8px;padding:16px;border-radius:var(--hq-card-r);background:var(--hq-cell);& > .min-w-0{display:flex;flex-direction:column-reverse;justify-content:flex-end;gap:3px;padding:0;background:none}
& .tracking-\\[0\\.12em\\].uppercase{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;text-transform:none;color:var(--hq-label-2);padding:0;margin:0}
& .tracking-\\[0\\.12em\\] + *{margin:0;font-size:17px;line-height:22px;font-weight:600;letter-spacing:-.26px;font-variant-numeric:tabular-nums;color:var(--ui-text-primary)}
}
& section:has(> .mb-2 > .tracking-\\[0\\.08em\\]){padding:0;background:none;border-radius:0}
& .mb-2 > .tracking-\\[0\\.08em\\]{padding-left:16px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;text-transform:none;color:var(--hq-section)}
& section > .mb-2 + .flex.h-24{height:222px;margin:0;padding:16px;gap:3px;border-radius:var(--hq-card-r) var(--hq-card-r) 0 0;background:repeating-linear-gradient(to top,color-mix(in srgb,var(--hq-sep) 50%,transparent) 0 1px,transparent 1px 45px) content-box,var(--hq-cell);& > *{transform:scaleY(1.875);transform-origin:bottom}
& [class*='--dt-primary']{background:var(--hq-tint);border-radius:2px 2px 0 0/1.07px 1.07px 0 0}
& [class*='bg-emerald']{background:var(--out);border-radius:0}
& [class*='bg-emerald']:first-child{border-radius:2px 2px 0 0/1.07px 1.07px 0 0}
}
& section > .mb-2 + .flex.h-24 ~ *{margin:0;padding:0 16px 14px;border-radius:0 0 var(--hq-card-r) var(--hq-card-r);background:var(--hq-cell);font-size:12px;line-height:16px;color:var(--hq-label-2)}
& section span.rounded-\\[1px\\]{border-radius:50%;background:var(--hq-tint)}
& section:has(> .mb-2 + .flex.h-24){--out:color-mix(in srgb,var(--hq-tint) 45%,var(--hq-cell))}
& section span.rounded-\\[1px\\][class*='bg-emerald']{background:var(--out)}
& section > ul > li.py-1\\.5{min-height:30px;padding:8px 14px;align-items:center;& > *{font-size:13px;line-height:18px;letter-spacing:-.08px}
& > :first-child{font-family:inherit;color:var(--ui-text-primary)}
& > :last-child:not(:first-child){color:var(--hq-label-2);font-variant-numeric:tabular-nums}
}
& .grid.gap-x-8:has(section > ul > li.py-1\\.5){column-gap:20px;row-gap:24px}
& .inline-grid.grid-flow-col[class*='bg-(--ui-bg-tertiary)'] :is(button,span){font-size:12px;line-height:16px;letter-spacing:-.08px}
& .inline-grid.grid-flow-col[class*='bg-(--ui-bg-tertiary)'] > button{min-width:64px}
}
}
html:root body [data-overlay-surface]:not(:has(main)):has(.group\\/row.h-7){--hq-label-2:var(--hq-section);& header.mb-3{margin-bottom:20px}
@media (min-width:47.5rem){& .flex.w-full.shrink-0.flex-col:has(> .overflow-y-auto > .group\\/row){width:clamp(208px,16vw,240px)}
}
& .flex.flex-col.overflow-y-auto:has(> .group\\/row){flex:0 1 auto;padding:0;border-radius:var(--hq-card-r);overflow:clip;clip-path:inset(0 round var(--hq-card-r))}
& .flex.flex-col.overflow-y-auto:has(> .group\\/row){padding-block:4px}
& .group\\/row.h-7{position:relative;height:auto;min-height:26px;margin-inline:4px;border-radius:6px;& > [data-slot=row-button]{padding:4px 8px 4px 8px;gap:8px;border-radius:6px}
}
& .group\\/row.h-7[class*='bg-(--ui-row-active-background)']{background:var(--hq-fill)}
& .group\\/row span.size-1\\.5.rounded-full{width:0;height:8px;flex:none;margin-right:-10px;visibility:hidden;&.bg-destructive{order:9;width:8px;margin:0 0 0 auto;visibility:visible}
}
& .group\\/row:has(span.size-1\\.5:is([class*=quaternary],.bg-amber-500,[class*=muted-fore])) span.truncate{opacity:.55}
& .group\\/row:has(span.grid.size-4){min-height:28px}
& .group\\/row span.grid.size-4{width:20px;height:20px;flex:none;border-radius:50%;font-size:10px;line-height:20px;font-weight:600;text-transform:uppercase;background:color-mix(in srgb,currentColor 72%,#000)!important;-webkit-text-fill-color:#fff}
& .group\\/row:has(span.grid.size-4) + .group\\/row::before,& .group\\/row + .group\\/row:has(span.grid.size-4)::before{left:40px}
& .group\\/row span.grid.size-4:has(> i.codicon){background:var(--hq-fill-3)!important}
& .group\\/row span.grid.size-4 > i.codicon{font-size:12px!important;color:var(--hq-label-2);-webkit-text-fill-color:currentColor}
& .flex.flex-col.overflow-y-auto > button[data-slot=tooltip-trigger].w-full{justify-content:flex-start;gap:10px;min-height:30px;padding:0 16px;color:var(--hq-link);opacity:1;font-size:13px;line-height:18px;letter-spacing:-.08px;font-weight:400;&::after{content:attr(aria-label)}
}
& .group\\/row + button[data-slot=tooltip-trigger].w-full{background:linear-gradient(var(--hq-sep),var(--hq-sep)) 16px 0/calc(100% - 16px) .5px no-repeat}
& .space-y-4.pb-6{max-width:56rem;padding-inline:4px 20px}
& .flex-wrap:has(> h3.text-\\[0\\.95rem\\]){column-gap:8px;row-gap:4px}
& h3.text-\\[0\\.95rem\\].font-semibold{flex-basis:100%;font-size:17px;line-height:22px;font-weight:700;letter-spacing:.1px}
& h3.text-\\[0\\.95rem\\] ~ span.rounded-full{order:2;height:auto;padding:2px 8px;font-size:12px;line-height:16px;font-weight:600;letter-spacing:0;background:var(--hq-fill-3);color:var(--hq-label-2);text-transform:none}
& h3.text-\\[0\\.95rem\\] ~ span.rounded-full:is([class*='bg-primary'],[class*='amber'],[class*='orange'],[class*='emerald']){order:1;background:none;padding:0;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;text-transform:capitalize}
& header .min-w-0 > p.font-mono{margin-top:2px;font-family:inherit;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
& .flex.flex-wrap.items-start.justify-between:has(h3) > .flex.shrink-0{flex:1 1 100%;gap:8px;& > [data-slot=button]{flex:0 0 auto;flex-direction:row;gap:6px;height:auto;min-height:28px;padding:5px 14px;border:0;border-radius:999px;background:var(--hq-cell);color:var(--ui-text-primary);font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px;box-shadow:none;& :is(svg,i.codicon){width:16px;height:16px;font-size:14px!important;stroke-width:2.2}
&:hover{background:var(--hq-fill-4)}
&[data-variant=default]{order:-1}
}
}
& dl.grid[class*='grid-cols-[5rem_1fr]']{grid-template-columns:auto 1fr;column-gap:0;padding-right:0}
& dl.grid dt{color:var(--ui-text-primary);padding-block:7px;border:0;font-size:13px;line-height:18px;letter-spacing:-.08px}
& dl.grid dd{text-align:right;color:var(--hq-label-2);padding:7px 14px;border:0;font-size:13px;line-height:18px;letter-spacing:-.08px;min-width:0}
& dl.grid dd > *{justify-content:flex-end}
& dl.grid .contents + .contents > *{box-shadow:inset 0 .5px 0 var(--hq-sep)}
& dl dd :is(span.font-mono,span.font-mono > span){font:inherit;letter-spacing:inherit;color:inherit}
& header dl dd span.rounded-full.rounded-full{height:auto;padding:0;border:0;background:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;text-transform:none;color:var(--hq-label-2)}
& :is(pre.max-h-48,.space-y-1\\.5 > p.text-xs.leading-relaxed){max-height:none;margin:0;padding:8px 14px;border:0;border-radius:var(--hq-card-r);background:var(--hq-cell);font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ui-text-primary);opacity:1}
& section > pre.max-h-48.overflow-auto.whitespace-pre-wrap{font-size:12px;line-height:16px;letter-spacing:0}
& div > pre.max-h-48{font-family:inherit}
& .flex.flex-col.gap-px:has(> .flex.justify-between.rounded-md){gap:0;padding:0;& > .flex.justify-between.rounded-md{position:relative;flex-direction:column-reverse;align-items:stretch;justify-content:flex-start;gap:0;min-height:32px;padding:5px 14px;border-radius:0;& > span:first-child{min-width:0;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2);opacity:1}
& > :last-child:not(:first-child){font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ui-text-primary);font-variant-numeric:normal}
& + *::before{content:'';position:absolute;top:0;left:16px;right:0;height:.5px;border:0;background:var(--hq-sep)}
}
& > button.justify-between{padding-right:36px;&::after{content:'';position:absolute;right:18px;top:50%;width:7px;height:7px;margin-top:-4px;border:solid var(--hq-label-3);border-width:2px 2px 0 0;transform:rotate(45deg)}
}
}
& .flex.items-center.gap-1.rounded[class*='bg-foreground/5']{min-height:30px;padding:8px 14px;border-radius:var(--hq-card-r);background:var(--hq-cell);& > span.font-mono{font-size:12px;line-height:16px;color:var(--ui-text-primary)}
& > button{color:var(--hq-link)}
& > button svg{width:18px;height:18px}
}
& .cm-editor{&{padding:12px 16px 24px}
& :is(.cm-content,.cm-scroller,.cm-line){font-size:12px;line-height:20px;font-family:ui-monospace,'SF Mono',Menlo,monospace}
& .cm-line{padding:0;color:var(--ui-text-primary)}
& .cm-line span{color:inherit;font-weight:inherit;font-style:normal;text-decoration:none}
}
}
html:root body [data-overlay-surface]:not(:has(main)) .flex-1.flex.flex-col:has(> .grid.place-items-center.text-center:only-child){&:has(i.codicon-hubot)::before{content:'Agents';font-size:18px;line-height:24px;font-weight:700;letter-spacing:.1px;color:var(--ui-text-primary)}
& > .grid{align-items:start;padding-top:min(24vh,220px)}
& .grid > .flex.flex-col.items-center{gap:6px;max-width:420px}
& .grid i.codicon{font-size:40px!important;width:auto;height:auto;color:var(--hq-label-3);opacity:1;margin-bottom:6px}
& .grid p.text-sm.font-medium{font-size:18px;line-height:22px;font-weight:600;letter-spacing:-.45px;color:var(--ui-text-primary)}
& .grid p.text-xs{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section)}
}
/* pages-cap */
[data-tree-group]:is(:has([data-slot=connectors-directory]),:has([data-testid^=plugin-r]),:has([data-tour=tab-link])):not(:has([data-slot=aui_thread-content])){&,:root[data-hermes-glass][data-hermes-glass-scope] &{--ui-editor-surface-background:var(--hq-grouped);--ui-chat-surface-background:var(--hq-grouped);--hq-card:var(--hq-cell);background-color:var(--hq-grouped)}
html:root.dark &{--hq-grouped:#1c1c1e;--hq-cell:#2c2c2e}
}
html:root body [data-tour=page-tabs]{button{line-height:18px}
button>span[class*='text-[0.72em]']{font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-slot=count-skeleton]{display:none}
}
[data-tree-group]{div.border-b:has(>[data-slot=select-trigger]),&:has(main) div.border-b:has(>div.flex-wrap>button.rounded-full){border-bottom:0}
div:has(>[data-slot=select-trigger])>span[class*='text-[0.7rem]']{font-size:12px;line-height:16px;letter-spacing:-.08px;font-weight:400;color:var(--hq-label-2)}
}
.group\\/row>[data-slot=row-button]:has(+[role=switch]){padding-block:6px;.text-\\[0\\.78rem\\]{font-size:13px;line-height:18px;letter-spacing:-.08px}
.text-\\[0\\.62rem\\]{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
[data-tree-group]:has(main){:is(.group\\/row,ul.space-y-1>li>button)[class*='bg-(--ui-row-active-background)']{background-color:rgb(116 116 128/.2);&:where(.dark *){background-color:rgb(118 118 128/.24)}
}
aside>div.overflow-y-auto:has(>.group\\/row,>ul.space-y-1){scrollbar-gutter:auto;padding-bottom:14px;-webkit-mask-image:linear-gradient(#000 calc(100% - 18px),transparent);mask-image:linear-gradient(#000 calc(100% - 18px),transparent)}
aside .group\\/row{height:auto;min-height:36px}
:is(aside .group\\/row,ul.space-y-1 button).row-hover{color:var(--ui-text-primary)}
aside>div.mb-1{height:auto;padding:0 4px 6px 16px;button.cursor-pointer[class*='text-[0.68rem]']{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
button[aria-haspopup]{color:var(--hq-label-2)!important}
button[aria-haspopup] :is(svg,i){font-size:13px!important}
}
.sm\\:grid-cols-\\[14rem_minmax\\(0\\,1fr\\)\\]{grid-template-columns:19rem minmax(0,1fr)}
ul.space-y-1{>li{margin-block:0}
>li>button.row-hover{min-height:26px;padding:4px 12px;gap:10px;span[class*='conversation-text-font-size']{font-size:13px;line-height:18px;letter-spacing:-.08px}
}
>li+li:has(>button>span.inline-grid.size-6){background-size:calc(100% - 58px) .5px;background-position:58px 0}
button.row-hover>span.inline-grid.size-6 svg{width:18px;height:18px}
button.row-hover span.size-1\\.5.rounded-full[class*='bg-muted-foreground']{display:none}
}
}
[data-tree-group] main{&:has(>div.text-right)>div.overflow-y-auto{width:min(100% - 40px,632px);margin-inline:auto;border-radius:var(--hq-card-r);scrollbar-gutter:auto;>div{padding:16px 0}
}
div.rounded-lg.border:has(>div.gap-2){gap:0;padding:0 0 0 16px}
div.rounded-lg.border>div.gap-2{padding:9px 16px 9px 0;font-size:12px;line-height:16px;letter-spacing:-.08px;+div{box-shadow:0 -.5px 0 var(--hq-sep)}
>span:first-child{text-transform:capitalize}
>span:last-child{color:var(--ui-text-primary)}
}
pre[data-selectable-text]{padding:16px}
>div.text-right.shrink-0{max-width:none;text-align:left;padding:8px 20px 8px calc(max(0px,(100% - 42rem)/2) + 36px);background:var(--hq-grouped);font-size:12px;line-height:16px;color:var(--hq-section)}
button.grid>span.text-\\[0\\.68rem\\]{font-size:12px;line-height:16px;letter-spacing:-.08px}
button.grid>span.text-amber-600{font-size:12px;line-height:16px;color:var(--hq-label-2);>svg{color:var(--hq-orange-text)}
}
span.rounded-md.font-mono{border-radius:999px;background:var(--hq-fill-3);padding:2px 10px}
}
[data-tree-group]:has([data-tour=page-tabs]){main div.space-y-5>header:first-child:has(+div.flex){margin:0!important;padding:16px 16px 4px;background:var(--hq-cell);border-radius:var(--hq-card-r) var(--hq-card-r) 0 0;>div:first-child{row-gap:2px}
h3{flex-basis:100%;white-space:normal;overflow-wrap:anywhere;font-size:17px;line-height:22px;font-weight:700;letter-spacing:-.26px}
.rounded-full{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;background:transparent;padding:0;color:var(--hq-label-2)}
.rounded-full+.rounded-full::before{content:'·';margin-right:8px}
>p{margin-top:6px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ui-text-primary)}
+div+*{margin-top:12px!important}
+div{margin-top:0!important;padding:8px 16px 16px;column-gap:10px;background:var(--hq-cell);border-radius:0 0 var(--hq-card-r) var(--hq-card-r)}
+div>[data-slot=button]{height:32px;padding:0 16px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-tint);font-weight:600}
}
@media (min-width:1300px){main div.space-y-5:has(>header:first-child+div.flex>[data-slot=button]){display:grid;grid-template-columns:minmax(0,1fr) auto;row-gap:12px;>*{grid-column:1/-1;margin:0!important}
>header:first-child{grid-column:1;padding-bottom:16px;border-radius:var(--hq-card-r) 0 0 var(--hq-card-r)}
>header+div.flex{grid-column:2;align-items:flex-start;padding:16px 16px 16px 8px;border-radius:0 var(--hq-card-r) var(--hq-card-r) 0}
}
}
section:has(>div.cursor-row-resize){border-top:0;>div.flex.justify-between>span{padding-left:16px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
>div.flex.justify-between [data-slot=button][data-variant=text]{padding:0 6px;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px}
div:has(>iframe){border:0!important;border-radius:var(--hq-card-r)!important;background:var(--hq-cell)}
p.shrink-0[class*='text-[0.65rem]']{padding:2px 16px 0;font-size:12px;line-height:16px;color:var(--hq-section)}
}
}
[data-slot=connectors-directory]{width:100%;max-width:64rem;>div:first-child>h2,section>header>:is(h3,span){font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
>div:first-child>h2,section>header{padding-left:16px}
[data-slot=button][data-size=xs]:not([data-slot=connector-row-card] *){min-height:24px;padding:0 12px;font-size:12px;line-height:16px;font-weight:400;background:transparent;color:var(--hq-link)}
>div.border-b{border-bottom:0;padding-bottom:0}
div.inline-grid.grid-flow-col:has(>button[aria-pressed]){grid-auto-columns:1fr;width:fit-content}
section.grid>.grid{grid-template-columns:1fr;gap:0;background:var(--hq-cell);border-radius:var(--hq-card-r);overflow:hidden}
}
[data-slot=connector-row-card]{gap:12px;min-height:36px;padding:4px 12px;border:0;border-radius:0;background:transparent;+[data-slot=connector-row-card]{background:linear-gradient(var(--hq-sep) 0 0) 58px 0/calc(100% - 58px) .5px no-repeat}
>span.inline-grid{width:34px;height:34px;border-radius:8px;box-shadow:inset 0 0 0 .5px var(--hq-fill-3)}
>span.inline-grid:not(:has(img,svg)){color:var(--hq-tint)!important;font-size:12px;font-weight:600}
button.font-semibold{font-size:13px;line-height:18px;letter-spacing:-.08px}
.grid.min-w-0 span[class*='text-[0.6875rem]'],p[class*='text-[0.72rem]']{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
p.text-\\(--ui-red\\){color:var(--hq-red-text)}
.w-\\[7\\.75rem\\]{width:auto;min-width:7.75rem;flex-direction:row;align-items:center;justify-content:flex-end;gap:12px;>span{font-size:12px;line-height:16px;color:var(--hq-label-2)}
>[role=switch]{order:2}
}
.w-\\[7\\.75rem\\]>span:has(>span[class*='bg-(--ui-text-quaternary)']):has(+[role=switch][aria-checked=false]){display:none}
[data-slot=button][data-size=xs]{min-height:24px;padding:0 12px;font-size:12px;line-height:16px;font-weight:600}
}
.min-h-32.overflow-y-auto:has(>[role=table] [data-testid^=plugin-r]){clip-path:inset(0 16px round var(--hq-card-r));>div.flex.flex-wrap{padding-inline:16px}
>div.flex.flex-wrap>p[class*='conversation-caption']{padding-left:16px;font-size:12px;line-height:16px;color:var(--hq-section)}
}
[role=table]:has([data-testid^=plugin-r]){margin:0 16px 16px;>[role=row]:first-child{background:transparent;border:0;border-radius:0;padding:0 16px 6px;font-size:12px;line-height:16px;color:var(--hq-section);>[role=columnheader]:not(:last-child){display:none}
>[role=columnheader]:last-child{flex:1}
[data-slot=select-trigger]{max-width:22rem}
+[role=row]{border-radius:var(--hq-card-r) var(--hq-card-r) 0 0}
}
}
[data-testid^=plugin-r]>[role=cell]:has(>span[aria-hidden]:only-child){width:0;margin-left:-12px;overflow:hidden;visibility:hidden}
[data-testid^=plugin-r]{border-bottom:0;padding:8px 14px;background-color:var(--hq-cell);&:not(:has(~[data-testid^=plugin-r])){border-radius:0 0 var(--hq-card-r) var(--hq-card-r)}
+[data-testid^=plugin-r]{background:linear-gradient(var(--hq-sep) 0 0) 16px 0/100% .5px no-repeat var(--hq-cell)}
>[role=cell]:first-child{align-items:center}
>[role=cell]:not(:first-child){width:auto;gap:12px}
[role=cell] [data-slot=tooltip-trigger][data-size^=icon]{color:var(--hq-label-3)}
[role=cell] [data-slot=button]:not([data-size^=icon]){font-size:12px;line-height:16px}
div[class*=conversation-text]{font-size:13px;line-height:18px;letter-spacing:-.08px;>span:first-child{font-weight:600}
>.text-\\(--ui-text-quaternary\\){font-weight:400;font-size:12px}
}
div[class*=conversation-caption]{max-width:44rem;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
:is([data-testid^=plugin-r],[data-slot=connector-row-card]) :is(span.rounded.border,[data-slot=badge]){padding:1px 8px;border:0;border-radius:999px;background:var(--hq-fill-3);font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-tree-group]:has(ul.space-y-1>li>button>span.size-6) main{>div.overflow-y-auto>div.mx-auto.max-w-2xl{margin-left:0;max-width:47rem;padding-inline:24px}
>div.overflow-y-auto{mask-image:linear-gradient(#000 calc(100% - 16px),#0000)}
>footer{padding:8px 24px 10px;background:var(--hq-grouped);>div{margin-left:0;max-width:44rem}
}
}
aside>div.overflow-y-auto:has(>ul.space-y-1>li>button>span.size-6){margin-bottom:8px;border-radius:var(--hq-card-r)}
[data-tree-group] :is(main header,ul.space-y-1 button.row-hover)>span.inline-grid.size-6{width:30px;height:30px;border-radius:7px;background:var(--hq-fill-3)!important;color:var(--hq-tint)!important}
html:root body [data-tree-group] main{section>h4.uppercase{padding-left:16px!important}
section>h4.uppercase+p{padding-inline:16px}
footer label:has(>[data-slot=switch]){gap:10px;font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ui-text-primary)}
section>h4.uppercase~.mt-3>a[data-variant=textStrong]:only-child{margin-left:2px;font-weight:400}
section>h4.uppercase+.mt-3{margin-top:6px}
section div.rounded-xl.border.p-3{padding:8px 14px}
}
:is([data-slot=connectors-directory],[data-tree-group]:has([data-tour=tab-link])) div.inline-flex.border-b:has(>input){min-height:28px;min-width:min(240px,100%);padding:0 12px 0 10px;border:0;border-radius:999px;background:var(--hq-fill-3);opacity:1;>input{flex:1 1 auto;height:32px;font-size:13px;line-height:18px;letter-spacing:-.08px}
>input::placeholder{color:var(--hq-label-2);opacity:.8}
>svg{width:17px;height:17px;color:var(--hq-label-2)}
}
[data-tree-group]:has([data-tour=tab-link]) section>div.sticky{height:32px;background:var(--ui-chat-surface-background);div.shrink-0[class*='text-[0.62rem]']{font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-slot=pagination] :is(a,button,span){font-size:12px}
[data-slot=pagination] [aria-current=page]{min-width:24px;height:22px;padding:0 8px;border:0;border-radius:999px;box-shadow:none;background:var(--hq-fill-3)}
}
[data-tour=artifact-card]{>div:first-child{height:auto;aspect-ratio:1;padding:8px;border-bottom:0}
>div:first-child>[data-slot=artifact-media]{width:100%;height:100%;overflow:hidden;border-radius:12px;background:var(--hq-fill-3)}
>div:first-child img{width:100%;height:100%;max-height:none;object-fit:scale-down;border-radius:0}
>div:last-child{padding:10px 14px 14px}
div.uppercase:has(>svg){display:none}
div[class*='text-[0.625rem]']{font-size:12px;line-height:16px;color:var(--hq-label-3)}
div.truncate.font-medium{font-size:12px;line-height:16px;font-weight:600;letter-spacing:-.08px}
div.truncate:not(.mt-0\\.5,.font-medium){white-space:normal;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;font-size:12px;line-height:16px;color:var(--hq-label-2)}
[data-slot=button][data-variant=textStrong]{font-size:12px;line-height:16px;letter-spacing:-.08px}
}
div.overflow-x-auto:has(>table tr.group\\/artifact){border:0;border-radius:0;background:transparent;thead{border:0;background:transparent!important;font-size:12px;line-height:16px;color:var(--hq-section)}
th{padding:6px 16px;font-weight:400}
tbody tr+tr>td{border-top:.5px solid var(--hq-sep)}
tbody tr+tr>td:first-child{border-top:0;background:linear-gradient(var(--hq-sep) 0 0) 62px 0/100% .5px no-repeat}
td>:is([data-slot=row-button],a.ref){gap:12px;padding:7px 14px}
td>div.flex{padding-inline:6px}
:is([data-slot=row-button],a.ref)>span.size-6{width:34px;height:34px;align-self:center;margin:0;border-radius:8px;color:var(--hq-tint)}
:is([data-slot=row-button],a.ref)>span.size-6 svg{width:18px;height:18px}
:is([data-slot=row-button]>span.truncate,a.ref>span.flex-1){font-size:13px;line-height:18px;letter-spacing:-.08px}
[data-slot=row-button]>span.truncate{color:var(--ui-text-primary)}
[data-slot=tooltip-trigger].font-mono{font-size:12px;line-height:16px;color:var(--hq-label-3)}
[data-slot=row-button]>span.flex-col>span{font-size:12px;line-height:16px;color:var(--hq-label-3);&:first-child{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
}
[data-glass-raised]:has(>div>.session-import,[aria-label='Timeline scrubber'])>.pointer-events-none>.pointer-events-auto{top:37px;right:20px;gap:8px;>button{width:32px;height:32px;background:var(--hq-fill-3)}
i{font-size:12px!important}
}
.session-import{>header{padding:10px 20px 20px}
>header>h1{font-size:18px;line-height:24px;font-weight:700;letter-spacing:.1px}
>header>p{font-size:12px;line-height:16px;letter-spacing:-.08px}
>header>div.text-xs{font-size:12px;line-height:16px}
>div.border-t{border-top:0}
aside div.inline-grid.grid-flow-col:has(>button[aria-pressed]){width:100%;grid-auto-columns:minmax(max-content,1fr);>button{padding-inline:8px}
}
[data-overlay-surface] [data-glass-raised] & aside{background:var(--hq-grouped);box-shadow:none}
aside .overflow-y-auto{padding-inline:24px;padding-bottom:24px;>div>p{padding:20px 16px 6px;font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px}
>div>button.w-full{padding:9px 14px;border-radius:0;background-color:var(--hq-cell)}
>div:not(:has(>p))>button.w-full{background:linear-gradient(var(--hq-sep) 0 0) 16px 0/100% .5px no-repeat var(--hq-cell)}
>div>p+button.w-full{border-radius:var(--hq-card-r) var(--hq-card-r) 0 0}
>div:is(:has(+div>p),:last-child)>button.w-full{border-bottom-left-radius:var(--hq-card-r);border-bottom-right-radius:var(--hq-card-r)}
>div>button.w-full:is(:hover,[aria-pressed=true]){background-color:var(--hq-fill-4)}
}
aside button>span{&.line-clamp-2{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px}
&.mb-2{margin-bottom:3px;font-size:12px;line-height:16px}
&.mt-1{margin-top:3px;font-size:12px;letter-spacing:-.08px}
}
main .codicon-comment-discussion{margin-bottom:6px;font-size:44px!important;color:var(--hq-label-3)}
}
html:root body .session-import main{p.text-sm.font-medium{font-size:18px!important;line-height:22px!important;color:var(--ui-text-primary)}
p.max-w-sm{font-size:12px!important;line-height:16px!important;letter-spacing:-.08px}
}
[data-overlay-surface]:has([aria-label='Timeline scrubber']){div.bottom-2.left-2{font-size:12px;line-height:16px;color:var(--hq-label-2);*{font-size:inherit}
}
[aria-label='Play timeline']{color:var(--hq-tint)}
[aria-label='Import / export map']{width:32px;height:32px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-label-2);:is(i,svg){width:15px;height:15px;font-size:12px!important}
}
[role=slider]>div.bg-foreground{border-radius:1px;background:var(--hq-tint)}
}
/* settings-a */
[data-overlay-surface]>.relative>.absolute.left-1\\/2.top-0{@media (min-width:47.5rem){left:21px;top:22px;width:calc(14rem - 28px);transform:none;translate:none}
&>button{width:100%;height:28px;padding:0 10px;gap:6px;border:0;border-radius:999px;background:var(--hq-fill-3);box-shadow:none;color:var(--hq-label-2);&>svg{width:14px;height:14px}
&>span.text-xs{flex:1;text-align:left;font-size:13px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
}
[data-overlay-surface]:has(>.relative>.left-1\\/2.top-0){@media (min-width:47.5rem){& [data-glass-raised] .grid[class*='grid-cols-[13rem']{grid-template-columns:15rem minmax(0,1fr)}
& [data-glass-raised] aside{margin:12px 0 12px 12px;padding:56px 8px 20px;gap:2px;border-radius:var(--hq-card-r);background:var(--hq-cell);box-shadow:none;scrollbar-width:thin;scroll-padding-bottom:20px}
}
& aside{& button:not([data-slot=button]){min-height:28px;padding-inline:10px;border-radius:999px;font-size:13px;line-height:18px;letter-spacing:-.08px;&:not([aria-current=page])>span{color:var(--ui-text-primary)}
&:not([aria-current=page])>:is(svg,i){color:var(--ui-text-primary);opacity:.7}
&>svg{width:15px;height:15px}
}
& .ml-3\\.5 button:not([data-slot=button])>svg{width:14px;height:14px}
&>div.h-2:empty{height:12px;flex:none}
& [data-slot=button]:has(>.codicon-chevron-right){color:var(--hq-label-3)}
& [data-slot=button]>.codicon-chevron-right{font-size:12px!important;font-weight:700}
}
& [data-glass-raised]>.pointer-events-none.absolute.inset-x-0.top-0{&>.pointer-events-auto{top:37px;right:20px}
& [data-slot=button]:has(>.codicon-close){width:32px;height:32px;border-radius:999px;background:var(--hq-fill-3);color:var(--hq-label-2)}
& [data-slot=button]>.codicon-close{font-size:12px!important;font-weight:700}
}
& [data-glass-raised] main{padding-top:20px;&>*{width:100%;max-width:68rem;margin-inline:auto}
}
& main{--hq-label-2:var(--hq-section);--ui-text-secondary:var(--hq-section);& :is(:is([id^=setting-field-],[id^=aux-task-],.\\@container,.scroll-mt-6.rounded-lg)+:is([id^=setting-field-],[id^=aux-task-],.\\@container,.scroll-mt-6.rounded-lg),section>.grid.gap-1>[data-slot=button],section>.grid.gap-1>[data-slot=button]+*,.h-72+p.mt-2,[id$=translucency] .mt-3.flex-col>.flex,[id$=fallback_providers] .grid.gap-1\\.5>div:last-child){margin-right:-16px;padding-right:16px}
& :is(.overflow-y-auto,.grid:not(.gap-1),section.mb-6)>:is([id^=setting-field-],.\\@container)+:is([id^=setting-field-],.\\@container){margin-right:0!important;box-shadow:none;background:linear-gradient(var(--hq-sep),var(--hq-sep)) 16px 0/100% .5px no-repeat var(--hq-cell)}
&>.mb-3.flex.shrink-0:has(>nav){position:relative;min-height:32px;margin-bottom:18px;align-items:center;justify-content:center}
&>.mb-3.flex.shrink-0>nav{justify-content:center;gap:0;max-width:calc(100% - 96px);&>span.shrink-0:first-child:not([aria-current]),&>svg{display:none}
&>span[aria-current=page]{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--ui-text-primary)}
&>[data-slot=button]{position:absolute;left:clamp(1.25rem,4vw,4rem);top:50%;transform:translateY(-50%);width:32px;height:32px;padding:0;border-radius:999px;background:var(--hq-fill-3);font-size:0;color:var(--ui-text-primary);text-decoration:none;&::before{content:'';width:8px;height:8px;margin-left:3px;border:solid currentColor;border-width:0 0 2px 2px;transform:rotate(45deg)}
&:hover{background:var(--hq-fill-2)}
}
}
& .grid.gap-2.mb-5:has(>.flex.flex-wrap>button.rounded-full.border)>div:first-child,& section>.mb-2\\.5.flex:not(.justify-end){padding-left:16px}
& section>.mb-2\\.5.flex:not(.justify-end){font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--hq-section)}
& .grid.gap-2.mb-5>.flex.flex-wrap.gap-1\\.5>button{flex:none;height:24px;padding:0 10px;font-size:12px;line-height:16px;font-weight:400;letter-spacing:0;&[class*=ui-bg-tertiary]{border-color:transparent;background:color-mix(in srgb,var(--hq-link) 15%,transparent);color:var(--hq-link);font-weight:600}
}
& .\\@container>.grid.gap-3.py-3{padding-block:12px;min-height:40px;&>.flex.min-w-0:has(>:is(input,[data-slot=input],textarea,[data-slot=popover-anchor])){min-width:12rem;max-width:22rem}
&>.flex.min-w-0:has(>:is(input[type=number],input[inputmode=numeric],[data-slot=input][inputmode=numeric])){min-width:6rem}
&>.min-w-0>.mt-1{margin-top:4px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2);&>.font-mono{font:inherit;letter-spacing:inherit}
}
&>.min-w-0>.flex span.items-baseline>[data-slot=badge]{padding:0;border:0;background:none;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
}
& .\\@container .min-w-0>a[href]{height:auto;margin-top:4px;padding:0;gap:4px;font-size:12px;line-height:16px;font-weight:400;color:var(--hq-link)}
& [id^=setting-field-] :is(input,[data-slot=input]):not(:focus,[type=checkbox],[type=range]){text-overflow:ellipsis}
& section:has(>.flex-wrap>[data-slot=select-trigger]){&>.flex.flex-wrap:not(.mt-3)>[data-slot=select-trigger]{gap:12px;&>[data-slot=select-value]{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
}
&>.mt-3>.flex>[data-slot=select-trigger]{color:var(--hq-link)}
}
& section:has(>.flex-wrap>[data-slot=select-trigger]+[data-slot=select-trigger])>.flex.flex-wrap:not(.mt-3)>[data-slot=button]{flex:1 1 100%;justify-content:flex-start;min-height:30px;margin:0;padding:0;border-radius:0;background:none;box-shadow:0 -.5px 0 var(--hq-sep);font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link)}
& :is(section>.mb-2\\.5.flex.justify-end,.rounded-md.border.border-amber-400\\/60,section>.mb-2.flex.flex-wrap,.\\@container .mt-2.flex.flex-wrap.pt-1)>[data-slot=button]{padding-inline:0;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link)}
& section:has(>.mb-2\\.5.flex.justify-end+p){display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:baseline;&>*{grid-column:1/-1}
&>.mb-2\\.5.flex.justify-end{grid-column:2;grid-row:1;margin:0;padding-right:16px}
&>.mb-2\\.5.flex.justify-end+p{grid-column:1;grid-row:1;padding-left:16px}
}
& .rounded-md.border.border-amber-400\\/60{gap:4px 12px;padding:9px 14px;border:0;border-radius:var(--hq-card-r);background:var(--hq-cell);&>svg{width:18px;height:18px;color:#ff9500}
&>span.grow{font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--ui-text-primary);& .font-mono{font-family:inherit;font-size:inherit;font-weight:600}
}
&>[data-slot=button]:last-child{margin-left:30px}
}
& section>.mb-2.flex.flex-wrap{&>label.rounded-sm.border{flex:1 1 100%;box-shadow:0 -.5px 0 var(--hq-sep),0 .5px 0 var(--hq-sep);justify-content:space-between;min-height:32px;padding:0 16px 0 0;border:0;border-radius:0;font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--ui-text-primary)}
&>:is([data-slot=button],input){margin-block:10px}
&>[data-slot=button][data-variant=ghost]{margin-left:16px;color:var(--hq-red-text)}
&>[data-slot=button][data-variant=text]{margin-right:4px}
&>[data-slot=input]{flex:1 1 10rem;height:32px;min-height:32px;margin-left:auto;margin-right:8px;padding:0 14px;border:0;border-radius:999px;background:var(--hq-fill-3);font-size:13px;text-align:left;box-shadow:none}
}
& section>.mb-2.text-xs.text-muted-foreground{padding:0 16px;font-size:12px;line-height:16px;color:var(--hq-section);& .font-mono{font-family:inherit;font-size:inherit;color:var(--hq-label-2)}
}
& .\\@container .mt-2.flex.flex-wrap.pt-1{gap:4px 20px;padding-top:6px;&>[data-slot=select-trigger]{flex:none;width:auto;min-width:0;justify-content:flex-start;margin-left:0;padding-left:0}
&>[data-slot=button][data-variant=ghost]{margin-left:auto;color:var(--hq-red-text)}
}
& section>.grid.gap-1>[data-slot=button][data-variant=textStrong]{justify-content:flex-start;min-height:30px;padding-left:0;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);box-shadow:0 -.5px 0 var(--hq-sep)}
& section>.grid.gap-1>[data-slot=button]+.\\@container{box-shadow:0 -.5px 0 var(--hq-sep)}
& [id^=setting-field-]>div>p.max-w-2xl:first-child+.mt-2>.\\@container{padding:0;background:none;box-shadow:none}
& .h-72+p.mt-2{margin-top:0;padding-top:10px;box-shadow:0 -.5px 0 var(--hq-sep);font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section)}
& [id^=setting-field-] .inline-grid.auto-cols-fr>button{padding-inline:10px;&>span.truncate{overflow:visible;text-overflow:clip}
}
@container (min-width:32rem){& .\\@container>.grid.gap-3.py-3:has(>:nth-child(2)){grid-template-columns:minmax(0,1fr) auto;column-gap:24px;align-items:center}
& .\\@container>.grid.gap-3.py-3:has(>.min-w-0>:is(.mt-2.flex-wrap.pt-1,.mt-3.flex-col)){row-gap:0;&>.min-w-0:not(.flex){display:contents;&>*{grid-column:1}
&>:is(.mt-2.flex-wrap.pt-1,.mt-3.flex-col){grid-column:1/-1}
}
&>.flex.min-w-0{grid-column:2;grid-row:1;align-self:center}
&:has(>.min-w-0>.mt-1)>.flex.min-w-0{grid-row:1/span 2}
}
}
& [id$=".language"] [data-slot=popover-trigger]{position:relative;padding:0 13px 0 0;background:none;border:0;box-shadow:none;color:var(--hq-link);font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;&>span>svg:first-child,&>svg:last-child{display:none}
&::before,&::after{content:'';position:absolute;right:2px;width:4px;height:4px;border:solid currentColor;transform:rotate(45deg)}
&::before{top:calc(50% - 5px);border-width:1.6px 0 0 1.6px}
&::after{top:50%;border-width:0 1.6px 1.6px 0}
}
}
html.dark & main .rounded-md.border.border-amber-400\\/60>svg{color:#ff9f0a}
}
#setting-field-fallback_providers .grid.w-full.gap-1\\.5{&>div:last-child{margin-top:8px;box-shadow:0 -.5px 0 var(--hq-sep);&>[data-slot=button]{min-height:30px;margin-bottom:-11px;padding:0;gap:10px;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);&>svg{width:20px;height:20px}
}
}
&>p{font-size:12px;line-height:16px;color:var(--hq-label-2)}
}
[id^=aux-task-] [data-slot=button]:is([data-variant=text],[data-variant=textStrong]){margin-left:8px;padding-inline:0;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);&[data-variant=textStrong]{font-weight:600}
}
[id^=setting-field-appearance] .grid.gap-3>.group>button{padding:10px;border:0;border-radius:16px;background:var(--hq-grouped);box-shadow:none;--tw-ring-shadow:0 0 #0000;&.border-primary{box-shadow:inset 0 0 0 2px var(--hq-link)}
&>.h-20.rounded-xl{height:72px;border-radius:10px;border-color:var(--hq-sep);box-shadow:none}
&>.mt-3{margin-top:8px;padding-inline:2px;&>.mt-0\\.5{font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
}
}
[id^=setting-field-appearance][id$=-font] .min-w-0>.mt-3{margin-top:6px;&>div:not(:first-child){padding-inline:0}
}
[id$=translucency] .mt-3.flex-col{gap:0;margin-top:8px;&>.flex{min-height:30px;gap:12px;box-shadow:0 -.5px 0 var(--hq-sep);&>span.w-12{width:4rem;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--ui-text-primary)}
&>input[type=range]{flex:1 1 auto;width:auto}
&>.inline-grid{margin-left:auto}
&>span.w-9{width:3rem;font-size:12px;line-height:16px;color:var(--hq-label-2)}
}
}
[data-overlay-surface] button[data-tour^='nav-toggle-'][aria-expanded='false']{opacity:0}
[data-overlay-surface] .relative:is(:hover,:focus-within) > button[data-tour^='nav-toggle-']{opacity:1}
/* settings-b */
[data-overlay-surface] main:has(nav[aria-label='Passwords & Logins']) section{> div > p.mb-2{margin:8px 0 0;padding:0 16px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section)}
> div{display:flex;flex-direction:column}
> div > *{order:1}
> div > :first-child{order:0}
> div > div:has(> [data-slot=badge] + * > [data-slot=button]){order:2;flex-direction:row-reverse;margin:0;padding:0 16px;min-height:32px;background:var(--hq-cell);border-radius:0 0 var(--hq-card-r) var(--hq-card-r);background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-size:calc(100% - 16px) .5px;background-position:100% 0;background-repeat:no-repeat;> :last-child{margin-left:0}
[data-slot=button]{height:auto;gap:12px;padding:0;border:0;background:none;box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link)}
[data-slot=button] svg{width:22px;height:22px;stroke-width:1.75}
[data-slot=badge]{margin-left:auto;padding:0;border:0;background:none;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
}
> div > p{order:3}
> div > .\\@container:not(:has(~ .\\@container)){margin-bottom:0!important}
> div:has(> div > [data-slot=badge] + * > [data-slot=button]) > .\\@container:not(:has(~ .\\@container)){border-bottom-left-radius:0!important;border-bottom-right-radius:0!important}
.\\@container .min-w-0 [data-slot=badge]{padding:0;border:0;border-radius:0;background:none;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
.\\@container .mt-1 .gap-x-2{column-gap:5px}
.\\@container .justify-end:has(> [data-slot=button]){gap:12px}
.\\@container .justify-end > [data-slot=button]:is([data-variant=outline],[data-variant=secondary]){height:auto;padding:0 4px;border:0;background:none;box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);svg{display:none}
}
> div > .\\@container > .grid > .min-w-0{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:baseline;> :first-child,> :first-child > span,> :first-child > span > span:has(> [data-slot=badge]){display:contents}
> :first-child .truncate{grid-column:1/-1;grid-row:1;font-size:13px;line-height:18px;letter-spacing:-.08px}
[data-slot=badge]{grid-column:1;grid-row:2;margin-top:2px}
[data-slot=badge]::after{content:'\\00b7';margin-left:1px;margin-right:5px}
> .mt-1{grid-column:2;grid-row:2;min-width:0}
}
> div > .\\@container:not(:has([aria-label='Remove saved item'])) > .grid > .min-w-0{[data-slot=badge]{grid-column:1/-1}
[data-slot=badge]::after{content:none}
> .mt-1{grid-column:1/-1;grid-row:3;margin-top:0}
}
}
[data-overlay-surface] main [aria-label='Remove saved item']{width:28px;height:28px;color:var(--hq-label-3);svg{width:17px;height:17px}
&:hover{background:var(--hq-fill-3);color:var(--hq-red-text)}
}
#setting-field-memory\\.provider > section{padding:0;> :first-child{position:relative;min-height:32px;padding:11px 0;gap:16px;box-shadow:0 -.5px 0 var(--hq-sep);> button:first-child{display:grid;grid-template-columns:minmax(0,1fr);row-gap:2px;align-items:center;> span:not([data-slot]){grid-row:1}
> [data-slot=badge]{grid-row:2}
> i{position:absolute;right:0;top:50%;margin-top:-6.5px;width:13px;font-size:12px!important;line-height:13px;color:var(--hq-label-3);opacity:1}
}
[data-slot=badge]{padding:0;border:0;background:none;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-label-2)}
> [data-slot=button]{height:auto;margin-right:25px;padding:0;border:0;background:none;box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);svg{display:none}
}
}
> :nth-child(2){margin:0;padding:0;border-left:0;> *{border-bottom:0;box-shadow:0 -.5px 0 var(--hq-sep)}
}
.\\@container > .grid{grid-template-columns:minmax(0,1fr) minmax(10rem,16rem);align-items:center;column-gap:16px;> :last-child{justify-self:end;justify-content:flex-end;width:100%}
> :last-child > .flex-col{width:100%;align-items:flex-end;gap:0}
}
input[data-slot=input]{font-family:inherit;font-size:13px;letter-spacing:-.08px;text-overflow:ellipsis}
input[data-slot=input]:not(:focus){width:100%;color:var(--hq-label-2);text-align:right}
.font-mono{align-self:flex-end;font-family:inherit;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-label-2)}
.font-mono svg{color:var(--hq-green-text)}
.flex-col:has(> .font-mono){position:relative}
.flex-col:has(> .font-mono) > input:placeholder-shown:not(:focus)::placeholder{color:transparent}
.flex-col > input:placeholder-shown:not(:focus) + .font-mono{position:absolute;right:0;top:50%;transform:translateY(-50%);pointer-events:none;font-size:13px;line-height:18px;letter-spacing:-.08px}
.flex-col > input:is(:focus,:not(:placeholder-shown)) + .font-mono{display:none}
.flex-col > .font-mono svg{width:15px;height:15px}
}
[data-overlay-surface] main section > div:has(> #setting-field-notifications\\.enable-all){display:flex;flex-direction:column;> *{order:1}
> p:first-child{order:2;margin:8px 0 0;padding:0 16px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section)}
> div:not(.\\@container):has(> [data-slot=button]){order:3;gap:8px;margin-top:24px}
> div:not(.\\@container) > [data-slot=button]{justify-content:flex-start;width:100%;height:auto;min-height:32px;padding:0 16px;border:0;border-radius:var(--hq-card-r);background:var(--hq-cell);box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);&:hover{background:var(--hq-cell);box-shadow:inset 0 0 0 100vmax var(--hq-fill-4)}
svg{display:none}
}
> div:not(.\\@container) > p{padding:0 16px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section)}
html:root body & > .\\@container:not(:has(~ .\\@container)){margin-bottom:0}
}
#setting-field-notifications\\.completion-sound{[data-slot=select-trigger]{min-width:0;width:auto}
[data-slot=button][data-variant=outline]{height:auto;padding:0 0 0 12px;border:0;background:none;box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);&:hover{background:none;opacity:.7}
svg{display:none}
}
}
[data-overlay-surface] main:has(> div > nav[aria-label=Voice]) section > div{html:root body & > .\\@container:not([id]):not(:has(button,input,[role=switch])){order:2!important;margin:8px 0 0!important;padding:0 16px!important;border-radius:0!important;background:none!important;box-shadow:none!important;> .grid{display:block;padding:0!important;min-height:0!important}
.min-w-0{line-height:16px;font-size:12px}
.min-w-0 > *{display:inline;margin:0;font-size:12px;line-height:16px;font-weight:400;letter-spacing:-.08px;color:var(--hq-section)!important}
}
& > .\\@container:not([id]):not(:has(button,input,[role=switch])) .min-w-0 > :first-child::after{content:': '}
html:root body &:has(> .\\@container:not([id]) > .grid > .min-w-0:only-child){display:flex;flex-direction:column}
&:has(> .\\@container:not([id]) > .grid > .min-w-0:only-child) > *{order:1}
&:has(> .\\@container:not([id]) > .grid > .min-w-0:only-child) > :first-child{order:0}
}
#setting-field-advanced\\.keep-awake{.inline-grid:has(> button[aria-pressed]){width:auto;grid-auto-columns:max-content}
.inline-grid > button[aria-pressed]{padding:0 12px;font-size:12px;line-height:16px;letter-spacing:-.08px;font-weight:500}
html:root body [data-overlay-surface] & > .grid > :last-child{align-self:start;margin-top:-5px}
}
#setting-field-advanced\\.quick-entry-shortcut{input[data-slot=input]{min-width:17rem}
.min-w-0 > .mt-1 + .mt-1{margin-top:2px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-green-text)}
}
[data-overlay-surface] main:has(> div > nav[aria-label=Advanced]) section > div > .\\@container:not([id]) [data-slot=button][data-variant=outline]{height:auto;padding:0;border:0;background:none;box-shadow:none;font-size:13px;line-height:18px;font-weight:400;letter-spacing:-.08px;color:var(--hq-link);&:hover{background:none;opacity:.7}
}
[data-overlay-surface] main:has(> div > nav:is([aria-label=Advanced],[aria-label=Voice],[aria-label=Browser],[aria-label='Memory & Context'])) :is([id^=setting-field-],.\\@container) input[data-slot=input]:not(:focus):not([role=combobox]){text-overflow:ellipsis}
html:root body [data-overlay-surface] main:has(> div > nav:is([aria-label=Advanced],[aria-label='Passwords & Logins'],[aria-label=Notifications])) section > div > .\\@container + .\\@container{box-shadow:none!important;background-image:linear-gradient(var(--hq-sep),var(--hq-sep))!important;background-size:calc(100% - 16px) .5px!important;background-position:100% 0!important;background-repeat:no-repeat!important}
html:root body [data-overlay-surface] main:has(> div > nav:is([aria-label=Advanced],[aria-label=Browser],[aria-label=Voice],[aria-label='Memory & Context'])) section > div > .grid.gap-1{&:has(> [id^=setting-field-]:only-child){padding:0!important;background:none!important;box-shadow:none}
> [id^=setting-field-]:only-child > .\\@container > .grid{isolation:isolate;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:0;padding:0!important;min-height:0!important;&::before{content:'';grid-row:1;grid-column:1/-1;align-self:stretch;z-index:-1;border-radius:var(--hq-card-r);background:var(--hq-cell)}
> .min-w-0:first-child{display:contents;> :first-child{grid-row:1;grid-column:1;min-height:32px;padding:7px 12px 7px 14px;display:flex;align-items:center}
> .mt-1{grid-row:2;grid-column:1/-1;margin:8px 0 0;padding:0 16px;font-size:12px;line-height:16px;letter-spacing:-.08px;color:var(--hq-section);-webkit-line-clamp:none}
}
> :last-child:not(:first-child){grid-row:1;grid-column:2;align-self:center;align-items:center;padding-right:16px}
}
}
/* settings-c */
[data-overlay-surface] main{--s3: rgba(60,60,67,.3);--sd: #ff3b30;--so: #c93400;--sw: var(--hq-fill);--sf: -apple-system,system-ui,sans-serif;--sn: 400 12px/16px var(--sf);--sb: 400 13px/18px var(--sf);--ss: 400 12px/16px var(--sf);--sh: 600 13px/18px var(--sf);--sx: 0 -.5px 0 var(--hq-sep);--sl: var(--hq-label-2);--st: var(--hq-tint);--sr: var(--hq-card-r);--sk: var(--hq-cell);--sp: var(--foreground);:is(.mb-2\\.5.flex:has(> :is(.tabler-icon-package,.tabler-icon-credit-card,.tabler-icon-chart-bar)),.mb-2\\.5.flex:has(+ p.mb-2 + .grid > [id^=archived-session-]),section:has(.tabler-icon-device-floppy) > .mb-2\\.5,.mx-auto.mt-4.max-w-2xl > .mb-2\\.5.flex,section.grid.gap-2 > .flex.flex-wrap.items-baseline > .mb-3.flex,section.grid.gap-2:has(> .flex.flex-wrap.items-baseline) > p.mt-3){margin:0 0 6px;padding:0 16px;min-height:22px;align-items:baseline;font:var(--sh);letter-spacing:-.23px;color:var(--sl);> svg:first-child{display:none}
> [data-slot=badge]{padding:0;background:none;font:inherit;color:inherit}
}
:has(> p.mb-2 + * :is([id^=archived-session-],.codicon-plug,.tabler-icon-folder-open)){display:flex;flex-direction:column}
p.mb-2:has(+ * :is([id^=archived-session-],.codicon-plug,.tabler-icon-folder-open)),div:has(> .mt-6.border-t) > p:is(.mb-1,.mb-4),.border-destructive\\/30 > .flex-col > p.text-xs{order:1;margin:6px 0 0;padding:0 16px;font:var(--sn);letter-spacing:-.08px;color:var(--sl)}
:is(.mt-6.justify-end.gap-4,div:has(> .mt-6.border-t) > .mt-4.flex,section > .rounded-md > .flex-wrap.gap-2){flex-direction:column;align-items:stretch;gap:0;padding:0 16px;border-radius:var(--sr);background:var(--sk);> [data-slot=button]{justify-content:flex-start;min-height:32px;padding:0;gap:10px;border-radius:0;background:none;color:var(--st);font:var(--sb);letter-spacing:-.23px}
> [data-slot=button] + [data-slot=button]{box-shadow:var(--sx)}
> [data-slot=button]:is(.gap-4 > :last-child,:has(> .tabler-icon-device-floppy)){font-weight:600}
> [data-slot=button]:disabled{color:var(--sl)}
}
.mt-6.justify-end.gap-4{margin-top:0}
:is(section.grid.gap-2,[id^=archived-session-],section > .divide-y,div:has(> .mt-6.border-t) > .\\@container) button:has(> :is(.tabler-icon-trash,.tabler-icon-terminal-2,.tabler-icon-pencil)){min-width:30px;min-height:30px;> svg{width:18px;height:18px;color:var(--sl)}
}
section.grid.gap-2:has(> .flex.flex-wrap.items-baseline){> *{order:3}
> .flex.flex-wrap.items-baseline{order:0;padding-right:16px}
> button.group.flex.rounded-\\[6px\\]{order:1}
> p.mt-3{order:2}
> p.mt-3.mt-3.mt-3{margin-top:30px}
> p.-mt-2{order:4;margin:6px 0 0;font:var(--sn);letter-spacing:-.08px}
> [data-slot=button]:last-child{order:5;margin-top:30px;min-height:32px;justify-content:flex-start;padding:0 16px;border-radius:var(--sr);background:var(--sk);color:var(--st);font:var(--sb);letter-spacing:-.23px}
> .flex.flex-wrap.items-baseline > [data-slot=button]{color:var(--st);font-weight:400}
}
section.grid.gap-2{> :is(button.group.flex,div.group.grid).rounded-\\[6px\\] + :is(button.group.flex,div.group.grid).rounded-\\[6px\\]{border-top-left-radius:0;border-top-right-radius:0}
> button.group.flex.rounded-\\[6px\\]{padding:10px 14px;min-height:40px}
> .group.rounded-\\[6px\\]{button.min-w-0{padding:10px 14px}
p.text-muted-foreground{padding:0!important;margin-top:4px;font:var(--ss);letter-spacing:-.08px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
p.text-\\[0\\.68rem\\]{font:var(--sn);letter-spacing:-.08px;color:var(--sl);white-space:normal}
}
> div.group.grid.rounded-\\[6px\\]{> button.min-w-0{position:relative;padding-right:112px}
> div:last-child{display:grid;grid-template-columns:30px 30px 16px;justify-items:center;padding-right:16px;> *{grid-row:1}
> :is(svg,button):has(.tabler-icon-terminal-2),> .tabler-icon-terminal-2{grid-column:1}
> button:has(.tabler-icon-trash){grid-column:2}
> .tabler-icon-chevron-right{grid-column:3}
> .tabler-icon-terminal-2{width:18px;height:18px;color:var(--sl)}
}
}
span.bg-primary\\/10.text-primary{position:absolute;right:0;top:50%;transform:translateY(-50%);padding:0;background:none;font:var(--sb);letter-spacing:-.23px;color:var(--sl);> svg{display:none}
}
}
.bg-\\(--ui-yellow\\)\\/10{border-radius:var(--sr);background:var(--sk);padding:10px 14px;> .font-medium:first-child{font-weight:600;color:var(--so)}
> .mt-1{margin-top:2px}
> [data-slot=button]{margin-top:8px}
}
[data-slot=button]:is(.bg-\\(--ui-yellow\\)\\/10 *,.rounded-lg.p-4 *,.mb-2\\.5:has(+ p + * > button > .codicon-plug) *){padding:0;background:none;font:var(--sb);letter-spacing:-.23px;> :is(.tabler-icon-external-link,.codicon-arrow-right){display:none}
}
.mb-6:has(> * > * > .text-lg){padding-block:0!important;> .grid.gap-3{grid-template-columns:1fr!important;gap:0}
> .grid > .min-w-0:has(> .text-lg){display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:32px}
> .grid > .min-w-0 + .min-w-0{box-shadow:var(--sx)}
> .grid > .min-w-0 > *{margin:0;font:var(--sb);letter-spacing:-.23px;color:var(--sp)}
> .grid > .min-w-0 > .text-lg{color:var(--sl)}
}
.py-3:has(> * > [data-slot=progress]){grid-template-columns:minmax(0,1fr) auto!important;row-gap:8px;> .min-w-0:has(> [data-slot=progress]){grid-column:1/-1;grid-row:2}
> .min-w-0:last-child{grid-row:1;grid-column:2;width:auto!important;color:var(--sl)!important}
[data-slot=progress]{height:4px;background:var(--hq-fill)}
[data-slot=progress] > .bg-\\(--ui-green\\){background:var(--st)}
}
:is(section:has(> .mb-2\\.5 > .tabler-icon-credit-card),div:has(> .mt-6.border-t),.overflow-y-auto:has(#setting-field-gateway\\.connection-mode) .grid.gap-3) > .\\@container + .\\@container{box-shadow:none;background-image:linear-gradient(var(--hq-sep),var(--hq-sep));background-position:16px 0;background-size:calc(100% - 32px) .5px;background-repeat:no-repeat}
.mb-2\\.5.flex:has(> .tabler-icon-credit-card) .ml-auto [data-slot=button]{padding:0;font-weight:400;color:var(--st)}
section:has(> .mb-2\\.5 > :is(.tabler-icon-credit-card,.tabler-icon-package)) .grid.gap-3.py-3{> .min-w-0 > .mt-1{font:var(--ss)!important;letter-spacing:-.08px!important}
.opacity-50{opacity:1}
.opacity-50 > [aria-pressed=false],> .flex > [data-slot=button]:disabled{opacity:1;color:var(--s3)}
> .flex > [data-slot=button]{min-height:30px;padding:0 2px;background:none;font:var(--sb);letter-spacing:-.23px}
&:has(> .flex > .inline-grid){grid-template-columns:1fr!important;row-gap:10px;> .flex{justify-self:stretch!important;justify-content:flex-start;flex-wrap:nowrap}
> .flex > [data-slot=button]{margin-left:auto}
}
> .flex > [data-slot=badge]{padding:0;background:none;font-size:12px;font-weight:400}
[data-slot=input-group]{width:88px;height:30px;border-radius:999px;font-size:12px;> span{color:var(--sl)}
input{padding-left:2px;font-size:12px;text-align:left!important}
}
}
.mb-2\\.5:has(+ .grid > .rounded-lg.p-4){display:none}
.grid:has(> .rounded-lg.p-4.gap-3){grid-template-columns:1fr!important;gap:0;> .rounded-lg.p-4{display:grid;grid-template-columns:minmax(0,1fr) auto 124px;align-items:center;column-gap:16px;min-height:52px;padding:7px 14px;border-radius:0;background:linear-gradient(var(--hq-sep),var(--hq-sep)) 68px 0/calc(100% - 84px) .5px no-repeat,var(--sk)}
> .p-4:first-child{border-radius:var(--sr) var(--sr) 0 0;background:var(--sk)}
> .p-4:last-child{border-bottom-left-radius:var(--sr);border-bottom-right-radius:var(--sr)}
> * > :first-child{grid-column:1;.min-w-0 > :last-child{margin-top:1px}
}
> * > :nth-child(2):not(:last-child){grid-column:2;font:var(--sb);letter-spacing:-.23px}
> * > .mt-auto{grid-column:3;justify-self:end;padding:0;margin:0}
.rounded-md{border-radius:9px}
[data-slot=badge]{gap:6px;padding:0;background:none;font:var(--sb)}
[data-slot=badge]::before{content:'';width:5px;height:10px;margin:-3px 4px 0 0;border:solid currentColor;border-width:0 2px 2px 0;transform:rotate(45deg)}
}
#setting-field-gateway\\.connection-mode{padding:0;background:none;gap:0;> .font-medium:first-child{padding:0 16px 6px;font:var(--sh)}
> .grid{grid-template-columns:1fr!important;grid-auto-rows:auto;gap:0;padding:0 16px;border-radius:var(--sr);background:var(--sk)}
> .grid > button{min-height:32px;padding:11px 0;border:0;border-radius:0;background:none!important;--tw-ring-shadow:0 0 #0000;+ button{box-shadow:var(--sx)}
> .flex{gap:8px}
> .flex > svg:first-child{width:17px;height:17px;color:var(--sl)}
.tabler-icon-check{width:18px;height:18px;stroke-width:2.5}
> p{margin-top:2px;padding-left:25px}
}
}
.overflow-y-auto:has(#setting-field-gateway\\.connection-mode) .\\@container{.min-w-0 > .mt-1{font:var(--ss)!important;letter-spacing:-.08px!important}
}
.grid.gap-3.py-3:has(input[placeholder*='gateway.example']){grid-template-columns:1fr!important;row-gap:2px;cursor:text;> .min-w-0:first-child{display:contents}
> .min-w-0:first-child > :first-child{font:var(--ss);letter-spacing:-.08px;color:var(--sl)}
> .min-w-0:first-child > :not(:first-child){order:2}
> .flex{order:1;justify-self:stretch!important;max-width:none!important}
input{padding:0!important;border-radius:0;text-align:left!important;color:var(--sp)!important;caret-color:var(--st)}
}
.grid.gap-3.py-3 > .flex > .flex > [data-slot=badge].bg-primary\\/10{padding:0;background:none;font:var(--sb);letter-spacing:-.23px;color:var(--sl);> svg{width:15px;height:15px;stroke-width:2.5;color:var(--st)}
}
.bg-primary\\/10:has(> .tabler-icon-check) + [data-variant=outline]{padding:0 4px;background:none;font-size:13px;font-weight:400;color:var(--sd)}
div:has(> .mt-6.border-t){display:flex;flex-direction:column;> p.mb-4{margin-top:0}
> .mt-6.border-t{order:3;margin-top:30px;padding-top:0;border-top:0}
> .mt-4.flex{order:2;margin-top:30px}
> .mt-4.flex > [data-slot=button] > svg{width:18px;height:18px}
[data-slot=badge]{padding:0;margin-left:2px;background:none;font:var(--ss);letter-spacing:-.08px}
> .\\@container{margin-bottom:0!important;margin-right:0!important;.min-w-0 > .mt-1{font-size:12px!important;line-height:16px!important}
span.flex.items-center.gap-2:has(> [data-slot=badge]){align-items:baseline;gap:6px;> svg{align-self:center}
}
.flex.items-center.gap-2 > [data-slot=button]:first-child{order:1}
.flex.items-center.gap-2 > [data-slot=button]:not(:has(> svg:only-child)){min-height:30px;padding:0 4px;background:none;font:var(--sb);letter-spacing:-.23px}
}
}
.min-h-48.place-items-center{min-height:60vh;> div > .mt-1{font:var(--ss);letter-spacing:-.08px;color:var(--sl)}
}
.grid.gap-2 > .scroll-mt-6.rounded-\\[6px\\]{border-radius:0}
:is([id^=credential-key-],[id^=provider-key-]){.bg-\\(--ui-stroke-secondary\\){display:none}
.size-2.bg-primary{order:1;width:7px;height:7px}
.flex.items-center.gap-2 > span.truncate.font-medium{font-weight:400}
input::placeholder{color:var(--s3)}
.flex.items-center.gap-2 > svg{order:2}
@container (width < 42rem){.\\@container > .grid{grid-template-columns:minmax(0,1fr) minmax(8rem,45%);align-items:center}
}
@container (width >= 42rem){input.desktop-input-chrome:not(:focus){width:calc(100% + 10px);margin-right:-10px}
}
}
[id^=provider-key-] .grid:has(> input){column-gap:0}
.overflow-y-auto > button.group.grid.rounded-\\[6px\\]:has(> .flex-col > .font-semibold){width:100%}
section:has(> button.group\\/kbd-cat){> button.group\\/kbd-cat{padding:10px 16px 6px}
&:first-child > button.group\\/kbd-cat{padding-top:8px}
> button.group\\/kbd-cat > span{font:var(--sh);letter-spacing:-.23px}
> .flex.rounded-lg{min-height:32px;padding:0 16px;gap:12px;> span.flex-1{font:var(--sb);letter-spacing:-.23px;color:var(--sp)}
> :is(button[aria-label=Clear],span:empty:last-child){width:0;min-width:0;margin-left:-12px;overflow:hidden}
&:is(:hover,:focus-within) > button[aria-label=Clear]{width:24px;margin-left:0}
}
button[aria-label=Rebind]{gap:6px}
[data-slot=kbd-group]{gap:2px;height:22px;padding:0 8px;border-radius:6px;background:var(--hq-fill-3)}
[data-slot=kbd-group]:has(> [class*='_38%']){padding:0;background:none}
[data-slot=kbd]{width:auto;min-width:0;height:auto;padding:0;border:0;border-radius:0;background:none;box-shadow:none;font:var(--ss);color:var(--sp)}
[data-slot=kbd][class*='_38%']{padding:0;background:none;color:var(--st);text-transform:capitalize}
}
.pb-3:has(> button.text-\\[0\\.72rem\\]){padding:0 16px 12px;align-items:baseline;p{font:var(--sn);color:var(--sl)}
> button{font-size:12px;color:var(--st)}
}
[id^=archived-session-]{.min-w-0 > div.mt-1:not(.font-mono){font-size:12px!important;line-height:16px!important}
.font-mono.text-\\[0\\.68rem\\]{font-family:var(--sf)}
.flex.items-center.gap-1\\.5{gap:12px}
}
:is([id^=archived-session-],.overflow-y-auto:has(#setting-field-gateway\\.connection-mode) .\\@container) [data-variant=textStrong],.\\@container [data-slot=button]:has(> .tabler-icon-folder-open){padding:0;font:var(--sb);letter-spacing:-.23px;color:var(--st);> svg{display:none}
}
.mb-6:has(> p.mb-2 + .\\@container .tabler-icon-folder-open) > .\\@container{margin-bottom:0!important;.mt-1{font:var(--ss)}
}
.grid:has(> button > .codicon-plug){margin-top:0;padding:0 16px;border:0;border-radius:var(--sr);background:var(--sk);> button{min-height:32px;padding:0}
> button > .codicon-plug{display:none}
> button > .codicon-chevron-right{font-size:13px!important;color:color-mix(in srgb,var(--sp) 57%,transparent)}
}
.mb-2\\.5:has(+ p + * > button > .codicon-plug){order:2;margin:30px 0 0;padding:0 16px;min-height:32px;border-radius:var(--sr);background:var(--sk);> .ml-auto{margin-left:0}
}
.mx-auto.max-w-2xl:is(.mt-4,:has(> .border-destructive\\/30)){max-width:none}
.bg-muted\\/20.border{p.font-medium{font:var(--sb);letter-spacing:-.23px}
p.mt-1.text-xs{margin-top:2px;font:var(--ss);letter-spacing:-.08px;color:var(--sl)}
.tabler-icon-circle-check{width:18px;height:18px;color:var(--hq-green)}
> .mt-3.flex{margin:11px 0 -12px;min-height:30px;justify-content:space-between;box-shadow:var(--sx);[data-slot=button]{min-height:30px;padding:0;font:var(--sb);letter-spacing:-.23px;color:var(--st);> svg{width:15px;height:15px;color:var(--s3)}
> .tabler-icon-refresh{display:none}
}
a[data-slot=button]{flex-direction:row-reverse}
}
}
.mx-auto.max-w-2xl > dl.rounded-lg.border{padding-block:0;> div{min-height:32px;align-items:center;padding-block:0;font:var(--sb);letter-spacing:-.23px}
> div > dt{color:var(--sp)}
> div > dd{color:var(--sl)}
> div > dd:is(.font-mono,:has(.font-mono)),> div > dd .font-mono{font:var(--sb);letter-spacing:-.23px}
> div > dd.font-mono{overflow:hidden;white-space:nowrap;text-overflow:ellipsis;word-break:normal;min-width:0}
}
.border-destructive\\/30{padding:0!important;background:none!important;> .flex-col{gap:0}
> .flex-col > p.font-medium{padding:0 16px 6px;color:var(--sl)}
> .flex-col > .mt-1.flex-col{padding:0 16px;border-radius:var(--sr);background:var(--sk)}
.mt-1.flex-col > button{min-height:32px;> svg{margin-top:3px;width:18px;height:18px;color:var(--sd)}
.font-medium{font-weight:400;color:var(--sd)}
.text-xs{font:var(--ss);letter-spacing:-.08px;color:var(--sl)}
}
}
.mb-2\\.5:has(> [data-slot=badge]:only-child):has(+ .divide-y){display:none}
section > .divide-y.rounded-md{padding:0 16px;> .grid.p-3{padding-inline:0;border-color:var(--hq-sep)}
:is(.font-semibold,.font-medium){font:var(--sb);letter-spacing:-.23px}
.font-mono{margin-top:2px;font:var(--ss);letter-spacing:-.08px;color:var(--sl)}
.mt-1.flex.text-xs{margin-top:2px;color:var(--sl)}
[data-slot=button]:has(> .tabler-icon-bolt){padding:0 4px!important;background:none;> svg{display:none}
}
}
.mt-6.justify-center > [data-slot=button]{min-height:30px;padding:0 20px;font:var(--sh);letter-spacing:-.23px}
.max-w-md.text-center > p.mt-2{font-size:12px;color:var(--sl)}
section > .grid.rounded-md.border:has(.tabler-icon-device-floppy){gap:0;padding:0 16px;> .grid.gap-3,> div.grid{grid-template-columns:minmax(0,1fr)!important;gap:0}
label.grid{grid-template-columns:max-content minmax(0,1fr);align-items:center;column-gap:16px;min-height:32px;text-indent:0!important;font:var(--sb);letter-spacing:-.23px;color:var(--sp)}
label.grid,fieldset,> .flex.flex-wrap{box-shadow:var(--sx)}
> :first-child > label.grid:first-child{box-shadow:none}
input.desktop-input-chrome{height:40px;padding:0!important;border:0;border-radius:0;background:none!important;text-align:right;color:var(--sl);caret-color:var(--st)}
input::placeholder{color:var(--s3)}
[data-slot=popover-anchor] input{padding-right:24px!important}
fieldset{display:flow-root;padding:10px 0;font:var(--sb);letter-spacing:-.23px;color:var(--sp);> legend{float:left;margin:0;text-indent:0;font-size:13px;line-height:32px;color:var(--sp)}
> .inline-grid{float:right;grid-auto-columns:auto;width:auto!important;max-width:calc(100% - 96px)!important;> button{padding:0 10px}
}
}
> .flex.flex-wrap.items-center.gap-4{flex-direction:column;align-items:stretch;gap:0;> label{flex-direction:row-reverse;justify-content:space-between;min-height:32px;font:var(--sb);letter-spacing:-.23px;color:var(--sp)}
> label + label{box-shadow:var(--sx)}
[data-slot=checkbox]{position:relative;width:46px;height:20px;border:0;background:var(--sw)!important;> *{visibility:hidden}
&::before{content:'';position:absolute;top:2px;left:2px;width:26px;height:16px;border-radius:999px;background:#fff;box-shadow:var(--hq-thumb-shadow)}
&[data-state=checked]{background:var(--hq-green)!important;&::before{left:18px}
}
}
}
> .flex.flex-wrap.gap-2{padding:0}
}
}
html.dark [data-overlay-surface] main{--s3:rgba(235,235,245,.3);--sd:#ff453a;--so:#ff9f0a;--sw:var(--hq-fill-2)}
`

export const THEME = {
  name: 'hermes-hq',
  label: 'Hermes HQ',
  description: 'The Hermes HQ iPhone look: iOS colours, system blue, round shapes',
  typography: { fontSans: SYSTEM_SANS, fontMono: SYSTEM_MONO },
  colors: LIGHT,
  darkColors: DARK,
  customCSS: CSS,
}

// Nous High Contrast: desktop's own Nous palette (@hermes/shared theme-presets.ts, copied: a plugin can't import it)
// with Hermes HQ's High Contrast option (src/phone-ui-contrast.css) on top. Every value below is mixed from the
// theme's own text, page and accent, as the phone does: lines and secondary text pulled toward the text colour, boxes
// lifted off the page, your messages tinted with the accent and outlined. The palette is set inline on <html>, so these
// go on <body>, where everything inherits them.
export const NOUS_LIGHT = {
  background: '#ffffff', foreground: '#1f2328', card: '#f6f8fa', cardForeground: '#1f2328',
  muted: '#f6f6f6', mutedForeground: '#656d76', popover: '#ffffff', popoverForeground: '#1f2328',
  primary: '#0053fd', primaryForeground: '#ffffff', secondary: '#deeaff', secondaryForeground: '#1f2328',
  accent: '#e3edff', accentForeground: '#1f2328', border: '#d0d7de', input: '#ffffff', ring: '#0053fd',
  midground: '#0053fd', midgroundForeground: '#ffffff', composerRing: '#0053fd',
  destructive: '#cf222e', destructiveForeground: '#ffffff',
  sidebarBackground: '#f6f8fa', sidebarBorder: '#d0d7de', userBubble: '#dae7fd', userBubbleBorder: '#d0d7de',
}
export const NOUS_DARK = {
  background: '#0d1117', foreground: '#e6edf3', card: '#010409', cardForeground: '#e6edf3',
  muted: '#1a1e24', mutedForeground: '#7d8590', popover: '#161b22', popoverForeground: '#e6edf3',
  primary: '#4a84fe', primaryForeground: '#161616', secondary: '#1d2e4f', secondaryForeground: '#e6edf3',
  accent: '#17243a', accentForeground: '#e6edf3', border: '#30363d', input: '#0d1117', ring: '#4a84fe',
  midground: '#4a84fe', midgroundForeground: '#161616', composerRing: '#4a84fe',
  destructive: '#f85149', destructiveForeground: '#ffffff',
  sidebarBackground: '#010409', sidebarBorder: '#30363d', userBubble: '#07162c', userBubbleBorder: '#30363d',
}

export const CONTRAST_CSS = `
body {
  --hc-ink:var(--theme-foreground);--hc-page:var(--theme-background-seed);--hc-accent:var(--theme-midground);
  /* Lines: the text colour at a fixed share, about twice the theme's own (harder ones read as too much). */
  --ui-stroke-primary:color-mix(in srgb,var(--hc-ink) 18%,transparent);
  --ui-stroke-secondary:color-mix(in srgb,var(--hc-ink) 13%,transparent);
  --ui-stroke-tertiary:color-mix(in srgb,var(--hc-ink) 10%,transparent);
  --dt-border:var(--ui-stroke-secondary);--dt-input:var(--ui-stroke-primary);--dt-sidebar-border:var(--ui-stroke-tertiary);
  /* Secondary and tertiary text: a step toward the text colour. */
  --ui-text-secondary:color-mix(in oklab,var(--hc-ink) 82%,var(--hc-page));
  --ui-text-tertiary:color-mix(in oklab,var(--hc-ink) 64%,var(--hc-page));
  /* Boxes (cards, code, the message bar's field) lifted clearly off the page. */
  --ui-bg-editor:color-mix(in oklab,var(--hc-ink) 10%,var(--hc-page));
  --ui-bg-card:var(--ui-bg-editor);
  /* A selected row: the accent, so it never reads as just another surface. */
  --ui-row-active-background:color-mix(in oklab,var(--hc-accent) 22%,var(--hc-page));
  /* Your messages: the accent's tint with an accent outline. */
  --dt-user-bubble:color-mix(in oklab,var(--hc-accent) 28%,var(--hc-page));
  --dt-user-bubble-border:color-mix(in oklab,var(--hc-accent) 75%,var(--hc-page));
}
/* Light pages show a tint far more than dark ones: lighter fills, the same lines. */
html:not(.dark) body {
  --ui-bg-editor:color-mix(in oklab,var(--hc-ink) 5%,var(--hc-page));
  --ui-row-active-background:color-mix(in oklab,var(--hc-accent) 14%,var(--hc-page));
  --dt-user-bubble:color-mix(in oklab,var(--hc-accent) 13%,var(--hc-page));
  --dt-user-bubble-border:color-mix(in oklab,var(--hc-accent) 65%,var(--hc-page));
}
/* The chat keeps the strong treatment: your message and the message bar get a full-strength outline. */
[data-slot='aui_user-message-root'] .composer-human-message {border-color:var(--dt-user-bubble-border)}
[data-slot='composer-surface'] {border-color:color-mix(in srgb,var(--hc-ink) 50%,transparent)}
`

const NOUS_SANS = '"Segoe WPC", "Segoe UI", -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif, "Apple Color Emoji"'
const NOUS_MONO = '"JetBrains Mono", "Cascadia Code", "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Noto Mono", "SF Mono", ui-monospace, Menlo, Monaco, Consolas, monospace, "Apple Color Emoji"'

export const NOUS_HIGH_CONTRAST = {
  name: 'nous-high-contrast',
  label: 'Nous High Contrast',
  description: 'Nous with Hermes HQ’s High Contrast: clearer lines and text, your messages outlined in blue',
  typography: { fontSans: NOUS_SANS, fontMono: NOUS_MONO },
  colors: NOUS_LIGHT,
  darkColors: NOUS_DARK,
  customCSS: CONTRAST_CSS,
}

// Newer looks without reinstalling. This copy paints first; then, once per launch, the theme reads the newest published
// look (latest.json beside this file on GitHub, written from this file by scripts/desktop-theme-latest.mjs) and
// switches to it when its version is above this copy's. Only data is taken (palette values, fonts and CSS, never code),
// and a look that is malformed or whose CSS would load anything from elsewhere is ignored. The last good look is kept in
// this computer's storage, so the next launch paints it at once, offline too. A published version at or below this
// copy's (a rollback, or a newer copy installed here) drops the kept one. Bump VERSION with every change to the look.
export const VERSION = 9
export const LATEST_URL = 'https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/desktop-plugin/hermes-hq-theme/latest.json'
const KEPT = 'hermes-hq-theme.latest'
const IDS = new Set([THEME.name, NOUS_HIGH_CONTRAST.name])
const MAX_CSS = 192 * 1024
// Anything in the CSS that could fetch from elsewhere: url(), @import, image-set(), @font-face, src().
const LOADS = /url\s*\(|@import|image-set\s*\(|@font-face|\bsrc\s*\(/i
const plainText = (value, max) => typeof value === 'string' && value.length <= max && !/[;{}<>]/.test(value)

const palette = value => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  const entries = Object.entries(value)
  if (entries.length > 64 || !entries.every(([key, v]) => /^\w{1,40}$/.test(key) && plainText(v, 64))) return null
  return Object.fromEntries(entries)
}

const theme = value => {
  if (!value || typeof value !== 'object' || !IDS.has(value.name) || !plainText(value.label, 80)) return null
  if (value.description != null && !plainText(value.description, 300)) return null
  const colors = palette(value.colors), darkColors = palette(value.darkColors)
  if (!colors || !darkColors) return null
  const typography = value.typography ?? {}
  if (!['fontSans', 'fontMono'].every(key => typography[key] == null || plainText(typography[key], 400))) return null
  const css = value.customCSS ?? ''
  if (typeof css !== 'string' || css.length > MAX_CSS || LOADS.test(css)) return null
  return {
    name: value.name, label: value.label, description: value.description ?? '',
    typography: { fontSans: typography.fontSans, fontMono: typography.fontMono },
    colors, darkColors, customCSS: css,
  }
}

/** A published look as `{version, themes}`, rebuilt from the allowed fields only; null when anything is off. */
export function readLook(value) {
  if (!value || typeof value !== 'object' || !Number.isInteger(value.version) || value.version < 1) return null
  if (!Array.isArray(value.themes) || value.themes.length < 1 || value.themes.length > IDS.size) return null
  const themes = value.themes.map(theme)
  if (themes.some(t => !t) || new Set(themes.map(t => t.name)).size !== themes.length) return null
  return { version: value.version, themes }
}

const kept = () => {
  try { return readLook(JSON.parse(localStorage.getItem(KEPT) ?? 'null')) } catch { return null }
}
const keep = look => {
  try { look ? localStorage.setItem(KEPT, JSON.stringify(look)) : localStorage.removeItem(KEPT) } catch {}
}

export default {
  id: 'hermes-hq-theme',
  name: 'Hermes HQ theme',
  description: 'Adds the Hermes HQ themes: the iPhone app’s look, and Nous with its High Contrast option.',
  register(ctx) {
    const paint = themes => { for (const t of themes) ctx.register({ id: t.name, area: 'themes', title: t.label, data: t }) }
    const bundled = [THEME, NOUS_HIGH_CONTRAST]
    paint(bundled)
    let shown = kept()
    if (shown && shown.version > VERSION) paint(shown.themes)
    else { keep(null); shown = null }

    if (typeof fetch !== 'function') return
    const abort = new AbortController()
    let gone = false
    ctx.onDispose(() => { gone = true; abort.abort() })
    const stop = setTimeout(() => abort.abort(), 15000)
    fetch(LATEST_URL, { cache: 'no-store', signal: abort.signal })
      .then(response => (response.ok ? response.json() : null))
      .then(value => {
        const look = readLook(value)
        if (gone || !look) return
        if (look.version > VERSION) {
          if (JSON.stringify(look) !== JSON.stringify(shown)) paint(look.themes)
          keep(look)
        } else if (shown) {
          paint(bundled)
          keep(null)
        }
      })
      .catch(() => {})
      .finally(() => clearTimeout(stop))
  },
}
