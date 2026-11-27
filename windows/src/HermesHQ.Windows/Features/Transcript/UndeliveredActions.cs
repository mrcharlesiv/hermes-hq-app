using Hermes.Core.Chat;
using Hermes.Core.Transcripts;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// [WIN-UNDELIVERED-ACTIONS] Your bubble marked "Delivery unconfirmed" (spec 04 §2.5): under it the read-only Check
/// ("Delivery Unconfirmed · Check", "Checking Delivery…" while it looks; App/Chat/ChatRow.swift, ChatCells.swift
/// `chat.delivery-check`), and in its menu Send Again and Delete (ChatMenus+Actions.swift `performMessageAction`).
/// The bubble itself is Controls/MessageView; the work is ChatSession's (Hermes.Core ChatSession+Undelivered.cs).
public static class UndeliveredActions
{
    /// Checks running now, by message id (the Mac's `ChatRowBuilder.checkingKey`): the line says "Checking Delivery…".
    private static readonly HashSet<string> Checking = [];

    public static bool IsChecking(string messageId) { lock (Checking) return Checking.Contains(messageId); }

    /// The line under the bubble: a button while it can check, words while it checks.
    public static FrameworkElement CheckLine(MessageItem item, Brush critical)
    {
        var id = item.Message.Id;
        var checking = IsChecking(id);
        var words = new TextBlock
        {
            Text = checking ? ChatSession.CheckingDeliveryWords : ChatSession.CheckDeliveryWords, FontSize = 11,
            TextWrapping = TextWrapping.Wrap, Foreground = critical,
        };
        if (checking || item.Owner is not { } owner)
        {
            words.HorizontalAlignment = HorizontalAlignment.Right;
            words.Margin = new Thickness(0, 3, 2, 0);
            return words;
        }
        var button = new HyperlinkButton
        {
            Content = words, Padding = new Thickness(6, 2, 6, 2), Margin = new Thickness(0, 1, -4, 0),
            HorizontalAlignment = HorizontalAlignment.Right, MinHeight = 0,
        };
        AutomationProperties.SetAutomationId(button, ChatSession.CheckDeliveryId);
        AutomationProperties.SetName(button, ChatSession.CheckDeliveryWords);
        AutomationProperties.SetHelpText(button, ChatSession.CheckDeliveryHint);
        button.Click += (_, _) => _ = Check(item, owner.Session);
        return button;
    }

    /// Check: never resends. Found, the mark goes (the session reads the chat again); not there, or couldn't tell, a
    /// notice over the transcript says so.
    public static async Task Check(MessageItem item, ChatSession session)
    {
        var id = item.Message.Id;
        lock (Checking) if (!Checking.Add(id)) return;
        item.Redraw();
        bool? found = null;
        try { found = await session.CheckDeliveryAsync(id); }
        catch (Exception ex) { HermesHQ.Services.AppLog.Error("transcript", ex); }
        finally
        {
            lock (Checking) Checking.Remove(id);
            item.Redraw();
        }
        var notice = found switch
        {
            true => null,
            false => ChatSession.NotThereYetNotice,
            null => ChatSession.CouldntCheckNotice,
        };
        if (notice != null && HermesHQ.Pages.ChatPage.Current is { } page && page.StoredId == session.StoredId)
            page.ShowNotice(notice, TimeSpan.FromSeconds(3));
    }

    /// The menu's Send Again and Delete (only on an unconfirmed send; the session refuses anything else).
    public static void Perform(ChatSession session, MessageMenuItem id, string messageId)
    {
        switch (id)
        {
            case MessageMenuItem.Retry:
                if (session.SendAgain(messageId) is { } send)
                    _ = send.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
                break;
            case MessageMenuItem.Delete:
                session.DeleteUndelivered(messageId);
                break;
        }
    }
}
