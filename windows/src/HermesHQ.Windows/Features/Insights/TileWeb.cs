using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Insights;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace HermesHQ.Features.Insights;

/// A tile's page in a WebView2 (App/Chat/Viewer/HTMLPageSheet.swift `prelude`, App/Pages/Artifacts/LiveTiles.swift
/// `tileScript`): the app's colours as CSS variables a page may use, a viewport, `window.hermes.send` and
/// `data-hermes-send` buttons that ask the tile's bot, and in a tile a click on nothing pressable opens it.
/// Messages come back through `chrome.webview.postMessage`: `{id, prompt}` from a button, `{open:true}` or
/// `{refresh:true}` from the tile script.
public static class TileWeb
{
    public static string Prelude(bool dark, bool talks, bool inTile)
    {
        var fg = dark ? "rgba(255,255,255,1.000)" : "rgba(0,0,0,1.000)";
        var muted = dark ? "rgba(235,235,245,0.600)" : "rgba(60,60,67,0.600)";
        var accent = dark ? "rgba(10,132,255,1.000)" : "rgba(0,122,255,1.000)";
        var border = dark ? "rgba(84,84,88,0.650)" : "rgba(60,60,67,0.290)";
        var card = dark ? "rgba(44,44,46,1.000)" : "rgba(255,255,255,1.000)";
        var style = $":root{{--foreground:{fg};--muted-foreground:{muted};--accent:{accent};--border:{border};--card:{card};"
            + $"--hq-radius:16px;color-scheme:{(dark ? "dark" : "light")};color:var(--foreground);"
            + "font-family:'Segoe UI Variable','Segoe UI',system-ui,sans-serif;-webkit-text-size-adjust:100%}"
            + ":where(html,body){margin:0;padding:0;background:transparent}:where(body){padding:12px 16px;box-sizing:border-box}"
            + ":where(img,svg,canvas,video){max-width:100%}:where(svg[viewBox]){height:auto}";
        var send = talks
            ? "var n=0,w={};window.__hermesAck=function(id,r){var f=w[id];delete w[id];if(f)f(r)};"
              + "window.hermes={send:function(p){return new Promise(function(res){var id=++n;w[id]=res;"
              + "try{window.chrome.webview.postMessage({id:id,prompt:String(p)})}catch(e){delete w[id];res({ok:false,error:'undelivered'})}})}};"
              + "document.addEventListener('click',function(e){var t=e.target&&e.target.closest&&e.target.closest('[data-hermes-send]');"
              + "if(t){e.preventDefault();window.hermes.send(t.getAttribute('data-hermes-send'))}},true);"
            : "window.hermes={send:function(){return Promise.resolve({ok:false,error:'undelivered'})}};";
        var script = "(function(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';"
            + "m.content='width=device-width,initial-scale=1';(document.head||document.documentElement).appendChild(m)}"
            + "var s=document.createElement('style');s.textContent=" + JsonSerializer.Serialize(style) + ";"
            + "(document.head||document.documentElement).prepend(s);" + send + "})();";
        if (inTile)
            script += "(function(){var s=document.createElement('style');"
                + "s.textContent=':where(html,body){user-select:none;overflow:hidden}';"
                + "(document.head||document.documentElement).appendChild(s);"
                + "function post(m){try{window.chrome.webview.postMessage(m)}catch(e){}}"
                + "window.hermes=window.hermes||{};window.hermes.refresh=function(){post({refresh:true})};"
                + "function pressable(t){for(var e=t;e&&e.nodeType===1;e=e.parentElement){"
                + "if(e.matches('a[href],button,input,select,textarea,label,summary,details,[data-hermes-send],[onclick],[role=button],[data-hq-tap]'))return true;"
                + "if(getComputedStyle(e).cursor==='pointer')return true}return false}"
                + "document.addEventListener('click',function(e){if(e.defaultPrevented||pressable(e.target))return;post({open:true})},false);})();";
        return script;
    }

    /// What a page posted: a button's ask, open, or refresh.
    public sealed record Message(int? Id, string? Prompt, bool Open, bool Refresh);

    public static Message? Read(CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonNode? n;
        try { n = JsonNode.Parse(e.WebMessageAsJson); } catch (JsonException) { return null; }
        if (n is not JsonObject) return null;
        return new Message((int?)n.Int("id"), n.Str("prompt"), n.Bool("open") == true, n.Bool("refresh") == true);
    }

    /// Answers a button's ask in the page (`window.__hermesAck`).
    public static void Ack(WebView2 web, int id, bool ok, string? error = null)
    {
        var result = ok ? "{ok:true}" : "{ok:false,error:" + JsonSerializer.Serialize(error ?? "undelivered") + "}";
        _ = web.CoreWebView2?.ExecuteScriptAsync($"window.__hermesAck && window.__hermesAck({id}, {result})");
    }

    /// A web view set up for a tile's page: no menus, no zoom, no dev tools, the prelude before every load, links
    /// leaving the page opened in the browser.
    public static async Task<bool> PrepareAsync(WebView2 web, bool dark, bool talks, bool inTile)
    {
        try
        {
            var env = await HermesHQ.Services.WebViewEnv.GetAsync();
            await web.EnsureCoreWebView2Async(env);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or FileNotFoundException)
        {
            return false;
        }
        var core = web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        await core.AddScriptToExecuteOnDocumentCreatedAsync(Prelude(dark, talks, inTile));
        core.NavigationStarting += (sender, a) =>
        {
            // The page itself (NavigateToString's about:blank / data) loads; a link leaving it opens in the browser.
            if (a.Uri.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || a.Uri.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                a.Cancel = true;
                if (Uri.TryCreate(a.Uri, UriKind.Absolute, out var u)) _ = Windows.System.Launcher.LaunchUriAsync(u);
            }
        };
        core.NewWindowRequested += (sender, a) =>
        {
            a.Handled = true;
            if (Uri.TryCreate(a.Uri, UriKind.Absolute, out var u) && u.Scheme is "http" or "https") _ = Windows.System.Launcher.LaunchUriAsync(u);
        };
        web.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
        return true;
    }

    /// Loads a page's text (with a viewport when it has none).
    public static void Show(WebView2 web, string html) => web.NavigateToString(TileFiles.WithViewport(html) ?? html);
}
