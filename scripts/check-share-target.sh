#!/bin/zsh
# [share] Checks the Share extension inside a built Hermes HQ app (docs/spec/3x-share.md §7.1 checks 1-2, §4.3):
# it is embedded, carries the right bundle id, the app's versions, the display name people see, exactly the five
# activation keys, the App Group and exactly one Keychain group (the app's own), its privacy manifest, and, in a
# Release build, no trace of the DEBUG-only debug.json hook.
#
#   scripts/check-share-target.sh build/dd/Build/Products/Debug-iphonesimulator/HermesHQNative.app
#   scripts/check-share-target.sh path/to/HermesHQ.xcarchive/Products/Applications/HermesHQNative.app
#
# Reads only. A simulator build keeps its entitlements beside the build (…-Simulated.xcent); a signed build is asked
# through codesign.
set -e
APP=${1:?usage: scripts/check-share-target.sh <path to the built .app>}
[[ -d $APP ]] || { echo "check-share-target: no app at $APP"; exit 1; }
python3 - "$APP" <<'PY'
import os, plistlib, re, subprocess, sys

app = os.path.abspath(sys.argv[1])
appex = os.path.join(app, 'PlugIns', 'HermesHQShare.appex')
problems = []


def need(ok, what):
    if not ok:
        problems.append(what)


def plist(path):
    with open(path, 'rb') as handle:
        return plistlib.load(handle)


if not os.path.isdir(appex):
    print('check-share-target: FAILED\n  no PlugIns/HermesHQShare.appex in ' + app)
    sys.exit(1)
host, share = plist(os.path.join(app, 'Info.plist')), plist(os.path.join(appex, 'Info.plist'))
need(host.get('CFBundleIdentifier') == 'com.charlesmcdowell.dispatch', f"app bundle id is {host.get('CFBundleIdentifier')}")
need(share.get('CFBundleIdentifier') == 'com.charlesmcdowell.dispatch.share', f"extension bundle id is {share.get('CFBundleIdentifier')}")
for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
    need(share.get(key) == host.get(key), f"{key}: extension {share.get(key)} != app {host.get(key)}")
need(share.get('CFBundleDisplayName') == 'Hermes HQ', f"display name is {share.get('CFBundleDisplayName')!r}")
need(share.get('CFBundlePackageType') == 'XPC!', 'not an extension package')
for key in ('HQAppGroup', 'HQKeychainService'):
    need(share.get(key) and share.get(key) == host.get(key), f"{key}: extension {share.get(key)!r} != app {host.get(key)!r}")
extension = share.get('NSExtension') or {}
need(extension.get('NSExtensionPointIdentifier') == 'com.apple.share-services', 'not a share-services extension')
need(extension.get('NSExtensionPrincipalClass') == 'ShareViewController', f"principal class is {extension.get('NSExtensionPrincipalClass')!r}")
need('NSExtensionMainStoryboard' not in extension, 'a storyboard is named')
rule = (extension.get('NSExtensionAttributes') or {}).get('NSExtensionActivationRule')
wanted = {'NSExtensionActivationSupportsText': True, 'NSExtensionActivationSupportsWebURLWithMaxCount': 1,
          'NSExtensionActivationSupportsImageWithMaxCount': 10, 'NSExtensionActivationSupportsMovieWithMaxCount': 10,
          'NSExtensionActivationSupportsFileWithMaxCount': 10}
need(rule == wanted, f'activation rule is {rule!r}')
need(os.path.isfile(os.path.join(appex, 'PrivacyInfo.xcprivacy')), 'no PrivacyInfo.xcprivacy in the extension')
binary = os.path.join(appex, share.get('CFBundleExecutable') or 'HermesHQShare')
need(os.path.isfile(binary), 'no executable in the extension')
text = ' '.join(str(share.get(key) or '') for key in ('CFBundleDisplayName', 'NSLocalNetworkUsageDescription'))
need('dispatch' not in text.lower(), 'a visible string says "Dispatch"')


def entitlements(bundle, name):
    """A signed build's own entitlements, else the simulator build's (kept beside the build products)."""
    found = {}
    try:
        raw = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', bundle], capture_output=True, timeout=60).stdout
        if raw.strip():
            found = plistlib.loads(raw)
    except Exception:
        found = {}
    if found.get('com.apple.security.application-groups'):
        return found, 'signed'
    match = re.match(r'(.*)/Build/Products/([^/]+)/[^/]+\.app$', app)
    if match:
        for project in os.listdir(os.path.join(match.group(1), 'Build', 'Intermediates.noindex')):
            path = os.path.join(match.group(1), 'Build', 'Intermediates.noindex', project, match.group(2), name + '.build',
                                os.path.basename(bundle) + '-Simulated.xcent')
            if os.path.isfile(path):
                return plist(path), 'simulated'
    return found, 'none'


share_rights, kind = entitlements(appex, 'HermesHQShare')
groups = share_rights.get('com.apple.security.application-groups') or []
keychain = share_rights.get('keychain-access-groups') or []
need(kind != 'none', 'the extension has no readable entitlements')
need(groups == ['group.com.charlesmcdowell.dispatch'], f'App Groups are {groups!r}')
need(len(keychain) == 1 and re.fullmatch(r'[A-Z0-9]{10}\.com\.charlesmcdowell\.dispatch', keychain[0] if keychain else ''),
     f'Keychain groups are {keychain!r}')
identifier = share_rights.get('application-identifier') or ''
if keychain and identifier:
    need(identifier == keychain[0] + '.share', f'application-identifier {identifier!r} is not the Keychain group plus .share')
host_rights, host_kind = entitlements(app, 'HermesHQNative')
if host_kind != 'none':
    need('group.com.charlesmcdowell.dispatch' in (host_rights.get('com.apple.security.application-groups') or []),
         'the app is not in the App Group')
    if keychain and host_rights.get('application-identifier'):
        need(host_rights['application-identifier'] == keychain[0],
             f"the extension's Keychain group is not the app's identifier ({host_rights['application-identifier']})")

release = '/Debug-' not in app
if os.path.isfile(binary):
    with open(binary, 'rb') as handle:
        data = handle.read()
    if release:
        need(b'debug.json' not in data, 'a Release extension still holds the DEBUG-only debug.json hook')
    for banned in (b'SecItemAdd', b'SecItemDelete'):
        need(banned not in data, f'the extension links {banned.decode()}')

if problems:
    print('check-share-target: FAILED')
    for line in problems:
        print('  ' + line)
    sys.exit(1)
print(f"check-share-target: ok ({share.get('CFBundleIdentifier')} {share.get('CFBundleShortVersionString')} ({share.get('CFBundleVersion')}), "
      f"entitlements {kind}, {'Release' if release else 'Debug'} checks)")
PY
