using System.Diagnostics;
using System.Text.Json;
using HermesHQ.Pages;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using CoreVirtualKeyStates = Windows.UI.Core.CoreVirtualKeyStates;

namespace HermesHQ;

internal sealed class NarratorChatWalk(string folder, Process reader)
{
    private sealed record Element(string Id, string Name, string Role, string Xaml);
    private sealed record At(Control View, Element Uia, string Stop);
    private sealed class InputReceipt(string key)
    {
        public string Key { get; } = key;
        public string Api => "SendInput";
        public uint Inserted { get; set; }
        public int Received { get; set; }
        public string? ReceivedKey { get; set; }
        public int FocusEvents { get; set; }
        public string? FocusState { get; set; }
        public long FrontBefore { get; set; }
        public long FrontAfter { get; set; }
        public bool? EmptyBefore { get; set; }
        public string? DraftAfter { get; set; }
        public bool? SendEnabled { get; set; }
    }
    private sealed class SpeechReceipt(int at)
    {
        public int At { get; } = at;
        public string Source => "Narrator.CopyLastPhrase";
        public string Key => "Insert+Ctrl+X";
        public uint Inserted { get; set; }
        public int ReceivedX { get; set; }
        public long FrontBefore { get; set; }
        public long FrontAfter { get; set; }
        public uint SequenceBefore { get; set; }
        public uint SequenceAfter { get; set; }
        public int OwnerPid { get; set; }
        public string? Text { get; set; }
        public string? Unavailable { get; set; }
    }

    private readonly List<Element> _focus = [];
    private readonly List<InputReceipt> _physical = [];
    private readonly List<SpeechReceipt> _speech = [];
    private nint _hwnd;
    private XamlRoot _root = null!;
    private ChatPage _chat = null!;
    private bool _lost, _complete, _copyDisabled;
    private uint? _lastClipboard;
    private int _epoch, _received;
    private int? _seededMessages;
    private VirtualKey _listening;
    private string? _receivedKey;
    private Control? _origin;
    private DependencyObject? _lastFocused;
    public string? Stop { get; set; }

    public void Save()
    {
        var path = Path.Combine(folder, "trace.json");
        var json = new { schema = 1, appPid = Environment.ProcessId, hwnd = _hwnd.ToInt64(), narratorPid = reader.Id,
            seededMessages = _seededMessages, completed = _complete, stop = Stop, focus = _focus, physical = _physical, speech = _speech };
        File.WriteAllText(path + ".next", JsonSerializer.Serialize(json, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
        File.Move(path + ".next", path, overwrite: true);
    }

    public async Task Run(MainWindow window)
    {
        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        Save();
        var wait = Stopwatch.StartNew();
        while (ChatPage.Current is not { IsLoaded: true, MessageCount: > 0 })
        {
            if (wait.Elapsed.TotalSeconds >= 25) throw new NarratorStop("no-loaded-fixture-chat");
            await Task.Delay(100); // no keys until a real chat has opened and taken the focus
        }
        _chat = ChatPage.Current;
        if (_chat.StoredId != "20260929_120000_aabbcc01" || _chat.ChatTitle != "Proof Hermes" || _chat.MessageCount != 1)
            throw new NarratorStop("not-the-seeded-chat");
        _seededMessages = _chat.MessageCount;
        _root = _chat.XamlRoot;
        var content = _root.Content;
        var keys = new KeyEventHandler(KeyDown);
        // WinUI FocusManager events are local to this XAML process, not hooks on the desktop.
        void Focused(object? sender, FocusManagerGotFocusEventArgs e) { _lastFocused = e.NewFocusedElement; _epoch++; }
        void Activated(object sender, WindowActivatedEventArgs e) { if (e.WindowActivationState == WindowActivationState.Deactivated) _lost = true; }
        content.AddHandler(UIElement.PreviewKeyDownEvent, keys, true);
        FocusManager.GotFocus += Focused;
        window.Activated += Activated;
        try
        {
            var first = Here();
            if (first.Stop != "Message" || first.View is not TextBox { Text.Length: 0 }) throw new NarratorStop("unexpected-start");
            _focus.Add(first.Uia);
            await Observe(first); // baseline: last speech was NOT already Inspector. Not a physical move to the composer.
            var inspector = await Move(first, "Inspector", ChatKey.Previous);
            await Observe(inspector);
            var composer = await Move(inspector, "Message", ChatKey.Next);
            await Observe(composer);
            await Press(composer, ChatKey.Draft);
            var send = await Move(composer, "Send", ChatKey.Next);
            await Observe(send);
            _complete = true; // traversal finished; only the independent evidence validator may award a pass
        }
        finally
        {
            window.Activated -= Activated;
            content.RemoveHandler(UIElement.PreviewKeyDownEvent, keys);
            FocusManager.GotFocus -= Focused;
        }
    }

    private void KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_listening == VirtualKey.None || e.Key != _listening) return;
        if (!ReferenceEquals(FocusManager.GetFocusedElement(_root), _origin)) _lost = true;
        if (_listening != VirtualKey.X)
        {
            static bool Down(VirtualKey k) => InputKeyboardSource.GetKeyStateForCurrentThread(k).HasFlag(CoreVirtualKeyStates.Down);
            _receivedKey = Down(VirtualKey.Control) || Down(VirtualKey.Menu) || Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)
                ? "unexpected-modifiers" : (Down(VirtualKey.Shift) ? "Shift+" : "") + e.Key;
        }
        _received++; // scoped, passive receipt for the one key currently being tested (not a key log)
    }

    private long Front()
    {
        if (_lost || reader.HasExited || !ReferenceEquals(ChatPage.Current, _chat) || App.Window?.SheetShown != false ||
            VisualTreeHelper.GetOpenPopupsForXamlRoot(_root).Any(p => p.IsOpen && p.Child is not ToolTip))
            throw new NarratorStop("lost-fixture-or-modal-open");
        return NarratorDesktop.Front(_hwnd);
    }

    private At Here()
    {
        Front();
        if (FocusManager.GetFocusedElement(_root) is not Control c || c.XamlRoot != _root || !c.IsEnabled || !c.IsLoaded ||
            c.ActualWidth <= 0 || c.ActualHeight <= 0) throw new NarratorStop("unknown-xaml-focus");
        bool Under(DependencyObject? ancestor)
        {
            for (DependencyObject? v = c; v != null; v = VisualTreeHelper.GetParent(v))
                if (ReferenceEquals(v, ancestor)) return true;
            return false;
        }
        if (!Under(_chat)) throw new NarratorStop("focus-outside-fixture-chat");
        var peer = FrameworkElementAutomationPeer.FromElement(c) ?? FrameworkElementAutomationPeer.CreatePeerForElement(c);
        if (peer == null) throw new NarratorStop("no-focused-peer");
        var id = peer.GetAutomationId() ?? "";
        var name = peer.GetName() ?? "";
        var role = peer.GetAutomationControlType().ToString();
        var xaml = c.Name ?? "";
        // Identify by the real focused peer. Named template children, other pages, popup/consent controls: abort.
        var stop = (id.Length > 0 ? id : xaml, role, name) switch
        {
            ("chat.composer", "Edit", _) when ReferenceEquals(c, _chat.FindName("Composer")) => "Message",
            ("chat.send", "Button", _) when ReferenceEquals(c, _chat.FindName("SendButton")) => "Send",
            ("InspectorToggle", "Button", _) when ReferenceEquals(c, _chat.FindName("InspectorToggle")) => "Inspector",
            ("composer.plus", "Button", "Attach") when Under(_chat.FindName("ComposerLeading") as DependencyObject) => "Attach",
            ("", "Button", "Commands") when Under(_chat.FindName("ComposerLeading") as DependencyObject) => "Commands",
            ("chat.reply-more", "Button", "More") when Under(_chat.FindName("Messages") as DependencyObject) => "More",
            ("chat.regenerate-reply", "Button", "Regenerate") when Under(_chat.FindName("Messages") as DependencyObject) => "Regenerate",
            ("chat.transcript", "List", _) when ReferenceEquals(c, _chat.FindName("Messages")) => "Transcript",
            ("", "Button", "Model") when Under(_chat.FindName("ComposerTrailing") as DependencyObject) => "Model",
            _ => throw new NarratorStop("unrecognized-chat-stop"),
        };
        if (stop is "Message" or "Inspector" or "Send" or "Transcript" && name is not ("Message" or "Message Proof Hermes" or "Inspector" or "Send" or ""))
            name = "[unexpected name omitted]";
        return new(c, new(id, name, role, xaml), stop);
    }

    private void Still(At expected, int epoch)
    {
        if (_epoch != epoch || !ReferenceEquals(Here().View, expected.View)) throw new NarratorStop("focus-changed-during-observation");
    }

    private async Task<At> Move(At current, string target, ChatKey direction)
    {
        var seen = new HashSet<string> { current.Stop };
        for (int i = 0; i < 12; i++)
        {
            current = await Press(current, direction);
            if (current.Stop == target) return current;
            if (!seen.Add(current.Stop) || !(target == "Send" ? current.Stop == "Model" :
                current.Stop is "Attach" or "Commands" or "Regenerate" or "More" or "Transcript")) break;
        }
        throw new NarratorStop("out-of-order-or-cyclic-tab-stops");
    }

    private async Task<At> Press(At from, ChatKey action)
    {
        var draft = action == ChatKey.Draft;
        var receipt = new InputReceipt(draft ? "Q" : action == ChatKey.Previous ? "Shift+Tab" : "Tab");
        var epoch = _epoch;
        if (draft)
        {
            if (from.Stop != "Message" || from.View is not TextBox { Text.Length: 0 }) throw new NarratorStop("draft-not-empty");
            receipt.EmptyBefore = true;
        }
        _origin = from.View;
        _received = 0;
        _receivedKey = null;
        _listening = draft ? VirtualKey.Q : VirtualKey.Tab;
        _physical.Add(receipt);
        try
        {
            (receipt.FrontBefore, receipt.Inserted) = NarratorDesktop.Press(_hwnd, action, () => Still(from, epoch));
            if (receipt.Inserted != (action == ChatKey.Previous ? 4 : 2)) throw new NarratorStop("incomplete-key-batch");
            var wait = Stopwatch.StartNew();
            while (wait.ElapsedMilliseconds < 1800)
            {
                await Task.Delay(40);
                var now = Here();
                if (draft ? _epoch != epoch || !ReferenceEquals(now.View, from.View) : _epoch > epoch + 1)
                    throw new NarratorStop("unexpected-focus-transition");
                bool effect = draft ? now.View is TextBox { Text: "q" } && _chat.FindName("SendButton") is Button { IsEnabled: true }
                                    : !ReferenceEquals(now.View, from.View);
                if (!effect) continue;
                if (!draft && _epoch == epoch) continue; // the local GotFocus event may follow the changed current element
                receipt.FrontAfter = Front();
                receipt.FocusState = now.View.FocusState.ToString();
                if (draft) { receipt.DraftAfter = ((TextBox)now.View).Text; receipt.SendEnabled = true; }
                _focus.Add(now.Uia);
                if ((!draft && !ReferenceEquals(_lastFocused, now.View)) || now.View.FocusState != FocusState.Keyboard)
                    throw new NarratorStop("not-a-keyboard-focus-arrival");
                if (_received != 1 || _receivedKey != receipt.Key) throw new NarratorStop("key-not-received-on-intended-control");
                return now;
            }
            throw new NarratorStop("key-did-not-change-focus-or-draft");
        }
        finally
        {
            _listening = VirtualKey.None;
            receipt.Received = _received;
            receipt.ReceivedKey = _receivedKey;
            receipt.FocusEvents = _epoch - epoch;
            Save();
        }
    }

    private async Task Observe(At target)
    {
        var obs = new SpeechReceipt(_focus.Count - 1);
        _speech.Add(obs);
        if (_copyDisabled) { obs.Unavailable = "no-attributable-narrator-output"; Save(); return; }
        var epoch = _epoch;
        try
        {
            // Let the ordinary focus announcement settle. No read-current-control command (that would prompt speech).
            for (int i = 0; i < 12; i++) { await Task.Delay(100); Still(target, epoch); }
            if (!NarratorDesktop.MayCopy(_hwnd, reader.Id, _lastClipboard, out var before))
            { obs.Unavailable = "clipboard-not-empty-owned-or-available"; _copyDisabled = true; return; }
            obs.SequenceBefore = before;
            _received = 0;
            _listening = VirtualKey.X;
            _origin = target.View;
            (obs.FrontBefore, obs.Inserted) = NarratorDesktop.Press(_hwnd, ChatKey.CopyPhrase, () =>
            {
                Still(target, epoch);
                if (!NarratorDesktop.MayCopy(_hwnd, reader.Id, _lastClipboard, out var check) || check != before)
                    throw new NarratorStop("clipboard-changed-before-shortcut");
            });
            if (obs.Inserted != 6) throw new NarratorStop("incomplete-narrator-shortcut");
            for (int i = 0; i < 25; i++)
            {
                await Task.Delay(60);
                Still(target, epoch);
                if (_received != 0) { obs.Unavailable = "shortcut-reached-app"; _copyDisabled = true; return; }
                if (NarratorDesktop.ReadNew(_hwnd, reader.Id, before) is not { } phrase) continue;
                Still(target, epoch);
                obs.SequenceAfter = phrase.Sequence;
                obs.OwnerPid = phrase.Owner;
                if (phrase.Owner == reader.Id && phrase.Unavailable == null)
                {
                    await Task.Delay(100); // let any app-delivered shortcut or delayed focus event arrive
                    Still(target, epoch);
                    if (_received != 0 || !NarratorDesktop.MayCopy(_hwnd, reader.Id, phrase.Sequence, out _))
                    { obs.Unavailable = "shortcut-or-clipboard-not-stable"; _copyDisabled = true; return; }
                }
                obs.Text = phrase.Text;
                obs.Unavailable = phrase.Unavailable;
                obs.FrontAfter = Front();
                if (phrase.Owner == reader.Id) _lastClipboard = phrase.Sequence; else _copyDisabled = true;
                return;
            }
            obs.Unavailable = "no-fresh-narrator-phrase";
            _copyDisabled = true;
        }
        finally { if (_listening == VirtualKey.X) obs.ReceivedX = _received; _listening = VirtualKey.None; Save(); }
    }
}
