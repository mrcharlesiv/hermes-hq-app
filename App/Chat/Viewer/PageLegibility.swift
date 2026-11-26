import UIKit

/// Words on a bot's page that can't be read are given an ink that can (owner 2026-11-21: a page written for a white
/// ground, its headings navy and its links dark blue, set no background of its own, so in the dark app they were
/// navy on near-black). The theme names the prelude hands a page only help a page that uses them; this is the floor
/// under every page, whatever its own styles say.
///
/// For each element that holds words (and each text field) the script works out what is behind it: the nearest
/// painted background up the tree, see-through ones laid over each other, a gradient taken as the mean of its stops,
/// and under them all the app's own page colour. Words that don't read against that have their lightness moved toward
/// white or black, whichever reads, hue and saturation kept (navy becomes a lighter blue, not grey). On a background
/// the page painted itself, and on the app's light page (a page with no background is written for white), both
/// colours are the page's own choice: only words under 3:1 are touched. On the app's dark page the standard holds in
/// full (4.5:1, 3:1 for large words). Words lost outright on the app's page were made for the other ground, so they
/// get the contrast they had on it (near-black body text becomes near-white, grey notes stay quieter than it; a
/// colour stops at 7:1); anything else is brought up to 4.5:1. A border or outline in the same ink follows it (a link drawn as a button keeps one colour).
/// A tile sits on its card, a little off the page colour: near enough that the same answers hold.
///
/// A drawing (`<svg>`): words over a filled shape (a label inside a bar) are judged against that fill, and so are a
/// page's words laid over a drawing (the number in the middle of a ring). A drawing whose words and lines were both
/// made for the other ground (dark labels and dark axes, in a dark app) is not recoloured piece by piece: it gets a
/// card of that ground behind it, so every part of it stays as it was drawn.
///
/// It only changes what it is sure of. Left alone: words lying over a picture, a video, a canvas or a frame (with no
/// background of their own between); words over a `background-image: url()` with no colour under it; words clipped to
/// a gradient (`background-clip: text`); what a `<canvas>` draws; shapes and icons with no words (faint on purpose
/// can't be told from lost); anything inside a frame.
///
/// It runs again when the page changes and when the pointer or the focus moves, first taking its own inks back with
/// those parts' transitions off (a `transition: color` would otherwise show it its own ink, fading, as the page's). An ink the page has set over ours since is the page's and stays. A change is answered at once, before it
/// is painted; the wait before the next run grows with what a run cost.
enum PageLegibility {
    /// The ground colour array passed to `PageLegibility` for `traits`.
    static func groundJS(_ traits: UITraitCollection, ground: UIColor = ChatPalette.page) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ground.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return "[\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),1]"
    }

    /// The script, for the page colour the web view sits on in `traits`.
    static func script(_ traits: UITraitCollection, ground: UIColor = ChatPalette.page) -> String {
        source.replacingOccurrences(of: "__GROUND__", with: groundJS(traits, ground: ground))
    }

    /// `FLOOR` and `GOAL` are WCAG's 3:1 (large text, and the least anything is left at) and 4.5:1 (body text);
    /// `MOST` caps one pass on a very long page.
    static let source = #"""
    (function(){
    var GROUND=__GROUND__,FLOOR=3,GOAL=4.5,MOST=6000,SKIP=/^(script|style|noscript|template|textarea|option|title|desc|metadata)$/i;
    var EDGES=['border-top-color','border-right-color','border-bottom-color','border-left-color','outline-color'];
    var mine=[],memo={},timer=0,last=0,gap=200,watch=null,media=null,shapes=null,clips=null;
    var cv=document.createElement('canvas');cv.width=cv.height=1;var cx=cv.getContext('2d',{willReadFrequently:true});
    // Any CSS colour as [r,g,b,a]; one the canvas can't read is clear (not judged).
    function rgba(c){var v=memo[c];if(v)return v;cx.clearRect(0,0,1,1);cx.fillStyle='#010203';cx.fillStyle=c;
      if(cx.fillStyle==='#010203'&&!/^(#010203|rgb\(1, ?2, ?3\))$/i.test(c))return memo[c]=[0,0,0,0];
      cx.fillRect(0,0,1,1);var d=cx.getImageData(0,0,1,1).data;return memo[c]=[d[0],d[1],d[2],d[3]/255]}
    function over(t,u){var a=t[3];return [t[0]*a+u[0]*(1-a),t[1]*a+u[1]*(1-a),t[2]*a+u[2]*(1-a),1]}
    function lay(t,u){var a=t[3]+u[3]*(1-t[3]);if(a<=0)return [0,0,0,0];function f(i){return (t[i]*t[3]+u[i]*u[3]*(1-t[3]))/a}
      return [f(0),f(1),f(2),a]}
    function lum(c){function f(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4)}
      return 0.2126*f(c[0])+0.7152*f(c[1])+0.0722*f(c[2])}
    function ratio(a,b){var x=lum(a),y=lum(b);return (Math.max(x,y)+0.05)/(Math.min(x,y)+0.05)}
    function num(v){v=parseFloat(v);return isNaN(v)?1:v}
    function css(c){return 'rgb('+Math.round(c[0])+','+Math.round(c[1])+','+Math.round(c[2])+')'}
    function hsl(c){var r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),l=(mx+mn)/2,d=mx-mn,h=0,s=0;
      if(d>0){s=d/(1-Math.abs(2*l-1));h=mx===r?((g-b)/d)%6:mx===g?(b-r)/d+2:(r-g)/d+4;h*=60;if(h<0)h+=360}return [h,Math.min(1,s),l]}
    function rgb(h,s,l){var c=(1-Math.abs(2*l-1))*s,x=c*(1-Math.abs((h/60)%2-1)),m=l-c/2,
      v=h<60?[c,x,0]:h<120?[x,c,0]:h<180?[0,c,x]:h<240?[0,x,c]:h<300?[x,0,c]:[c,0,x];return [(v[0]+m)*255,(v[1]+m)*255,(v[2]+m)*255]}
    // The ink's lightness toward the pole that reads on `back`, hue and saturation kept, until it passes.
    function lift(ink,back,goal){var up=ratio([255,255,255],back)>=ratio([0,0,0],back),k=hsl(ink),c=ink;
      for(var i=1;i<=40&&ratio(c,back)<goal;i++)c=rgb(k[0],k[1],up?k[2]+(1-k[2])*i/40:k[2]*(1-i/40));return c}
    // How far to lift. On the app's own page the words were made for the other ground (dark on a page taken for
    // white): they get the contrast they had there, so body text stays stronger than muted text; a colour stops at
    // 7:1, before it washes out. On a ground the page painted itself, just enough to read.
    function goal(ink,back){if(back!==GROUND)return GOAL;
      var made=lum(back)<0.18?[255,255,255,1]:[28,28,30,1];
      return Math.max(GOAL,Math.min(ratio(over(ink,made),made),hsl(ink)[1]>0.2?7:16))}
    function stops(image){var m=image.match(/(rgba?|hsla?|color|oklch|oklab|lab|lch)\([^()]*\)|#[0-9a-f]{3,8}\b/gi);
      if(!m||!m.length)return null;var s=[0,0,0,0];m.forEach(function(c){c=rgba(c);for(var i=0;i<4;i++)s[i]+=c[i]/m.length});return s}
    // What is painted behind an element's words; null when it can't be known (a picture).
    function ground(el,seen){
      if(!el||el.nodeType!==1)return GROUND;
      if(seen.has(el))return seen.get(el);
      var cs=getComputedStyle(el),layer=rgba(cs.backgroundColor),image=cs.backgroundImage,out;
      if(image&&image!=='none'){
        if(/url\(/.test(image)){if(layer[3]<0.999){seen.set(el,null);return null}}
        else{var g=stops(image);if(g)layer=lay(g,layer)}
      }
      if(layer[3]>=0.999)out=layer;
      else{var under=ground(el.parentElement,seen);out=under===null?null:(layer[3]>0?over(layer,under):under)}
      seen.set(el,out);return out}
    // The window an element's parents let it show through (a map clips the tiles that run past its edge: a line of
    // words above the map is not over them); null when nothing clips it.
    function clip(el){
      if(!el||el.nodeType!==1)return null;if(clips.has(el))return clips.get(el);
      var c=clip(el.parentElement),cs=getComputedStyle(el);
      if(/hidden|auto|scroll|clip/.test(cs.overflowX+' '+cs.overflowY)){var b=el.getBoundingClientRect();
        c=c?{left:Math.max(c.left,b.left),top:Math.max(c.top,b.top),right:Math.min(c.right,b.right),bottom:Math.min(c.bottom,b.bottom)}
           :{left:b.left,top:b.top,right:b.right,bottom:b.bottom}}
      clips.set(el,c);return c}
    // The part of an element that shows, or null.
    function shown(el){var b=el.getBoundingClientRect(),c=clip(el.parentElement),
      r=c?{left:Math.max(c.left,b.left),top:Math.max(c.top,b.top),right:Math.min(c.right,b.right),bottom:Math.min(c.bottom,b.bottom)}:b;
      return r.right>r.left&&r.bottom>r.top?r:null}
    // The pictures, videos, canvases, drawings and frames an element's middle lies over: not its own parents or
    // children, and none that a background of its own (a tooltip's) covers.
    function mediaUnder(el){
      if(!media){media=[];var all=document.querySelectorAll('img,video,canvas,svg,iframe,object,embed');
        for(var i=0;i<all.length&&media.length<300;i++){var b=shown(all[i]);if(b)media.push([all[i],b])}}
      // The first line of its words (a float beside them is not under them), else its box.
      var r=null,out=[];if(!media.length)return out;
      if(el.firstChild&&!(el instanceof SVGElement)){try{var g=document.createRange();g.selectNodeContents(el);var rs=g.getClientRects();
        for(var k=0;k<rs.length&&!r;k++)if(rs[k].width>0&&rs[k].height>0)r=rs[k]}catch(e){}}
      if(!r)r=el.getBoundingClientRect();if(!(r.width>0&&r.height>0))return out;
      var x=r.left+r.width/2,y=r.top+r.height/2,own;
      for(var j=0;j<media.length;j++){var m=media[j][0],q=media[j][1];
        if(x<q.left||x>q.right||y<q.top||y>q.bottom||m.contains(el)||el.contains(m))continue;
        if(own===undefined){own=null;for(var e=el;e&&e.nodeType===1&&!own;e=e.parentElement){var cs=getComputedStyle(e);
          if(rgba(cs.backgroundColor)[3]>=0.999||cs.backgroundImage!=='none')own=e}}
        if(!own||own.contains(m))out.push(m)}
      out.x=x;out.y=y;return out}
    function root(el){var r=el.tagName.toLowerCase()==='svg'?el:el.ownerSVGElement;if(!r)return null;while(r.ownerSVGElement)r=r.ownerSVGElement;return r}
    function paint(cs,which){var raw=cs[which];if(!raw||raw==='none')return null;if(/url\(/.test(raw))return 'url';
      var c=rgba(raw);return [c[0],c[1],c[2],c[3]*num(cs[which+'Opacity'])*num(cs.opacity)]}
    function filled(r){var list=shapes.get(r);if(list)return list;list=[];
      var all=r.querySelectorAll('rect,circle,ellipse,path,polygon');
      for(var i=0;i<all.length&&list.length<400;i++){var s=all[i];if(s.closest('defs,clipPath,mask,pattern,symbol,marker'))continue;
        var f=paint(getComputedStyle(s),'fill');if(f&&(f==='url'||f[3]>=0.05))list.push([s,f])}
      shapes.set(r,list);return list}
    // What a drawing paints at a point of the screen: its last filled shape there (one drawn before `before`, when
    // given), else the drawing's own ground.
    function at(r,p,seen,before){
      var base=ground(r,seen);if(base===null||!p)return base;var list=filled(r);
      for(var i=list.length-1;i>=0;i--){var s=list[i][0],f=list[i][1];
        if(before&&(s===before||!(s.compareDocumentPosition(before)&4)||s.contains(before)))continue;
        try{var m=s.getScreenCTM();if(!m||!s.isPointInFill(p.matrixTransform(m.inverse())))continue}catch(e){continue}
        if(f==='url')return null;
        return f[3]>=0.999?f:over(f,base)}
      return base}
    function middle(el){try{var b=el.getBBox(),m=el.getScreenCTM();if(!m||!(b.width>0||b.height>0))return null;
      return new DOMPoint(b.x+b.width/2,b.y+b.height/2).matrixTransform(m)}catch(e){return null}}
    function set(el,p,v){var s=el.style,was=s.getPropertyValue(p),pri=s.getPropertyPriority(p);s.setProperty(p,v,'important');
      mine.push([el,p,was,pri,s.getPropertyValue(p)])}
    // Our inks taken back; one the page has set over ours since is the page's.
    function undo(){for(var i=mine.length-1;i>=0;i--){var m=mine[i],s=m[0].style;
      if(s.getPropertyValue(m[1])!==m[4]||s.getPropertyPriority(m[1])!=='important')continue;
      if(m[2])s.setProperty(m[1],m[2],m[3]);else s.removeProperty(m[1])}mine=[]}
    // The parts that carry our inks, their own transitions off while the inks are taken back and judged again (only
    // theirs: a map's zoom, or any other motion of the page's, runs on).
    function hold(){var seen=new Set(),was=[];mine.forEach(function(m){var el=m[0];if(seen.has(el))return;seen.add(el);
      var s=el.style;was.push([el,s.getPropertyValue('transition'),s.getPropertyPriority('transition')]);s.setProperty('transition','none','important')});
      return was}
    function release(was){was.forEach(function(w){var s=w[0].style;if(w[1])s.setProperty('transition',w[1],w[2]);else s.removeProperty('transition')})}
    // A drawing made for the other ground, words and lines both: a card of that ground behind it, and it is left as drawn.
    function charts(seen){
      var all=document.querySelectorAll('svg');
      for(var i=0;i<all.length&&i<80;i++){var r=all[i];if(r.ownerSVGElement)continue;
        var box=r.getBoundingClientRect();if(box.width<120||box.height<60||getComputedStyle(r).display==='none')continue;
        var base=ground(r,seen);if(base===null||mediaUnder(r).length)continue;
        var card=lum(base)<0.18?[255,255,255,1]:[28,28,30,1],lost=0,fine=true,words=r.querySelectorAll('text');
        for(var j=0;j<words.length&&j<300&&fine;j++){var t=words[j],ink=paint(getComputedStyle(t),'fill');
          if(!ink||ink==='url'||ink[3]<0.1||at(r,middle(t),seen,t)!==base)continue;
          if(ratio(over(ink,base),base)<FLOOR)lost++;
          if(ratio(over(ink,card),card)<FLOOR)fine=false}
        if(!lost||!fine)continue;
        var marks=r.querySelectorAll('line,polyline,path,rect,circle,ellipse,polygon'),gone=false;
        for(var k=0;k<marks.length&&k<600&&!gone;k++){var cs=getComputedStyle(marks[k]);
          ['stroke','fill'].forEach(function(which){var c=paint(cs,which);if(!c||c==='url'||c[3]<0.3)return;
            if(which==='stroke'?!(parseFloat(cs.strokeWidth)>0):marks[k].tagName.toLowerCase()==='line')return;   // a line has no inside
            if(ratio(over(c,base),base)<2&&ratio(over(c,card),card)>=FLOOR)gone=true})}
        if(!gone)continue;
        set(r,'background-color',css(card));set(r,'border-radius','8px');seen.set(r,card)}}
    // What words must have to count as readable. On the app's dark page, the standard in full: 4.5:1, or 3:1 for
    // large words (24 px, or 18.66 px bold). Where both colours are the page's own choice, only under 3:1 is it
    // stepped in on: on a ground it painted itself, and on the app's light page (a page with no background is
    // written for white, so there it shows as its writer saw it).
    function need(cs,back){if(back!==GROUND||lum(GROUND)>=0.18)return FLOOR;var px=parseFloat(cs.fontSize),w=parseInt(cs.fontWeight,10)||400;
      return px>=24||(px>=18.66&&w>=700)?FLOOR:GOAL}
    function check(el,seen){
      var svg=typeof SVGElement!=='undefined'&&el instanceof SVGElement,cs=getComputedStyle(el),prop,raw,back,r=null;
      if(cs.display==='none'||cs.visibility==='hidden')return;
      if(svg){r=root(el);if(!r)return;prop='fill';raw=cs.fill;back=at(r,middle(el),seen,el)}
      else{if(cs.webkitBackgroundClip==='text'||cs.backgroundClip==='text')return;
        var tf=cs.webkitTextFillColor;prop=tf&&tf!==cs.color?'-webkit-text-fill-color':'color';raw=prop==='color'?cs.color:tf;back=ground(el,seen)}
      if(back===null||!raw||raw==='none'||/url\(/.test(raw))return;
      var ink=rgba(raw);if(ink[3]<0.1)return;
      var laid=over(ink,back),had=ratio(laid,back);if(had>=need(cs,back))return;
      // Over something that is not its parent: a drawing says what it paints there, anything else can't be known.
      var under=mediaUnder(svg?r:el);
      if(under.length){
        for(var i=0;i<under.length;i++)if(under[i].tagName.toLowerCase()!=='svg')return;
        if(svg)return;
        back=at(root(under[under.length-1]),new DOMPoint(under.x,under.y),seen,null);if(back===null)return;
        laid=over(ink,back);had=ratio(laid,back);if(had>=need(cs,back))return}
      // Lost outright, they were made for the other ground; only a little short, they are brought up to the standard.
      var to=css(lift(laid,back,had<FLOOR?goal(ink,back):GOAL));set(el,prop,to);
      if(prop==='color')EDGES.forEach(function(p){if(cs.getPropertyValue(p)===raw)set(el,p,to)})}
    function run(){
      clearTimeout(timer);timer=0;if(!document.body)return;
      var t0=performance.now(),held=hold();undo();media=null;shapes=new Map();clips=new Map();
      var seen=new Map(),done=new Set(),n=0,walk=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),node;
      charts(seen);
      while((node=walk.nextNode())&&n<MOST){var el=node.parentElement;
        if(!el||done.has(el)||!/\S/.test(node.nodeValue)||SKIP.test(el.tagName))continue;
        done.add(el);n++;check(el,seen)}
      document.querySelectorAll('input,textarea,select').forEach(function(el){if(n++<MOST)check(el,seen)});
      void document.body.offsetWidth;release(held);   // the inks are in before those transitions run again
      if(watch)watch.takeRecords();
      gap=Math.max(200,Math.min(5000,(performance.now()-t0)*25));last=Date.now()}
    // At once on a change (before it is painted: no dark words flash), then no sooner than `gap` after the last run.
    function soon(){var wait=last+gap-Date.now();clearTimeout(timer);if(wait<=0)run();else timer=setTimeout(run,wait)}
    function start(){run();if(watch||!document.body)return;watch=new MutationObserver(soon);
      watch.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,
        attributeFilter:['class','style','hidden','open','fill','stroke']});
      ['pointerover','pointerout','focusin','focusout'].forEach(function(e){document.addEventListener(e,soon,true)})}
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);else start();
    window.addEventListener('load',run);
    window.__hqLegible={run:run,setGround:function(g){GROUND=g;memo={};run()},count:function(){return mine.length},wait:function(){return gap}};
    })();
    """#
}
