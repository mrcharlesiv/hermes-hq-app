// The page keeps its offer/window; each call allocates the direct-chat pane independently.
// This replay does not render pixels, run Windows text services, or deliver OS input.
using Microsoft.UI.Xaml;

const string title = "Trip planning", full = "Message Trip planning", word = "Message", model = "Sonnet 5";
var r = new Row(args[0], double.Parse(args[1]), double.Parse(args[2]), double.Parse(args[3]), args[4]);
void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
void At(double pane, string hint, bool chip, bool? stacked = null)
{
    r.Arrange(pane);
    Check(r.Composer.PlaceholderText == hint && r.Chip == chip && (stacked == null || r.Stacked == stacked),
        $"pane {pane} / lane {r.Lane} / text {r.Room}: got '{r.Composer.PlaceholderText}', chip={r.Chip}, stacked={r.Stacked}; expected '{hint}', {chip}, {stacked}");
    Check(r.Room >= r.WordWidth, "clipped even the single word");
    if (chip) Check(r.ComposerModel.Content is { Length: > 0 }, "blank shortcut");
}
r.Title(title); r.Model(model);
foreach (int pane in new[] { 767, 252, 767, 252 })
{
    At(pane, pane == 252 ? word : full, pane != 252, false);
    Console.WriteLine($"fixture: pane={pane} lane={r.Lane} editor={r.Composer.ActualWidth} text={r.Room} hint='{r.Composer.PlaceholderText}' chip={r.Chip}");
}
// No capability; capability without current model; a model too long even for the wide field.
foreach (var wide in new[] { false, true })
{
    int w = wide ? 767 : 252;
    r.Model(null); At(w, wide ? full : word, false);
    r.Model(null, options: true); At(w, wide ? full : word, wide);
    if (wide) Check(r.ComposerModel.Content == "Model", "lost fallback picker caption");
    r.Model(TypeMetrics.LongModel); At(w, wide ? full : word, false);
    r.Model(model); r.Title(TypeMetrics.LongTitle); At(w, word, wide); r.Title(title);
}
r.Title("bad\nname"); r.Model("two\nlines"); At(767, word, false);
r.Title(""); At(767, word, false); r.Title(title);
// Full label: exactly its upward-rounded natural advance in the editor *after* insets & chip.
// Check both directions, with chip present/absent and a separate, unchanged accessory reservation.
r.Trailing = 13;
foreach (var withChip in new[] { false, true })
{
    r.Model(withChip ? model : null);
    double editorNeed = r.FullWidth(title) + r.Composer.Insets;
    double paneAtFit = r.Chrome + editorNeed + (withChip ? r.ButtonWidth(model) + r.ComposerModel.Margin.Horizontal : 0);
    foreach (var delta in new[] { -1, 0, 1, 0, -1 })
    {
        At(paneAtFit + delta, delta >= 0 ? full : word, withChip, false);
        Check(r.Composer.ActualWidth == editorNeed + delta, "not the final editor allocation");
    }
}
// Same pane AND lane throughout: change just the final editor slot. A window/lane-width heuristic fails here.
r.Model(model);
foreach (var delta in new[] { 1d, -1, 0, -.25, 1 })
{
    r.EditorCap = r.FullWidth(title) + r.Composer.Insets + delta;
    At(767, delta >= 0 ? full : word, true, false);
}
r.EditorCap = double.PositiveInfinity; r.Trailing = 0;
// Word reservation and 40% share independently limit the shortcut. Long title keeps the hint stable.
r.Title(TypeMetrics.LongTitle);
var padding = r.Composer.Padding;
foreach (var (name, insets, shareLimits) in new[] { (model, padding, true), ("M", new Thickness(65, 5, 22, 6), false) })
{
    r.Composer.Padding = insets; r.Model(name);
    double chip = r.ButtonWidth(name), share = chip / .4;
    double reserve = r.WordWidth + r.Composer.Insets + 4 + r.ComposerModel.Margin.Horizontal + chip;
    Check(shareLimits ? share > reserve : share < reserve, "fixture did not isolate chip limit");
    double edge = r.Chrome + Math.Max(share, reserve);
    foreach (var delta in new[] { 1, 0, -1, 0, 1 }) At(edge + delta, word, delta >= 0, false);
}
r.Composer.Padding = padding; r.Model(null); r.Title(title);
foreach (var delta in new[] { 1, 0, -1, 0, 1 })
{
    double pane = r.Chrome + r.WordWidth + r.Composer.Insets + delta;
    At(pane, delta < 0 ? full : word, false, delta < 0);
}
// Only OS type changes, not the pane or model. Natural label and chip widths must be re-read.
r.Model(model);
double middle = r.Chrome + r.FullWidth(title) + r.Composer.Insets + r.ButtonWidth(model) + r.ComposerModel.Margin.Horizontal;
foreach (double factor in new[] { 1d, 2, 1, 2, 1 })
{
    r.Composer.OsTextScale = r.ComposerModel.OsTextScale = factor;
    At(middle, factor == 1 ? full : word, factor == 1);
}
// Absolute 240 cap, with plenty of width: don't render the model's name smaller or ellipsized.
double originalSize = r.ComposerModel.FontSize;
foreach (int desired in new[] { 239, 240, 241, 240 })
{
    r.ComposerModel.FontSize = (desired - r.ComposerModel.Insets - .25) / TypeMetrics.Advance(model, 1, 1);
    Check(r.ButtonWidth(model) == desired, "bad cap probe"); At(767, full, desired <= 240);
}
r.ComposerModel.FontSize = originalSize;
foreach (var factor in new[] { 1d, 1.5, 2, 1.5, 1 })
{
    r.Composer.OsTextScale = r.ComposerModel.OsTextScale = factor;
    At(252, word, false, r.WordWidth + r.Composer.Insets > 252 - r.Chrome);
    At(767, full, true, false);
    double exact = r.FullWidth(title) + r.Composer.Insets;
    foreach (int delta in new[] { -1, 0, 1 }) { r.EditorCap = exact + delta; At(767, delta < 0 ? word : full, true); }
    r.EditorCap = double.PositiveInfinity;
}
r.Title("Wren"); At(767, "Message Wren", true); r.Title(title);
// Character delivery is in memory. Shift+Enter passes the actual drawer and page key handlers;
// the receiver inserts its newline only when neither consumed it. No call to Send, the mic or a picker.
var edit = r.Composer; edit.KeyboardFocus = true;
const string first = "plan the route", second = "keep this line wrapped around the narrow composer";
foreach (char c in first) r.Type(c); r.Type('\r', shift: true); foreach (char c in second) r.Type(c);
string draft = first + "\r" + second;
int start = first.IndexOf("route", StringComparison.Ordinal), length = "route\rkeep".Length;
Check(edit.Text == draft && edit.SelectionStart == draft.Length, "multiline input lost");
edit.SelectionStart = start; edit.SelectionLength = length;
int writes = edit.InputWrites;
foreach (var factor in new[] { 1d, 2, 1 })
{
    r.Composer.OsTextScale = r.ComposerModel.OsTextScale = factor;
    foreach (var w in new[] { 767, 252, 767, 252, 252 })
    {
        At(w, w == 252 ? word : full, w != 252);
        Check(ReferenceEquals(edit, r.Composer) && edit.KeyboardFocus && edit.FocusVisuals && edit.Name == "Message" && edit.AutomationId == "chat.composer",
            "lost the focused, named editor");
        Check(edit.InputWrites == writes && edit.Text == draft && edit.SelectionStart == start && edit.SelectionLength == length
            && edit.Text.Substring(start, length) == "route\rkeep" && edit.AcceptsReturn && edit.TextWrapping == TextWrapping.Wrap,
            "changed draft, wrapping or selection");
    }
}
r.Type('X'); Check(edit.Text == draft.Remove(start, length).Insert(start, "X") && edit.SelectionStart == start + 1, "next key missed selection");
edit.SelectionStart = 0; edit.SelectionLength = edit.Text.Length; edit.Insert(""); At(252, word, false); At(767, full, true);
Console.WriteLine("exact fits, scaled text, stable rows and retained input: PASS (managed receiver, no desktop)");
