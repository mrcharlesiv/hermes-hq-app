import UIKit

// Commenting on a page a bot made: turn Comment on in the page's bar, point at any part of the page (a heading, a
// chart, a row, some selected words) and say what should change. The part is ringed, a small box asks for the
// comment, and it goes to the page's bot with the part named, so "make this bigger" needs no describing of which
// "this". Owner 2026-11-17: the page had to be at least as good to work with as Grok Bot's, which does this.
//
// The page side is a script in the page's prelude, asleep until the bar's button wakes it (`window.__hqComment`);
// while awake it takes clicks before the page does, so pointing at a button doesn't press it.

@MainActor enum PageComment {
    /// The part of the page a comment is about, as the page's script named it.
    struct Target {
        enum Kind: String { case element, text }
        var kind: Kind
        /// "Heading", "Chart", "Button"… ("Selected text" for chosen words).
        var label: String
        /// The part's own words (a heading's text, a button's name, the chosen words), cut to a line or two.
        var text: String
        /// Where it is in the page's markup (`div.card > h2`), for the bot.
        var path: String
        /// In the page's own pixels, with the page's width in them (`viewport`).
        var rect: CGRect
        var viewport: CGFloat

        init?(_ body: [String: Any]) {
            guard let kind = (body["kind"] as? String).flatMap(Kind.init),
                  let x = body["x"] as? Double, let y = body["y"] as? Double,
                  let w = body["w"] as? Double, let h = body["h"] as? Double else { return nil }
            self.kind = kind
            label = String((body["label"] as? String ?? "Part").prefix(40))
            text = String((body["text"] as? String ?? "").prefix(300))
            path = String((body["path"] as? String ?? "").prefix(300))
            rect = CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
            viewport = CGFloat(body["vw"] as? Double ?? 0)
        }

        /// The part in the web view's own coordinates (the Mac lays a page out at its own zoom).
        func frame(in web: UIView) -> CGRect {
            let k = viewport > 0 ? web.bounds.width / viewport : 1
            return CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
                .intersection(web.bounds.insetBy(dx: -1, dy: -1))
        }

        /// One line naming the part: `Heading · “Replies per 100 follow-ups”`.
        var caption: String {
            let words = text.count > 60 ? String(text.prefix(58)) + "…" : text
            return words.isEmpty ? label : "\(label) · “\(words)”"
        }
    }

    /// What the bot is sent, and what the chat's bubble shows (shorter: no markup path).
    static func message(_ note: String, about target: Target, file: String) -> (text: String, display: String) {
        let part = target.kind == .text ? "the words “\(target.text)”"
            : target.text.isEmpty ? "the \(target.label.lowercased())" : "the \(target.label.lowercased()) “\(target.text)”"
        let display = "On \(file), about \(part):\n\(note)"
        let place = target.path.isEmpty ? "" : "\n(In the page’s markup: \(target.path))"
        return (display + place + "\nChange the page’s file in place.", display)
    }

    /// The page's side. `accent` is a CSS colour for the ring.
    static func script(accent: String) -> String {
        #"""
        (function(){if(window.__hqComment)return;var A='var(--accent,\#(accent))',on=false,ring=null,held=null,touch=null,last=0;
        function post(m){try{window.webkit.messageHandlers.hermes.postMessage({id:0,comment:m})}catch(e){}}
        function box(){if(!ring){ring=document.createElement('div');ring.setAttribute('data-hq-comment-ring','');
        ring.style.cssText='position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;border:1.5px solid '+A+
        ';border-radius:8px;background:color-mix(in srgb,'+A+' 12%,transparent);opacity:0;transition:opacity .12s ease-out';
        document.documentElement.appendChild(ring)}return ring}
        function put(r){var b=box(),p=4;b.style.left=(r.left-p)+'px';b.style.top=(r.top-p)+'px';
        b.style.width=(r.width+2*p)+'px';b.style.height=(r.height+2*p)+'px';b.style.opacity='1'}
        function hide(){if(ring)ring.style.opacity='0'}
        function pick(x,y){var e=document.elementFromPoint(x,y);if(!e||e===document.documentElement||e===document.body)return null;
        var s=e.closest&&e.closest('svg');if(s&&e!==s){var r=e.getBoundingClientRect();if(r.width<24||r.height<24)e=s}return e}
        var names={P:'Paragraph',BUTTON:'Button',A:'Link',IMG:'Picture',SVG:'Chart',CANVAS:'Chart',TABLE:'Table',TR:'Row',
        TD:'Cell',TH:'Column',LI:'List item',UL:'List',OL:'List',INPUT:'Field',TEXTAREA:'Field',SELECT:'Menu',LABEL:'Label',
        VIDEO:'Video',NAV:'Menu bar',SECTION:'Section',ARTICLE:'Section',HEADER:'Header',FOOTER:'Footer',FORM:'Form',
        BLOCKQUOTE:'Quote',PRE:'Code',CODE:'Code',FIGURE:'Figure',SPAN:'Text',STRONG:'Text',EM:'Text',B:'Text',I:'Text'};
        function kind(e){var t=e.tagName.toUpperCase();if(/^H[1-6]$/.test(t))return'Heading';
        if(e.getAttribute('role')==='button')return'Button';return names[t]||'Part'}
        function words(e){var t=e.getAttribute('aria-label')||e.getAttribute('alt')||e.getAttribute('title')||e.innerText||e.textContent||'';
        return t.replace(/\s+/g,' ').trim().slice(0,160)}
        function where(e){var out=[];for(var n=e;n&&n.tagName&&n!==document.body&&out.length<4;n=n.parentElement){
        var s=n.tagName.toLowerCase();if(n.id)s+='#'+n.id;else if(typeof n.className==='string'&&n.className.trim())
        s+='.'+n.className.trim().split(/\s+/)[0];out.unshift(s)}return out.join(' > ').slice(0,300)}
        function tell(k,label,text,path,r){post({kind:k,label:label,text:text,path:path,x:r.left,y:r.top,w:r.width,h:r.height,
        vw:document.documentElement.clientWidth})}
        function choose(x,y){var sel=window.getSelection&&window.getSelection(),q=sel&&!sel.isCollapsed?String(sel).replace(/\s+/g,' ').trim():'';
        if(q&&sel.rangeCount){var r=sel.getRangeAt(0).getBoundingClientRect();held={rect:function(){return sel.rangeCount?sel.getRangeAt(0).getBoundingClientRect():r}};
        put(r);var n=sel.anchorNode;tell('text','Selected text',q.slice(0,300),where(n&&(n.nodeType===1?n:n.parentElement)||document.body),r);return}
        var e=pick(x,y);if(!e)return;held={rect:function(){return e.getBoundingClientRect()}};var b=e.getBoundingClientRect();
        if('ontouchstart' in window&&b.top>innerHeight*0.38){window.scrollBy(0,b.top-innerHeight*0.2);b=e.getBoundingClientRect()}
        put(b);tell('element',kind(e),words(e),where(e),b)}
        function eat(ev){if(on){ev.stopImmediatePropagation()}}
        window.addEventListener('mousemove',function(ev){if(!on||held)return;var e=pick(ev.clientX,ev.clientY);
        if(e)put(e.getBoundingClientRect());else hide()},true);
        window.addEventListener('mouseleave',function(){if(on&&!held)hide()},true);
        window.addEventListener('click',function(ev){if(!on)return;ev.preventDefault();ev.stopImmediatePropagation();
        if(Date.now()-last<600)return;last=Date.now();choose(ev.clientX,ev.clientY)},true);
        window.addEventListener('touchstart',function(ev){if(!on)return;var t=ev.touches[0];
        touch=ev.touches.length===1?{x:t.clientX,y:t.clientY,at:Date.now()}:null},{capture:true,passive:true});
        window.addEventListener('touchend',function(ev){if(!on||!touch)return;var t=ev.changedTouches[0],s=touch;touch=null;
        if(Math.abs(t.clientX-s.x)>10||Math.abs(t.clientY-s.y)>10||Date.now()-s.at>600)return;
        ev.preventDefault();ev.stopImmediatePropagation();last=Date.now();choose(t.clientX,t.clientY)},{capture:true,passive:false});
        ['mousedown','mouseup','pointerdown','pointerup','dblclick','submit'].forEach(function(n){window.addEventListener(n,eat,true)});
        window.addEventListener('scroll',function(){if(!on)return;if(held)put(held.rect());else hide()},true);
        window.addEventListener('keydown',function(ev){if(on&&ev.key==='Escape'){ev.preventDefault();ev.stopImmediatePropagation();post({kind:'escape'})}},true);
        window.__hqComment={set:function(v){on=!!v;held=null;hide();var d=document.documentElement;
        if(on)d.setAttribute('data-hq-commenting','');else d.removeAttribute('data-hq-commenting')},
        release:function(){held=null;hide()},
        sent:function(){held=null;if(!ring)return;ring.style.background='color-mix(in srgb,'+A+' 30%,transparent)';
        setTimeout(function(){if(ring){ring.style.opacity='0';setTimeout(function(){if(ring)ring.style.background='color-mix(in srgb,'+A+' 12%,transparent)'},160)}},180)}};
        var st=document.createElement('style');st.textContent='html[data-hq-commenting],html[data-hq-commenting] *{cursor:crosshair!important}';
        (document.head||document.documentElement).appendChild(st)})();
        """#
    }
}

/// The small box that asks for the comment, pointing at the part of the page it is about.
final class PageCommentBox: UIViewController, UITextViewDelegate, UIPopoverPresentationControllerDelegate {
    private let caption = UILabel()
    private let field = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let target: PageComment.Target
    private let onSend: (String) -> Void
    private let onClose: () -> Void
    private var sent = false
    private static let width: CGFloat = 300

    /// `onClose` runs when the box goes without a comment sent (the ring on the page is let go).
    init(target: PageComment.Target, onSend: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.target = target
        self.onSend = onSend
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shown from `host`, its arrow at `rect` of `view`.
    func present(from host: UIViewController, at rect: CGRect, in view: UIView) {
        guard let popover = popoverPresentationController else { return }
        popover.sourceView = view
        popover.sourceRect = rect
        // Under a part near the top (over it, the box covered the page's bar); over one further down, clear of the keyboard.
        popover.permittedArrowDirections = rect.midY < view.bounds.height * 0.3 ? .up : .down
        popover.delegate = self
        // [desktoplook3] A solid panel in the Desktop Look, not the popover's glass (as the app's other pop-overs).
        if Theme.isDesktop { popover.backgroundColor = ChatPalette.editor }
        host.present(self, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "page.comment.box"
        caption.text = target.caption
        caption.font = HQFont.preferred(.footnote)
        caption.textColor = ChatPalette.label2
        caption.lineBreakMode = .byTruncatingTail
        caption.adjustsFontForContentSizeCategory = true

        field.font = HQFont.preferred(.body)
        field.adjustsFontForContentSizeCategory = true
        field.backgroundColor = .clear
        field.textColor = ChatPalette.label
        field.tintColor = ChatPalette.caret
        field.textContainerInset = .zero
        field.textContainer.lineFragmentPadding = 0
        field.isScrollEnabled = false
        field.delegate = self
        field.accessibilityLabel = "Comment"
        field.accessibilityIdentifier = "page.comment.field"

        placeholder.text = "Add a comment"
        placeholder.font = field.font
        placeholder.textColor = ChatPalette.label3
        placeholder.isAccessibilityElement = false

        var look = UIButton.Configuration.filled()
        look.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        look.cornerStyle = .capsule
        look.baseBackgroundColor = ChatPalette.tint
        look.baseForegroundColor = ChatPalette.onTint
        look.contentInsets = .zero
        sendButton.configuration = look
        sendButton.isEnabled = false
        sendButton.accessibilityLabel = "Send Comment"
        sendButton.accessibilityIdentifier = "page.comment.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)

        for sub in [caption, field, placeholder, sendButton] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            caption.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            caption.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            field.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            field.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
            placeholder.topAnchor.constraint(equalTo: field.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            sendButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        fit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !sent { onClose() }
    }

    /// As tall as its words, up to about six lines; then the words scroll.
    private func fit() {
        let room = Self.width - 14 - 8 - 28 - 10
        let most = ceil((field.font?.lineHeight ?? 20) * 6)
        let wanted = ceil(field.sizeThatFits(CGSize(width: room, height: .greatestFiniteMagnitude)).height)
        field.isScrollEnabled = wanted > most
        let captionHeight = ceil(caption.font.lineHeight)
        let size = CGSize(width: Self.width, height: 12 + captionHeight + 6 + max(28, min(wanted, most)) + 10)
        if preferredContentSize != size { preferredContentSize = size }
    }

    func textViewDidChange(_ textView: UITextView) {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        sendButton.isEnabled = !empty
        fit()
    }

    /// Return sends on the Mac (Shift-Return a new line, as the chat's box); the phone's Return is a new line.
    override var keyCommands: [UIKeyCommand]? {
        #if targetEnvironment(macCatalyst)
        let command = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromKey))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
        #else
        return [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendFromKey))]
        #endif
    }

    @objc private func sendFromKey() { send() }

    private func send() {
        let note = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, !sent else { return }
        sent = true
        Haptics.play(.light)
        dismiss(animated: true)
        onSend(note)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
}
