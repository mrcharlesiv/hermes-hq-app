#!/usr/bin/env python3
"""[m9/ipad] Static checks for the iPad layout (docs/spec/3x-ipad.md §7.3). Exit 1 on a finding.

  python3 scripts/check-ipad.py

(a) every app / extension target in project.yml (and project-original.yml) has TARGETED_DEVICE_FAMILY "1,2", or
    $(HQ_DEVICE_FAMILY) with its universal row "1,2" (the App Store build's iphone row is project-appstore.yml's choice);
(b) App/Info.plist has the ~ipad orientations and no UIRequiresFullScreen;
(c) no UIScreen.main and no `.screen.bounds` under App/ outside an allow-list (layout reads the view's own size);
(d) every `.actionSheet` alert and UIActivityViewController has a popover anchor near it (an unanchored one crashes on iPad);
(e) no `topViewController as? ChatViewController` outside App/Root (use MainTabController.chatOnShow / paneChat);
(f) no `rootViewController is MainTabController` / `as? MainTabController` (use AppRoot / MainTabController.current);
(g) the new files hold no user-facing string with the banned product word;
(i) Bot Info, Settings, New Bot, Group Info, the Kanban task, the chat's sheets and the smaller pickers present through
    SheetStyle (a form sheet in two panes).
"""
import pathlib, plistlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
findings = []
def find(msg): findings.append(msg)

# (a)
for name in ['project.yml', 'project-original.yml']:
    text = (ROOT / name).read_text()
    target = None; kind = {}; family = {}
    row = re.search(r'^\s+HQ_DEVICE_FAMILY_universal:\s*"?([\d,]+)"?', (ROOT / 'project.yml').read_text(), re.M)
    universal = row.group(1) if row else None
    in_targets = False
    for line in text.splitlines():
        if re.match(r'^targets:\s*$', line): in_targets = True; continue
        if in_targets and re.match(r'^\S', line): in_targets = False
        if not in_targets: continue
        m = re.match(r'^  (\w+):\s*$', line)
        if m: target = m.group(1); continue
        m = re.match(r'^\s+type:\s*(\S+)', line)
        if m and target: kind[target] = m.group(1)
        m = re.match(r'^\s+TARGETED_DEVICE_FAMILY:\s*"?([\d,]+|\$\(HQ_DEVICE_FAMILY\))"?', line)
        if m and target: family[target] = universal if m.group(1) == '$(HQ_DEVICE_FAMILY)' else m.group(1)
    for t, k in kind.items():
        if k in ('application', 'app-extension') and family.get(t) != '1,2':
            find(f'(a) {name}: target {t} ({k}) has TARGETED_DEVICE_FAMILY {family.get(t)!r}, needs "1,2"')

# (b)
plist_text = (ROOT / 'App/Info.plist').read_text()
if 'UISupportedInterfaceOrientations~ipad' not in plist_text: find('(b) App/Info.plist lacks UISupportedInterfaceOrientations~ipad')
else:
    block = plist_text.split('UISupportedInterfaceOrientations~ipad', 1)[1].split('</array>', 1)[0]
    for o in ['Portrait<', 'PortraitUpsideDown', 'LandscapeLeft', 'LandscapeRight']:
        if 'UIInterfaceOrientation' + o not in block: find(f'(b) App/Info.plist ~ipad orientations lack {o.rstrip("<")}')
if 'UIRequiresFullScreen' in plist_text: find('(b) App/Info.plist has UIRequiresFullScreen (Split View and Stage Manager need it absent)')

# (c)-(f)
SCREEN_OK = {'App/Chat/Debug/ChatPerfProbe.swift', 'App/Chat/ChatViewController.swift', 'App/Settings/ToolCallsSettingsView.swift'}
ANCHOR = re.compile(r'popoverPresentationController|sourceView:|sourceItem|popover\.')
for path in sorted((ROOT / 'App').rglob('*.swift')):
    rel = str(path.relative_to(ROOT))
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        code = line.split('//', 1)[0]
        if rel not in SCREEN_OK and (re.search(r'UIScreen\.main', code) or re.search(r'\.screen\.bounds', code)):
            find(f'(c) {rel}:{i + 1}: lays out from the screen; use the view\'s or the window\'s own size')
        if re.search(r'preferredStyle:\s*\.actionSheet|UIActivityViewController\(', code):
            window = '\n'.join(lines[max(0, i - 3):i + 45])
            if not ANCHOR.search(window): find(f'(d) {rel}:{i + 1}: an action sheet or share sheet with no popover anchor nearby')
        if 'topViewController as? ChatViewController' in code and not rel.startswith('App/Root/'):
            find(f'(e) {rel}:{i + 1}: use MainTabController.chatOnShow or UINavigationController.paneChat')
        if re.search(r'rootViewController (is|as\?) MainTabController', code) and rel != 'App/Root/PaneRouter.swift':
            find(f'(f) {rel}:{i + 1}: the root may be the two-pane root; use AppRoot / MainTabController.current')

# (g)
NEW = ['HermesKit/Layout/PaneLayout.swift', 'HermesKit/Layout/KeyRules.swift', 'App/Root/RootSplitController.swift',
       'App/Root/PaneRouter.swift', 'App/Root/DetailPlaceholderViewController.swift', 'App/Root/KeyCommands.swift',
       'App/Kit/PointerEffects.swift']
for rel in NEW:
    path = ROOT / rel
    if not path.exists(): find(f'(g) missing {rel}'); continue
    for i, line in enumerate(path.read_text().splitlines()):
        for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', line.split('//', 1)[0]):
            if 'dispatch' in literal.lower(): find(f'(g) {rel}:{i + 1}: a string says the banned word')

# (h) user-facing wording names the device through DeviceWord ("iPhone" on a phone, "iPad" on an iPad)
DEVICE_OK = {'Shared/DeviceWord.swift', 'App/AppDelegate.swift', 'HermesKit/Model/RosterPreview.swift', 'HermesKit/Pages/JobWords.swift'}
# [mac-audit #12] 2026-11-02: word-capitalisation tables spell the brand word itself ("iphone" -> "iPhone"); only the bare
# word, only in these files, so a sentence naming the device there is still caught.
WORD_TABLES = {'HermesKit/Settings/DisplayName.swift', 'HermesKit/Voice/LiveWordsTidy.swift'}
for base in ['App', 'HermesKit', 'Shared', 'NotificationService']:
    for path in sorted((ROOT / base).rglob('*.swift')):
        rel = str(path.relative_to(ROOT))
        if rel in DEVICE_OK or '/Debug/' in rel: continue
        for i, line in enumerate(path.read_text().splitlines()):
            if line.strip().startswith('//'): continue
            for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', line):
                if literal == 'iPhone' and rel in WORD_TABLES: continue
                if 'iPhone' in literal: find(f'(h) {rel}:{i + 1}: a string says "iPhone"; use \\(DeviceWord.name)')

# (i) the phone-shaped sheets are a centred form sheet in two panes (§4.8, D6): they go through SheetStyle
FORM_SHEETS = ['App/BotInfo/BotInfoSheet.swift', 'App/Settings/SettingsScreens.swift', 'App/Bots/NewBotViewController.swift',
               'App/Groups/GroupInfoSheet.swift', 'App/Pages/Kanban/KanbanTaskSheet.swift',
               # UX study #161: the chat's sheets, the pickers, Add Gateway and New Webhook too. Left out on purpose:
               # the audio preview (sized to its player), Talk's intro and the offline screen's sign-in (no tabs).
               'App/Chat/ChatSheets.swift', 'App/Chat/Menus/MenusSheets.swift', 'App/Chat/Menus/SelectTextViewController.swift',
               'App/Groups/GroupBotsPicker.swift', 'App/Groups/AddToGroupController.swift', 'App/Gateways/AddGatewayFlow.swift',
               'App/Pages/More/Webhooks/WebhooksPages.swift']
for rel in FORM_SHEETS:
    text = (ROOT / rel).read_text()
    if 'SheetStyle.apply' not in text: find(f'(i) {rel}: present its sheet through SheetStyle.apply (a form sheet in two panes)')
    for i, line in enumerate(text.splitlines()):
        if re.search(r'modalPresentationStyle\s*=\s*\.pageSheet', line.split('//', 1)[0]):
            find(f'(i) {rel}:{i + 1}: a bare .pageSheet; use SheetStyle.apply')

if findings:
    print('\n'.join(findings)); print(f'check-ipad: {len(findings)} finding(s)'); sys.exit(1)
print('check-ipad: ok')
