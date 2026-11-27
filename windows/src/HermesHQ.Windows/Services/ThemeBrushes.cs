using HermesHQ.Features.Settings;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ;

/// [WIN-THEME-APP-RESOURCES] A brush by its theme key, in the mode on show: what `{ThemeResource key}` gives in markup,
/// for code. `Application.Current.Resources[key]` resolves in the application's theme (the system's), so with
/// Appearance › Dark on a light Windows it handed back light-theme colours (black formulas, a light ground: CI run
/// 45095225249, shot 194). A key ThemeService paints is its one brush, coloured for the mode on show; any other key is
/// one brush per key painted from the theme dictionary for that mode (Hermes.Core.Settings.ThemeKeys.Dictionaries) and
/// painted again on every ThemeService.Changed. A key whose theme value isn't a solid colour (an acrylic) is that
/// theme's object as it is now; under a Windows contrast theme the application's own lookup is the right one.
public static class ThemeBrushes
{
    private static readonly Dictionary<string, SolidColorBrush> Followed = [];
    private static bool _watching;

    public static Brush Get(string key)
    {
        if (ThemeService.Painted(key) is { } painted) return painted;
        if (ThemeService.SystemHighContrast) return (Brush)Application.Current.Resources[key];
        if (Followed.TryGetValue(key, out var followed)) return followed;
        var now = InMode(key, ThemeService.Dark);
        if (now is not SolidColorBrush solid) return now as Brush ?? (Brush)Application.Current.Resources[key];
        var brush = new SolidColorBrush(solid.Color) { Opacity = solid.Opacity };
        Followed[key] = brush;
        if (!_watching)
        {
            _watching = true;
            ThemeService.Changed += Repaint;
        }
        return brush;
    }

    /// A resource by key: a brush through `Get` (the mode on show), anything else (a style, a font) as the
    /// application holds it.
    public static T Res<T>(string key)
    {
        var value = Application.Current.Resources[key];
        return value is Brush ? (T)(object)Get(key) : (T)value;
    }

    private static void Repaint()
    {
        foreach (var (key, brush) in Followed)
        {
            if (InMode(key, ThemeService.Dark) is SolidColorBrush solid)
            {
                brush.Color = solid.Color;
                brush.Opacity = solid.Opacity;
            }
        }
    }

    /// The value under `key` in the theme dictionary for the mode, searched as WinUI does: the application's own
    /// dictionaries, then its merged ones (XamlControlsResources) from the last.
    private static object? InMode(string key, bool dark)
    {
        try
        {
            foreach (var name in Hermes.Core.Settings.ThemeKeys.Dictionaries(dark))
                if (Find(Application.Current.Resources, name, key, 0) is { } found) return found;
        }
        catch (Exception x) { AppLog.Note("settings", $"theme key {key} not read: {x.GetType().Name}"); }
        return null;
    }

    private static object? Find(ResourceDictionary dictionary, string theme, string key, int depth)
    {
        if (depth > 8) return null;
        if (dictionary.ThemeDictionaries.TryGetValue(theme, out var t) && t is ResourceDictionary themed)
        {
            if (themed.TryGetValue(key, out var value)) return value;
            for (var i = themed.MergedDictionaries.Count - 1; i >= 0; i--)
                if (themed.MergedDictionaries[i].TryGetValue(key, out var merged)) return merged;
        }
        for (var i = dictionary.MergedDictionaries.Count - 1; i >= 0; i--)
            if (Find(dictionary.MergedDictionaries[i], theme, key, depth + 1) is { } found) return found;
        return null;
    }
}
