# Hermes.Math: third-party code and fonts

Hermes.Math sets the chat's formulas. It ships nothing of its own beyond `MathEngine.cs`; what it carries comes in
through NuGet, pinned in `Hermes.Math.csproj`:

| Component | Version | Licence | Text |
|---|---|---|---|
| CSharpMath, CSharpMath.Editor, CSharpMath.Rendering, CSharpMath.SkiaSharp | 0.5.1 | MIT, © CSharpMath Contributors 2020 (verybadcat, Happypig375, charlesroddie, FoggyFinder), github.com/verybadcat/CSharpMath | the MIT licence (below) |
| Latin Modern Math (`latinmodern-math.otf` v1.959, embedded in CSharpMath.Rendering.dll) | 1.959 | GUST Font License (an instance of the LaTeX Project Public License 1.3c); © 2012–2014 B. Jackowski, P. Strzelczyk and P. Pianowski for the TeX users groups | `licenses/LatinModernMath-GUST-FONT-LICENSE.txt` |
| SkiaSharp, SkiaSharp.NativeAssets.Win32, SkiaSharp.NativeAssets.macOS | 2.88.9 | MIT, © Xamarin, Inc. / Microsoft Corporation | `licenses/SkiaSharp-LICENSE.txt`; Skia and the libraries inside the native build: `licenses/SkiaSharp-THIRD-PARTY-NOTICES.txt` |

The font is byte for byte the Mac's own (`Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/latinmodern-math.otf`,
SHA-256 `6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f`; its licence file above is copied from that
bundle, whose `OFL.txt` is the STIX fonts' licence and does not apply). `MathEngineTests.TheFontIsTheMacsLatinModernMath` checks the hash, so a CSharpMath update that
changes the font fails a test rather than changing the app's formulas unseen.

CSharpMath.Rendering.dll also embeds two other fonts, both under the SIL Open Font License 1.1:

| Font | Notice | Text |
|---|---|---|
| `AMS-Capital-Blackboard-Bold.otf` | Taken from AMSMathematicalSymbol-Medium5, © 1997, 2009 American Mathematical Society, Reserved Font Name MSBM9 | `licenses/AMS-Capital-Blackboard-Bold-OFL.txt` |
| `cyrillic-modern-nmr10.otf` (Cyrillic Modern NMR10 4.002) | © 1997, 2009 American Mathematical Society (Reserved Font Name CMR10); © 2012–2014 Andrey V. Panov | `licenses/CyrillicModern-NMR10-OFL.txt` |

[WIN-MATH-UI] Where those two texts come from, all on this disk, nothing fetched: each font's own copyright and licence
lines are read from its name table inside the restored `csharpmath.rendering/0.5.1` package's DLL, and the OFL 1.1
terms below them are copied from the Mac's `Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/OFL.txt` (its STIX
header left out; the OFL 1.1 body is the same for every font). The app's About › Open-Source Licenses lists all of the
above (`Hermes.Core/Settings/licenses.json`: CSharpMath, Latin Modern Math, AMS Blackboard Bold, Cyrillic Modern,
SkiaSharp with its third-party notices); `AboutLoggingTests` checks every package Hermes.Math pins has a notice.

CSharpMath.Rendering.dll also compiles in the Typography library (LayoutFarm's OpenType reader and text breaking:
`Typography.OpenFont`, `.TextBreak`, `.TextLayout`, `.Contours`, `.WebFont` namespaces in the DLL). Its text is taken
from upstream at the submodule commit CSharpMath's `v0.5.1` tag pins, `LayoutFarm/Typography@d331968f3ee7`: the
project's `LICENSE.md` verbatim, then the full texts its file headers name (MIT; Apache 2.0 from apache.org; the
FreeType Project License from freetype's `docs/FTL.TXT`; Unicode License V3 from unicode.org for the ICU-derived
break rules). About lists it as "Typography (OpenType reader)"; `AboutLoggingTests` checks the pin and each text.
Open: the Unicode text is today's V3, not the 2016 agreement the ICU 58 files were released under (same terms of
permission; the older wording is not on this disk).

## MIT licence (CSharpMath)

```
MIT License

Copyright (c) CSharpMath Contributors 2020

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
