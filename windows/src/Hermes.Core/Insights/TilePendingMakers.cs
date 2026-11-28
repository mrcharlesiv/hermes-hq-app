using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Settings;

namespace Hermes.Core.Insights;

/// [tiles-v2] An in-flight tile creation or change, persisted across app launches so its hidden chat is never orphaned
/// (HermesKit/Pages/TilePendingMakers.swift `PendingTileMaker`).
public sealed record PendingTileMaker
{
    public required string Id { get; init; }
    public required string AccountId { get; init; }
    public required string SessionId { get; init; }
    public required string BotId { get; init; }
    /// Set for Change… or live button turns; null for New Tile or Duplicate….
    public string? PinId { get; init; }
    public string? PinName { get; init; }
    public string Path { get; init; } = "";
    public string What { get; init; } = "";
    public string DashboardPage { get; init; } = TilePage.MainId;
    public TileSize? DesiredSize { get; init; }
    public bool Acting { get; init; }
    /// Seconds since 1970.
    public double AskedAt { get; init; }

    public JsonObject ToJson()
    {
        var o = new JsonObject
        {
            ["id"] = Id,
            ["accountId"] = AccountId,
            ["sessionId"] = SessionId,
            ["botId"] = BotId,
            ["path"] = Path,
            ["what"] = What,
            ["dashboardPage"] = DashboardPage,
            ["acting"] = Acting,
            ["askedAt"] = AskedAt,
        };
        if (PinId != null) o["pinId"] = PinId;
        if (PinName != null) o["pinName"] = PinName;
        if (DesiredSize is { } s) o["desiredSize"] = s.Raw();
        return o;
    }

    public static PendingTileMaker? FromJson(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var id = n.Text("id");
        var accountId = n.Text("accountId");
        var sessionId = n.Text("sessionId");
        var botId = n.Text("botId");
        if (id == null || accountId == null || sessionId == null || botId == null) return null;
        return new PendingTileMaker
        {
            Id = id,
            AccountId = accountId,
            SessionId = sessionId,
            BotId = botId,
            PinId = n.Str("pinId"),
            PinName = n.Str("pinName"),
            Path = n.Str("path") ?? "",
            What = n.Str("what") ?? "",
            DashboardPage = n.Text("dashboardPage") ?? TilePage.MainId,
            DesiredSize = TileSizes.FromRaw(n.Str("desiredSize")),
            Acting = n.Bool("acting") ?? false,
            AskedAt = n.Num("askedAt") ?? 0,
        };
    }
}

/// [tiles-v2] Persists pending tile makers per account under `hq.tilePendingMakers.<accountId>`,
/// pruning entries older than 30 minutes automatically (HermesKit/Pages/TilePendingMakers.swift `TilePendingStore`).
public static class TilePendingStore
{
    public const string Prefix = "hq.tilePendingMakers.";
    /// Pending entries older than 30 minutes are pruned automatically on load.
    public static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(30);

    public static string Key(string accountId) => Prefix + accountId;

    /// Returns only entries newer than `MaxAge` with a non-empty `SessionId`.
    public static List<PendingTileMaker> Prune(IEnumerable<PendingTileMaker> items, DateTimeOffset? now = null)
    {
        var cutoff = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0 - MaxAge.TotalSeconds;
        return items.Where(m => m.AskedAt >= cutoff && !string.IsNullOrWhiteSpace(m.SessionId)).ToList();
    }

    public static List<PendingTileMaker> Load(string accountId, IKeyValueStore store, DateTimeOffset? now = null)
    {
        var raw = store.Get(Key(accountId));
        if (string.IsNullOrWhiteSpace(raw)) return [];
        if (J.Parse(raw) is not JsonArray arr) return [];
        var list = arr.Select(PendingTileMaker.FromJson).OfType<PendingTileMaker>().ToList();
        var fresh = Prune(list, now);
        if (fresh.Count != list.Count) Save(fresh, accountId, store);
        return fresh;
    }

    public static void Save(IEnumerable<PendingTileMaker> items, string accountId, IKeyValueStore store)
    {
        var list = items.ToList();
        if (list.Count == 0)
        {
            store.Set(Key(accountId), null);
            return;
        }
        var arr = new JsonArray([.. list.Select(m => (JsonNode)m.ToJson())]);
        store.Set(Key(accountId), arr.ToJsonString());
    }

    public static void Add(PendingTileMaker item, IKeyValueStore store, DateTimeOffset? now = null)
    {
        if (string.IsNullOrWhiteSpace(item.SessionId)) return;
        var list = Load(item.AccountId, store, now);
        list.RemoveAll(m => m.Id == item.Id || m.SessionId == item.SessionId);
        list.Add(item);
        Save(list, item.AccountId, store);
    }

    public static void Upsert(PendingTileMaker item, IKeyValueStore store, DateTimeOffset? now = null) =>
        Add(item, store, now);

    public static void Remove(string id, string accountId, IKeyValueStore store)
    {
        var raw = store.Get(Key(accountId));
        if (string.IsNullOrWhiteSpace(raw) || J.Parse(raw) is not JsonArray arr) return;
        var list = arr.Select(PendingTileMaker.FromJson).OfType<PendingTileMaker>().ToList();
        var removed = list.RemoveAll(m => m.Id == id);
        if (removed > 0) Save(list, accountId, store);
    }

    public static void Clear(string accountId, IKeyValueStore store) =>
        store.Set(Key(accountId), null);
}

/// Resolved palette handed to a tile's HTML page (`TileWebTheme`).
public sealed record TileThemePalette(
    Rgba Label,
    Rgba Label2,
    Rgba Tint,
    Rgba Separator,
    Rgba Card,
    Rgba Page,
    bool Dark,
    int Radius = 16);

/// [tiles-v2] Pure CSS/JS theme & legibility prelude, deterministic `themeKey`, `__hqApplyTheme(css, isDark, ground)`
/// in-place theme switcher (`28b14acf7`, App/Chat/Viewer/HTMLPageSheet.swift + PageLegibility.swift), and tile reply
/// page-path extraction (`TileMaker.pagePath` with bare absolute `.html` fallback).
public static partial class TileWebTheme
{
    /// How long a New Tile / Change Tile waits for a reply after its turn ends without a page path (`TileMaker.replyGrace`).
    public static readonly TimeSpan ReplyGrace = TimeSpan.FromSeconds(12);
    public static readonly int[] ReplyGraceDelaysSeconds = [1, 3, 6, 12];

    public static TileThemePalette DefaultPalette(bool dark, bool desktopLook = false, int desktopRadius = 4) =>
        dark
            ? new(
                Label: new(1, 1, 1),
                Label2: new(235 / 255.0, 235 / 255.0, 245 / 255.0, 0.6),
                Tint: new(10 / 255.0, 132 / 255.0, 1),
                Separator: new(84 / 255.0, 84 / 255.0, 88 / 255.0, 0.65),
                Card: new(44 / 255.0, 44 / 255.0, 46 / 255.0),
                Page: new(28 / 255.0, 28 / 255.0, 30 / 255.0),
                Dark: true,
                Radius: desktopLook ? desktopRadius : 16)
            : new(
                Label: new(0, 0, 0),
                Label2: new(60 / 255.0, 60 / 255.0, 67 / 255.0, 0.6),
                Tint: new(0, 122 / 255.0, 1),
                Separator: new(60 / 255.0, 60 / 255.0, 67 / 255.0, 0.29),
                Card: new(1, 1, 1),
                Page: new(242 / 255.0, 242 / 255.0, 247 / 255.0),
                Dark: false,
                Radius: desktopLook ? desktopRadius : 16);

    public static string CssColor(Rgba c) =>
        string.Create(CultureInfo.InvariantCulture, $"rgba({Rgba.Byte(c.R)},{Rgba.Byte(c.G)},{Rgba.Byte(c.B)},{c.A:0.000})");

    public static string GroundJs(Rgba page) =>
        string.Create(CultureInfo.InvariantCulture, $"[{Rgba.Byte(page.R)},{Rgba.Byte(page.G)},{Rgba.Byte(page.B)},1]");

    /// The CSS variables and baseline element defaults injected into `<style id="__hq-theme">`.
    public static string PreludeCss(TileThemePalette p) =>
        $":root{{--foreground:{CssColor(p.Label)};--muted-foreground:{CssColor(p.Label2)};"
        + $"--accent:{CssColor(p.Tint)};--border:{CssColor(p.Separator)};--card:{CssColor(p.Card)};"
        + $"--hq-radius:{p.Radius}px;color-scheme:{(p.Dark ? "dark" : "light")};color:var(--foreground);accent-color:var(--accent);"
        + "font-family:'Segoe UI Variable','Segoe UI',system-ui,sans-serif;-webkit-text-size-adjust:100%}"
        + ":where(html,body){margin:0;padding:0;background:transparent}:where(body){padding:12px 16px;box-sizing:border-box;overflow-wrap:break-word}"
        + ":where(img,svg,canvas,video){max-width:100%}:where(svg[viewBox]){height:auto}"
        + ":where(input,select,textarea,button){font:inherit;color:inherit}"
        + ":where(label:has(>input[type=checkbox],>input[type=radio])){display:inline-flex;align-items:baseline;gap:.4em}"
        + ":where(a){color:var(--accent)}:where(pre){white-space:pre-wrap}"
        + ":where(hr){border:0;border-top:1px solid var(--border)}:where(iframe){max-width:100%;border:0}";

    /// Deterministic 64-bit FNV-1a hash identifying the resolved visual theme + mode + ground (`HTMLPageSheet.themeKey`).
    public static string ThemeKey(TileThemePalette p)
    {
        var input = (p.Dark ? "d|" : "l|") + PreludeCss(p) + "|" + GroundJs(p.Page);
        ulong hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(input))
        {
            hash ^= b;
            hash *= 0x100000001b3UL;
        }
        return (p.Dark ? "d-" : "l-") + hash.ToString("x16", CultureInfo.InvariantCulture);
    }

    public static string EscapeJsTemplate(string text) =>
        text.Replace("\\", "\\\\").Replace("`", "\\`").Replace("$", "\\$");

    /// Evaluates in-place theme update on an already-loaded WebView (`HTMLPageSheet.applyThemeScript`):
    /// returns `'reload'` before prelude runs, `true` if canvas/scripts require reload, or `false` when updated in place.
    public static string ApplyThemeScript(TileThemePalette p)
    {
        var escaped = EscapeJsTemplate(PreludeCss(p));
        var dark = p.Dark ? "true" : "false";
        var ground = GroundJs(p.Page);
        return $"typeof window.__hqApplyTheme==='function'?window.__hqApplyTheme(`{escaped}`,{dark},{ground}):'reload'";
    }

    /// Interprets the JSON string returned by WebView2 `ExecuteScriptAsync(ApplyThemeScript(...))`.
    public static bool NeedsReloadAfterThemeApply(string? scriptResult)
    {
        if (string.IsNullOrWhiteSpace(scriptResult)) return true;
        var trimmed = scriptResult.Trim();
        return trimmed is "true" or "\"reload\"" or "null";
    }

    /// Document-created prelude injecting `<style id="__hq-theme">`, `window.__hqApplyTheme(css, isDark, ground)`,
    /// `window.__hqLegible`, `window.hermes.send`, and (when `inTile`) tap-to-open & `window.hermes.refresh`.
    public static string PreludeScript(TileThemePalette p, bool talks, bool inTile)
    {
        var escaped = EscapeJsTemplate(PreludeCss(p));
        var dark = p.Dark ? "true" : "false";
        var send = talks
            ? "var n=0,w={};window.__hermesAck=function(id,r){var f=w[id];delete w[id];if(f)f(r)};"
              + "window.hermes={send:function(p){return new Promise(function(res){var id=++n;w[id]=res;"
              + "try{window.chrome.webview.postMessage({id:id,prompt:String(p)})}catch(e){delete w[id];res({ok:false,error:'undelivered'})}})}};"
              + "document.addEventListener('click',function(e){var t=e.target&&e.target.closest&&e.target.closest('[data-hermes-send]');"
              + "if(t){e.preventDefault();window.hermes.send(t.getAttribute('data-hermes-send'))}},true);"
            : "window.hermes={send:function(){return Promise.resolve({ok:false,error:'undelivered'})}};";

        var script = "(function(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';"
            + "m.content='width=device-width,initial-scale=1';(document.head||document.documentElement).appendChild(m)}"
            + "var s=document.createElement('style');s.id='__hq-theme';s.textContent=`" + escaped + "`;"
            + "(document.head||document.documentElement).prepend(s);" + send
            + "function fit(){var vw=document.documentElement.clientWidth;"
            + "document.querySelectorAll('svg[width][height]:not([viewBox])').forEach(function(g){"
            + "var w=parseFloat(g.getAttribute('width')),h=parseFloat(g.getAttribute('height'));"
            + "if(w>0&&h>0&&w>vw-8){g.setAttribute('viewBox','0 0 '+w+' '+h);g.setAttribute('preserveAspectRatio','xMinYMin meet');"
            + "g.style.width='100%';g.style.height='auto'}})}"
            + "var dark=" + dark + ",schemeOwned=false;"
            + "function scheme(){var r=document.documentElement.style;"
            + "if(schemeOwned){r.colorScheme='';r.removeProperty('--foreground');r.removeProperty('--muted-foreground');schemeOwned=false}"
            + "var c=getComputedStyle(document.body).backgroundColor,m=c&&c.match(/[\\d.]+/g);"
            + "if(!m||m.length<3||(m.length>3&&+m[3]<0.5)){c=getComputedStyle(document.documentElement).backgroundColor;m=c&&c.match(/[\\d.]+/g)}"
            + "if(m&&m.length>=3&&!(m.length>3&&+m[3]<0.5)){var k=/^color\\(/.test(c)?255:1,l=(0.299*m[0]+0.587*m[1]+0.114*m[2])*k/255;"
            + "var light=l>0.5;r.colorScheme=light?'light':'dark';"
            + "if(light===dark){r.setProperty('--foreground',light?'#1c1c1e':'#f2f2f7');"
            + "r.setProperty('--muted-foreground',light?'rgba(60,60,67,0.75)':'rgba(235,235,245,0.7)')}"
            + "schemeOwned=true}}"
            + "window.__hqApplyTheme=function(css,isDark,ground){dark=!!isDark;"
            + "var st=s||document.getElementById('__hq-theme');if(st)st.textContent=css;"
            + "if(document.body)scheme();"
            + "if(window.__hqLegible&&window.__hqLegible.setGround)window.__hqLegible.setGround(ground);"
            + "requestAnimationFrame(function(){if(document.body)scheme();if(window.__hqLegible)window.__hqLegible.run()});"
            + "if(document.querySelector('canvas'))return true;"
            + "var re=/prefers-color-scheme|getComputedStyle|--foreground|--card|--accent|--muted-foreground|--border/;"
            + "for(var i=0;i<document.scripts.length;i++){if(re.test(document.scripts[i].textContent||''))return true}"
            + "return false};"
            + "document.addEventListener('DOMContentLoaded',function(){fit();scheme();"
            + "if(document.body)new MutationObserver(fit).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['width','height']})});})();"
            + LegibilityScript(p.Page);

        if (inTile)
        {
            script += "(function(){var s=document.createElement('style');"
                + "s.textContent=':where(html,body){user-select:none;overflow:hidden}';"
                + "(document.head||document.documentElement).appendChild(s);"
                + "function post(m){try{window.chrome.webview.postMessage(m)}catch(e){}}"
                + "window.hermes=window.hermes||{};window.hermes.refresh=function(){post({refresh:true})};"
                + "function pressable(t){for(var e=t;e&&e.nodeType===1;e=e.parentElement){"
                + "if(e.matches('a[href],button,input,select,textarea,label,summary,details,[data-hermes-send],[onclick],[role=button],[data-hq-tap]'))return true;"
                + "if(getComputedStyle(e).cursor==='pointer')return true}return false}"
                + "document.addEventListener('click',function(e){if(e.defaultPrevented||pressable(e.target))return;post({open:true})},false);})();";
        }
        return script;
    }

    public static string LegibilityScript(Rgba page) =>
        LegibilitySource.Replace("__GROUND__", GroundJs(page), StringComparison.Ordinal);

    /// The newest page a reply named: `MEDIA:/…/x.html` first, else any bare absolute or `~/` `.html`/`.htm` path
    /// (`TileMaker.pagePath(in:)`).
    public static string? ExtractPagePath(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var media = MediaHtmlRx().Matches(text);
        if (media.Count > 0) return media[^1].Groups[1].Value.Trim();
        var bare = BareHtmlRx().Matches(text);
        if (bare.Count > 0) return bare[^1].Groups[1].Value.Trim();
        return null;
    }

    /// A problem's first line, ending in a full stop (`TileMaker.firstLine(_:)`).
    public static string FirstLine(string? problem)
    {
        if (string.IsNullOrWhiteSpace(problem)) return "";
        var line = problem.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        if (line.Length == 0) return "";
        var cut = line.Length > 160 ? line[..159] + "…" : line;
        return ".!?…".Contains(cut[^1]) ? cut : cut + ".";
    }

    [GeneratedRegex(@"MEDIA:\s*`?((?:/|~/)[^\s`""'<>]+?\.html?)`?(?=\s|$)", RegexOptions.IgnoreCase)]
    private static partial Regex MediaHtmlRx();

    [GeneratedRegex(@"(?:^|[\s`(""'])((?:/|~/)[^\s`""'<>()]+?\.html?)(?=[\s`)""'.,:;]|$)", RegexOptions.IgnoreCase)]
    private static partial Regex BareHtmlRx();

    private const string LegibilitySource = """
    (function(){
    var GROUND=__GROUND__,FLOOR=3,GOAL=4.5,MOST=6000,SKIP=/^(script|style|noscript|template|textarea|option|title|desc|metadata)$/i;
    var EDGES=['border-top-color','border-right-color','border-bottom-color','border-left-color','outline-color'];
    var mine=[],memo={},timer=0,last=0,gap=200,watch=null;
    var cv=document.createElement('canvas');cv.width=cv.height=1;var cx=cv.getContext('2d',{willReadFrequently:true});
    function rgba(c){var v=memo[c];if(v)return v;cx.clearRect(0,0,1,1);cx.fillStyle='#010203';cx.fillStyle=c;
      if(cx.fillStyle==='#010203'&&!/^(#010203|rgb\(1, ?2, ?3\))$/i.test(c))return memo[c]=[0,0,0,0];
      cx.fillRect(0,0,1,1);var d=cx.getImageData(0,0,1,1).data;return memo[c]=[d[0],d[1],d[2],d[3]/255]}
    function over(t,u){var a=t[3];return [t[0]*a+u[0]*(1-a),t[1]*a+u[1]*(1-a),t[2]*a+u[2]*(1-a),1]}
    function lum(c){function f(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4)}
      return 0.2126*f(c[0])+0.7152*f(c[1])+0.0722*f(c[2])}
    function ratio(a,b){var x=lum(a),y=lum(b);return (Math.max(x,y)+0.05)/(Math.min(x,y)+0.05)}
    function css(c){return 'rgb('+Math.round(c[0])+','+Math.round(c[1])+','+Math.round(c[2])+')'}
    function hsl(c){var r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),l=(mx+mn)/2,d=mx-mn,h=0,s=0;
      if(d>0){s=d/(1-Math.abs(2*l-1));h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h*=60;if(h<0)h+=360}return [h,Math.min(1,s),l]}
    function rgb(h,s,l){var c=(1-Math.abs(2*l-1))*s,x=c*(1-Math.abs((h/60)%2-1)),m=l-c/2,
      v=h<60?[c,x,0]:h<120?[x,c,0]:h<180?[0,c,x]:h<240?[0,x,c]:h<300?[x,0,c]:[c,0,x];return [(v[0]+m)*255,(v[1]+m)*255,(v[2]+m)*255]}
    function lift(ink,back,goal){var up=ratio([255,255,255],back)>=ratio([0,0,0],back),k=hsl(ink),c=ink;
      for(var i=1;i<=40&&ratio(c,back)<goal;i++)c=rgb(k[0],k[1],up?k[2]+(1-k[2])*i/40:k[2]*(1-i/40));return c}
    function goal(ink,back){if(back!==GROUND)return GOAL;
      var made=lum(back)<0.18?[255,255,255,1]:[28,28,30,1];
      return Math.max(GOAL,Math.min(ratio(over(ink,made),made),hsl(ink)[1]>0.2?7:16))}
    function ground(el,seen){
      if(!el||el.nodeType!==1)return GROUND;
      if(seen.has(el))return seen.get(el);
      var cs=getComputedStyle(el),layer=rgba(cs.backgroundColor),image=cs.backgroundImage,out;
      if(image&&image!=='none'&&/url\(/.test(image)&&layer[3]<0.999){seen.set(el,null);return null}
      if(layer[3]>=0.999)out=layer;
      else{var under=ground(el.parentElement,seen);out=under===null?null:(layer[3]>0?over(layer,under):under)}
      seen.set(el,out);return out}
    function set(el,p,v){var s=el.style,was=s.getPropertyValue(p),pri=s.getPropertyPriority(p);s.setProperty(p,v,'important');
      mine.push([el,p,was,pri,s.getPropertyValue(p)])}
    function undo(){for(var i=mine.length-1;i>=0;i--){var m=mine[i],s=m[0].style;
      if(s.getPropertyValue(m[1])!==m[4]||s.getPropertyPriority(m[1])!=='important')continue;
      if(m[2])s.setProperty(m[1],m[2],m[3]);else s.removeProperty(m[1])}mine=[]}
    function need(cs,back){if(back!==GROUND||lum(GROUND)>=0.18)return FLOOR;var px=parseFloat(cs.fontSize),w=parseInt(cs.fontWeight,10)||400;
      return px>=24||(px>=18.66&&w>=700)?FLOOR:GOAL}
    function check(el,seen){
      if(typeof SVGElement!=='undefined'&&el instanceof SVGElement)return;
      var cs=getComputedStyle(el);if(cs.display==='none'||cs.visibility==='hidden')return;
      if(cs.webkitBackgroundClip==='text'||cs.backgroundClip==='text')return;
      var tf=cs.webkitTextFillColor,prop=tf&&tf!==cs.color?'-webkit-text-fill-color':'color',raw=prop==='color'?cs.color:tf;
      var back=ground(el,seen);if(back===null||!raw||raw==='none'||/url\(/.test(raw))return;
      var ink=rgba(raw);if(ink[3]<0.1)return;
      var laid=over(ink,back),had=ratio(laid,back);if(had>=need(cs,back))return;
      var to=css(lift(laid,back,had<FLOOR?goal(ink,back):GOAL));set(el,prop,to);
      if(prop==='color')EDGES.forEach(function(p){if(cs.getPropertyValue(p)===raw)set(el,p,to)})}
    function run(){
      clearTimeout(timer);timer=0;if(!document.body)return;
      var t0=performance.now();undo();
      var seen=new Map(),done=new Set(),n=0,walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),node;
      while((node=walk.nextNode())&&n<MOST){var el=node.parentElement;
        if(!el||done.has(el)||!/\S/.test(node.nodeValue)||SKIP.test(el.tagName))continue;
        done.add(el);n++;check(el,seen)}
      document.querySelectorAll('input,textarea,select').forEach(function(el){if(n++<MOST)check(el,seen)});
      if(watch)watch.takeRecords();
      gap=Math.max(200,Math.min(5000,(performance.now()-t0)*25));last=Date.now()}
    function soon(){var wait=last+gap-Date.now();clearTimeout(timer);if(wait<=0)run();else timer=setTimeout(run,wait)}
    function start(){run();if(watch||!document.body)return;watch=new MutationObserver(soon);
      watch.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,
        attributeFilter:['class','style','hidden','open']})}
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
    window.addEventListener('load',run);
    window.__hqLegible={run:run,setGround:function(g){GROUND=g;memo={};run()},count:function(){return mine.length},wait:function(){return gap}};
    })();
    """;
}

/// [tiles-v2] Live-tile message rate & concurrency guard (`LiveTiles.swift` `isWorking` + 1-second throttle):
/// rejects empty/oversized prompts, rejects duplicate taps while a bot turn is already running (`busy`),
/// waits out at most one queued tap inside the 1-second window, and rejects any further taps inside that window (`throttled`).
public sealed class TileLiveGuard
{
    public enum DecisionKind { Deliver, Wait, Reject }
    public readonly record struct Decision(DecisionKind Kind, string? Error = null, TimeSpan Delay = default);

    public static readonly TimeSpan MinGap = TimeSpan.FromSeconds(1);

    private readonly Dictionary<string, DateTimeOffset> _lastIntent = new(StringComparer.Ordinal);
    private readonly HashSet<string> _waiting = new(StringComparer.Ordinal);
    private readonly object _lock = new();

    public Decision Evaluate(string pinId, string? rawPrompt, bool isWorking, DateTimeOffset? now = null)
    {
        var prompt = (rawPrompt ?? "").Trim();
        if (prompt.Length == 0) return new(DecisionKind.Reject, "empty");
        if (prompt.Length > TileWords.MaxIntentLength) return new(DecisionKind.Reject, "too_long");
        if (isWorking) return new(DecisionKind.Reject, "busy");
        var at = now ?? DateTimeOffset.UtcNow;
        lock (_lock)
        {
            if (_lastIntent.TryGetValue(pinId, out var last))
            {
                var wait = MinGap - (at - last);
                if (wait > TimeSpan.Zero)
                {
                    if (!_waiting.Add(pinId)) return new(DecisionKind.Reject, "throttled");
                    return new(DecisionKind.Wait, null, wait);
                }
            }
            _lastIntent[pinId] = at;
            return new(DecisionKind.Deliver);
        }
    }

    public Decision CompleteWait(string pinId, bool isWorking, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        lock (_lock)
        {
            _waiting.Remove(pinId);
            if (isWorking) return new(DecisionKind.Reject, "busy");
            _lastIntent[pinId] = at;
            return new(DecisionKind.Deliver);
        }
    }

    public void CancelWait(string pinId)
    {
        lock (_lock) _waiting.Remove(pinId);
    }

    public void Reset(string pinId)
    {
        lock (_lock)
        {
            _waiting.Remove(pinId);
            _lastIntent.Remove(pinId);
        }
    }
}
