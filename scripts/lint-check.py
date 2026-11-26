#!/usr/bin/env python3
"""Fast static lint gate mirroring Xcode lint tests and Python migration/safety checks."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def resolve_root() -> Path:
    if os.environ.get("HQ_REPO"):
        return Path(os.environ["HQ_REPO"]).resolve()
    if "__file__" in globals():
        candidate = Path(__file__)
        if candidate.name != "<stdin>" and candidate.exists():
            return candidate.resolve().parent.parent
    return Path.cwd().resolve()


def rel_posix(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def iter_swift_files(root: Path, folders: list[str]) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for folder in folders:
        base = root / folder
        if not base.exists():
            continue
        for p in sorted(base.rglob("*.swift")):
            if p.is_file():
                files.append((p, rel_posix(p, root)))
    return files


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def is_comment_line(line: str) -> bool:
    return line.lstrip().startswith("//")


# --- A11yLintTests ---

RE_FIXED_FONT = re.compile(
    r"(\.system\(size:|systemFont\(ofSize:|monospacedSystemFont\(ofSize:|monospacedDigitSystemFont\(ofSize:)\s*[0-9]"
)
FIXED_FONT_ALLOWED = ("UIFontMetrics", "HQFont", "a11y-font-ok", "pointSize", "scaledValue")

RE_DIRECT_A11Y_SETTING = re.compile(
    r"UIAccessibility\.(is[A-Z][A-Za-z]+Enabled|is[A-Z][A-Za-z]+Running|buttonShapesEnabled|prefersCrossFadeTransitions)"
)
RE_DIRECT_A11Y_ANNOUNCE = re.compile(r"UIAccessibility\.post\(notification:\s*\.announcement")

RE_MOTION = re.compile(
    r"UIView\.animate|UIView\.transition|UIViewPropertyAnimator\(|withAnimation\(|withAnimation \{|\.animation\(|CASpringAnimation\(|CABasicAnimation\(|CAKeyframeAnimation\(|CADisplayLink\(|\.transition\("
)
RE_MOTION_TOKEN = re.compile(r"HQMotion\.(hover|quick|fade|pane|move)\b")
MOTION_GUARDS = ("HQMotion", "hqMotion", "reduced", "reduceMotion", "ReduceMotion", "motion-ok")

RE_SPOKEN_LABEL = re.compile(r'accessibility(Label|Hint|Value)\s*(=|\()\s*(Text\()?"([^"\\]*)"')
RE_DOTTED_ID = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)+$")
RE_BANNED_LINE = re.compile(r'accessibility(Label|Hint|Value|CustomAction).*"[^"]*[Dd]ispatch[^"]*"')


# --- ThemeLintTests ---

RE_RAW_FONT_PATTERNS = [
    (re.compile(r"(?<![\w.])\.systemGroupedBackground\b"), ".systemGroupedBackground"),
    (re.compile(r"UIColor\.systemGroupedBackground\b"), "UIColor.systemGroupedBackground"),
    (re.compile(r"UIFont\.preferredFont\(forTextStyle:"), "UIFont.preferredFont(forTextStyle:)"),
    (re.compile(r"UIFont\.systemFont\(ofSize:"), "UIFont.systemFont(ofSize:)"),
    (re.compile(r"UIFont\.monospacedSystemFont\(ofSize:"), "UIFont.monospacedSystemFont(ofSize:)"),
    (
        re.compile(
            r"(?<!\w)\.font\(\.(largeTitle|title3|title2|title|headline|subheadline|body|callout|footnote|caption2|caption)\b(?!\()"
        ),
        "raw .font(.textStyle)",
    ),
    (
        re.compile(r"registerForTraitChanges\(\[UITraitUserInterfaceStyle\.self(?!, ThemeGenerationTrait\.self)"),
        "registerForTraitChanges without ThemeGenerationTrait",
    ),
]

RE_RAW_GLASS = re.compile(
    r"Configuration\.(glass|prominentGlass|clearGlass|prominentClearGlass)\(\)|\.glassEffect\(|\.buttonStyle\(\.glass"
)
RE_SEGMENTED_PICKER = re.compile(r"\.pickerStyle\(\.segmented\)")
RE_GLASS_SHEET_MARKER = re.compile(r"ChatSheet\.wrap\(|MenusSheet\.wrap\(|hqGlassPage\(\)")
RE_OPAQUE_SHEET_ON_GLASS = re.compile(
    r"hqOpaqueGroupedPage\(\)|(?:ackgroundColor|\.background\()\s*=?\s*(?:HQPalette\.groupedPage|Color\.hqGroupedPage)\b"
)
RE_OPAQUE_PAGE = re.compile(r"hqOpaqueGroupedPage\(\)")
RE_HALF_HEIGHT_GLASS_OK = re.compile(
    r"hqGlassPage\(|hqGlassTrait\(\)|hqGlassSheetPage\(\)|ChatSheet\.wrap\(|MenusSheet\.wrap\("
)
RE_HALF_HEIGHT_DETENT = re.compile(
    r"\.medium\(\)|\.custom\(identifier|presentationDetents\(\[[^\]]*\.(medium|fraction|height)\b"
)
RE_SYSTEM_INK = re.compile(r"\.secondary\)|secondaryLabel|tertiaryLabel|= \.label\b")
RE_SYSTEM_INK_RETURN_EXCLUSION = re.compile(r"return \(.*, \.secondary\)")


# --- ChildTasksTests ---

RE_TASK_GROUP = re.compile(r"\bwith(Throwing)?(Discarding)?(Throwing)?TaskGroup\s*\(")


def check_a11y_lints(root: Path) -> list[str]:
    errors: list[str] = []
    app_shared = iter_swift_files(root, ["App", "Shared"])

    # 1. noFixedFontSizes
    skip_fixed = ("App/Debug/", "App/Heads/", "App/Kit/Accessibility/", "/Debug/")
    for path, rel in app_shared:
        if any(s in rel for s in skip_fixed):
            continue
        for idx, line in enumerate(read_lines(path), start=1):
            if is_comment_line(line):
                continue
            if RE_FIXED_FONT.search(line) and not any(tok in line for tok in FIXED_FONT_ALLOWED):
                errors.append(f"[A11yLint.noFixedFontSizes] {rel}:{idx}: {line.strip()}")

    # 2. noDirectAccessibilitySettingReads
    for path, rel in app_shared:
        if "App/Kit/Accessibility/" in rel:
            continue
        for idx, line in enumerate(read_lines(path), start=1):
            if is_comment_line(line):
                continue
            if RE_DIRECT_A11Y_SETTING.search(line) or RE_DIRECT_A11Y_ANNOUNCE.search(line):
                errors.append(f"[A11yLint.noDirectAccessibilitySettingReads] {rel}:{idx}: {line.strip()}")

    # 3. noUnguardedAnimations
    skip_motion = ("App/Debug/", "ActivityMotionProbe.swift", "ChatPerfProbe.swift", "App/Kit/Accessibility/")
    for path, rel in app_shared:
        if any(s in rel for s in skip_motion):
            continue
        lines = read_lines(path)
        for idx0, line in enumerate(lines):
            if is_comment_line(line):
                continue
            cleaned = line.replace(".animation(forKey:", "").replace(".transition(.opacity)", "")
            if not RE_MOTION.search(cleaned):
                continue
            window = "\n".join(lines[max(0, idx0 - 6) : idx0 + 1])
            window_stripped = RE_MOTION_TOKEN.sub("", window)
            if not any(g in window_stripped for g in MOTION_GUARDS):
                errors.append(f"[A11yLint.noUnguardedAnimations] {rel}:{idx0 + 1}: {line.strip()}")

    # 4 & 5. spokenLabelsAreWords & bannedWord
    all_spoken = iter_swift_files(root, ["App", "Shared", "NotificationService"])
    for path, rel in all_spoken:
        for idx, line in enumerate(read_lines(path), start=1):
            if is_comment_line(line):
                continue
            for m in RE_SPOKEN_LABEL.finditer(line):
                kind = m.group(1)
                literal = m.group(4)
                if "dispatch" in literal.lower():
                    errors.append(f"[A11yLint.spokenLabelsAreWords] {rel}:{idx}: banned word in {kind}: {literal!r}")
                if kind == "Label" and literal:
                    if RE_DOTTED_ID.fullmatch(literal):
                        errors.append(f"[A11yLint.spokenLabelsAreWords] {rel}:{idx}: dotted id as Label: {literal!r}")
                    if literal.lower().endswith(" button"):
                        errors.append(f"[A11yLint.spokenLabelsAreWords] {rel}:{idx}: redundant 'button' suffix: {literal!r}")
                    if literal.endswith(".") and not literal.endswith("…") and ". " not in literal and len(literal) < 40:
                        errors.append(f"[A11yLint.spokenLabelsAreWords] {rel}:{idx}: trailing period on short Label: {literal!r}")
            if RE_BANNED_LINE.search(line):
                segments = line.split('"')[1::2]
                for seg in segments:
                    low = seg.lower()
                    if "dispatch" in low and "com." not in low and "getdispatch" not in low:
                        errors.append(f"[A11yLint.bannedWord] {rel}:{idx}: banned word in accessibility literal: {seg!r}")

    return errors


def check_theme_lints(root: Path) -> list[str]:
    errors: list[str] = []
    app_files = iter_swift_files(root, ["App"])

    for path, rel in app_files:
        if "App/Theme/" in rel:
            continue
        lines = read_lines(path)
        text = "\n".join(lines)

        # 6. noRawFontCallsOutsideTheThemeFolder
        if "App/Kit/Accessibility/HQFont.swift" not in rel:
            for idx, line in enumerate(lines, start=1):
                if is_comment_line(line):
                    continue
                for pattern, desc in RE_RAW_FONT_PATTERNS:
                    if pattern.search(line):
                        errors.append(f"[ThemeLint.noRawFontCalls] {rel}:{idx} ({desc}): {line.strip()}")

        # 7. noRawGlassButtonsOrSwiftUIGlassOutsideTheThemeFolder
        for idx, line in enumerate(lines, start=1):
            if is_comment_line(line) or "glass-ok" in line:
                continue
            if RE_RAW_GLASS.search(line):
                errors.append(f"[ThemeLint.noRawGlass] {rel}:{idx}: {line.strip()}")

        # 8. segmentedPickersGoThroughTheLooksStrip
        for idx, line in enumerate(lines, start=1):
            if is_comment_line(line) or "segments-ok" in line:
                continue
            if RE_SEGMENTED_PICKER.search(line):
                errors.append(f"[ThemeLint.segmentedPickers] {rel}:{idx}: {line.strip()}")

        # 9. sheetsAreGlassUnlessALineSaysWhyNot
        if not any(s in rel for s in ("App/Debug/", "App/Kit/SheetStyle.swift", "App/Root/HQPalette.swift")):
            has_glass_marker = bool(RE_GLASS_SHEET_MARKER.search(text))
            for idx, line in enumerate(lines, start=1):
                if is_comment_line(line) or "solid-ok:" in line:
                    continue
                if has_glass_marker and RE_OPAQUE_SHEET_ON_GLASS.search(line):
                    errors.append(f"[ThemeLint.sheetsAreGlass] {rel}:{idx}: {line.strip()}")
                elif RE_OPAQUE_PAGE.search(line):
                    errors.append(f"[ThemeLint.sheetsAreGlass] {rel}:{idx}: {line.strip()}")

        # 10. halfHeightSheetsAreOnTheAppsGlass
        if "App/Debug/" not in rel:
            if not RE_HALF_HEIGHT_GLASS_OK.search(text) and "solid-ok:" not in text:
                for idx, line in enumerate(lines, start=1):
                    if is_comment_line(line):
                        continue
                    if RE_HALF_HEIGHT_DETENT.search(line):
                        errors.append(f"[ThemeLint.halfHeightSheets] {rel}:{idx}: {line.strip()}")

        # 11. noUnmarkedSystemInkOutsideTheThemeFolder
        if "App/Kit/Accessibility/HQFont.swift" not in rel:
            for idx, line in enumerate(lines, start=1):
                if is_comment_line(line) or "system-ink-ok" in line:
                    continue
                if RE_SYSTEM_INK.search(line) and not RE_SYSTEM_INK_RETURN_EXCLUSION.search(line):
                    errors.append(f"[ThemeLint.noUnmarkedSystemInk] {rel}:{idx}: {line.strip()}")

    return errors


def check_child_tasks(root: Path) -> list[str]:
    errors: list[str] = []
    folders = ["App", "HermesKit", "Shared", "ShareKit", "ShareExtension", "NotificationService"]
    for path, rel in iter_swift_files(root, folders):
        for idx, line in enumerate(read_lines(path), start=1):
            code = line.split("//", 1)[0]
            if RE_TASK_GROUP.search(code):
                errors.append(f"[ChildTasks.noTaskGroupsInTheSources] {rel}:{idx}: {line.strip()}")
    return errors


def run_sibling_script(root: Path, script_rel: str, args: list[str], label: str) -> str | None:
    script = root / script_rel
    if not script.exists():
        return None
    proc = subprocess.run(
        [sys.executable, str(script), *args],
        cwd=str(root),
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        detail = (proc.stdout + proc.stderr).strip()
        return f"[{label}] failed (exit {proc.returncode}):\n{detail}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Run fast Swift and release static lint checks.")
    parser.add_argument("--skip-migrate", action="store_true", help="Skip desktoplook-migrate.py --check")
    parser.add_argument("--include-release", action="store_true", help="Also check default app icon and shipped work")
    args = parser.parse_args()

    root = resolve_root()
    errors: list[str] = []
    errors.extend(check_a11y_lints(root))
    errors.extend(check_theme_lints(root))
    errors.extend(check_child_tasks(root))

    if not args.skip_migrate:
        err = run_sibling_script(root, "scripts/desktoplook-migrate.py", ["--check"], "desktoplook-migrate")
        if err:
            errors.append(err)

    err = run_sibling_script(root, "scripts/check-tuple-try-await.py", [], "check-tuple-try-await")
    if err:
        errors.append(err)

    if args.include_release:
        err = run_sibling_script(root, "scripts/check-default-icon.py", [], "check-default-icon")
        if err:
            errors.append(err)
        err = run_sibling_script(root, "scripts/check-shipped-work.py", ["--rev", "HEAD"], "check-shipped-work")
        if err:
            errors.append(err)

    if errors:
        print(f"lint-check FAILED ({len(errors)} issue(s)):", file=sys.stderr)
        for item in errors:
            print(item, file=sys.stderr)
        return 1

    print("lint-check PASSED: all 12 static lint rules, desktoplook-migrate, and tuple-try-await clean.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
