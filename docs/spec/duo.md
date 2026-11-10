# iPhone Duo (stream `duo`, 2026-11-03)

Apple's first foldable iPhone (announced 2026-09-09, on sale 2026-10-23, iOS 27.1). Owner: "Can you add support for
iPhone Duo?"

## The device

- Outer screen 5.4″, 466×678 pt (1398×2034 px @3x): compact width upright, compact both ways sideways. It honours the
  app's portrait-only setting.
- Inner screen 669×951 pt upright, 951×669 pt sideways (2007×2853 px, Xcode 27.2's simulator): regular width and
  height in every orientation. It honours a portrait-only app, so the app says itself that it turns there (item 5).
- Fold and unfold resize the same window. No new scene.
- Touch ID in the side button, no Face ID.
- Split View on the inner screen.
- Apple has not said which `userInterfaceIdiom` the Duo reports. This plan assumes `.phone`.

## What the app does

1. **The iPad's root.** `AppRoot.make` (App/Root/PaneRouter.swift) gives an iPhone that unfolds the two-pane root
   (`RootSplitController`), so the iPad's rule (`PaneLayout.decide`: two panes from 768 pt wide and more than 500 pt
   tall) runs on it:
   - folded (466 pt): one pane;
   - open, upright (669 pt): a 300 pt list and the chat (2026-11-07, as Hermes Agent on a Duo; `PaneLayout.decide`'s
     `foldable`, from 640 pt). The 84 pt status column down the right edge leaves the chat about 285 pt, an iPhone
     mini's column. An iPad window that narrow stays one pane;
   - open, sideways (951 pt): a 375 pt list and a 576 pt chat.
   Folding or unfolding moves the open chat between the list's stack and the right pane, exactly as a Stage Manager
   resize does on an iPad. The list pane keeps the compact size class (the phone's bottom tab bar, phone rows) at every
   width. In the phone root an unfolded Duo was regular width, which puts iOS's tab bar at the top.
2. **Telling a Duo.** `PaneLayout.foldable(screen:)`: the screen's narrow side is wider than 450 pt. The widest iPhone
   that does not fold is 440 pt (Pro Max). Even folded, the Duo is 466 pt. The check reads the window scene's screen
   when the scene connects (`AppRoot.foldable`), before any root is made. `-HQDebugFoldable YES` forces it on a flat
   iPhone simulator.
   **Fixed 2026-11-07:** the size alone missed a Duo launched folded. Built with an SDK older than 27.1 the app stays
   out of the 80 pt sensor column, so the folded screen reads 386×678, under 450, and the app kept the phone root: one
   pane even open and sideways (a tester's Duo, beside Hermes Agent's list-and-chat). Now also by model
   (`PaneLayout.foldableModels`: iPhone19,4, the Duo simulator's), and a phone whose screen is ever seen open
   (`AppRoot.noteScreen`) remembers it (`HQFoldableSeenOpen`) for the next launch. The root is not swapped under a
   running app. Open sideways in that build the window is 871×669: a 375 pt list and the chat.
3. **Sheets.** `ThemeChrome.onBottomEdge`: on an unfolded Duo (regular width), a sheet follows the iPad's rule: a form
   sheet is a card, not the phone's bottom sheet. Folded, it is the phone's.
4. **Touch ID.** The Terminal's lock reads the sensor (`LAContext.biometryType`): "Require Touch ID", "Touch ID or
   your passcode". Before, iOS always said Face ID, which was wrong on an iPhone SE as well.

5. **Turning.** `supportedInterfaceOrientationsFor`: on the open screen (`PaneLayout.unfolded`, narrow side over
   600 pt) the app turns every way, as on an iPad; folded it stays portrait. A fold or unfold asks again
   (`RootSplitController` → `setNeedsUpdateOfSupportedInterfaceOrientations`).
6. **The side column.** The 27.2 SDK puts the status bar and the bar buttons in a column down the right edge, on both
   screens. The chat lays out inside the safe area's sides, which are uneven.

Checked on Xcode 27.2's Duo simulator, driven through Device Hub (2026-11-03): open upright, open sideways (two panes,
the chat moves to the right pane live), fold from sideways (one pane, chat back on the list's stack), unfold again.
`-HQDebugDuoWatch YES` logs the window, the chat's frame and its safe area every 2 s. Once, the first fold from
sideways drew the chat about 100 pt to the right; two repeats were right and it was not seen again. The simulator
sometimes sleeps after Closed (black screenshots); Home wakes it.

## Xcode 27.2 (2026-11-07)

`scripts/ship.py`, `scripts/build.sh` and `scripts/build-mac.sh` build with /Applications/Xcode-27.2.app
(`DEVELOPER_DIR`; the Mac's selected Xcode is still 27.0, and the other scripts use it). Built with 27.2 the app runs
edge to edge on the Duo: folded the window is 466×678 with the status column inside it (right safe area 84 pt), not
the 386 pt window beside a black strip. `simctl io <udid> screenshot --display=1` (outer) or `--display=3` (inner)
photographs a Duo simulator; nothing on the command line folds or turns it (`screenConfig power` only blanks a screen).
DEBUG `-HQDebugDuoUpright YES -HQDebugPaneWidth 669 -HQDebugPaneHeight 951` on an iPad simulator stands in for the open
Duo upright, column included.

## Not done (was: needs Xcode 27.1)

Before 2026-11-07 builds used the iOS 27.0 SDK. Built with 27.0, the app gets the inner screen but stays out
of the strip beside the status bar. Built with 27.1, it runs edge to edge with the standard bars laid vertically.
Still to do once 27.1 is installed:

- Run on the Duo simulator: fold, unfold, rotate, half fold, and Split View on the inner screen.
- Reserved regions (`reservedRegions(kind: .division / .occlusion)`, `UIViewReservedRegion`). Check that nothing drawn
  outside the safe area sits on the fold or the inner screen's under-display camera: the custom bars (Desktop Look tab
  bar, composer, pills).
- Asymmetric safe areas: the vertical bars can sit on either side.
- Hinge posture (`onHingeChange` / `UIHingeInteraction`): not in a shipped SDK yet.
