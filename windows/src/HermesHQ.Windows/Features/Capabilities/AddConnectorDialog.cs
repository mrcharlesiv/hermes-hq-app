using Hermes.Core.Capabilities;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Capabilities;

/// Connectors › Add Your Own… (App/Capabilities/AddConnectorController.swift): a name, a web address (with its sign-in
/// and headers) or a command (with arguments, environment and folder); Add calls `mcp.servers.add`, the bearer token
/// beside the entry, never in it. Cancel with something typed asks first.
internal static class AddConnectorDialog
{
    /// The new connector's name, or null when nothing was added.
    public static async Task<string?> ShowAsync(CapabilitiesModel model)
    {
        var draft = new ConnectorDraft();
        var refused = new HashSet<string>();
        IEnumerable<string> Existing() => (model.Servers ?? []).Select(s => s.Name).Concat(refused);
        var adding = false;
        string? added = null;
        var form = new StackPanel { Spacing = 12, Width = 460 };
        var dialog = new ContentDialog
        {
            Title = "Add a Connector", PrimaryButtonText = "Add", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            Content = new ScrollViewer { Content = form, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled },
        };

        UIElement Header(string text) => Kit.Text(text, 12, bold: true, color: Kit.Secondary);
        TextBox Field(string placeholder, string value, Action<string> set, string name)
        {
            var t = new TextBox { PlaceholderText = placeholder, Text = value, IsSpellCheckEnabled = false };
            AutomationProperties.SetName(t, name);
            t.TextChanged += (_, _) => { set(t.Text); Update(); };
            return t;
        }
        TextBlock nameNote = Kit.Text("", 12, secondary: true), typeNote = Kit.Text("", 12, secondary: true);

        void Pairs(string title, string add, List<ConnectorDraft.Pair> list, bool secretValues)
        {
            form.Children.Add(Header(title));
            foreach (var pair in list.ToList())
            {
                var row = new Grid { ColumnSpacing = 8 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var key = Field("KEY", pair.Key, v => pair.Key = v, "Key");
                key.FontFamily = Kit.Res<Microsoft.UI.Xaml.Media.FontFamily>("CodeFont");
                row.Children.Add(key);
                var isSecret = secretValues && McpEntryMask.SECRET_KEY.IsMatch(pair.Key);
                FrameworkElement value;
                if (isSecret)
                {
                    var pw = new PasswordBox { PlaceholderText = "value", Password = pair.Value };
                    pw.PasswordChanged += (_, _) => { pair.Value = pw.Password; Update(); };
                    value = pw;
                }
                else value = Field("value", pair.Value, v => pair.Value = v, "Value");
                Grid.SetColumn(value, 1);
                row.Children.Add(value);
                var remove = new Button { Content = Kit.Glyph("", 12) };
                AutomationProperties.SetName(remove, "Remove");
                remove.Click += (_, _) => { list.Remove(pair); Rebuild(); };
                Grid.SetColumn(remove, 2);
                row.Children.Add(remove);
                key.LostFocus += (_, _) => { if (secretValues && McpEntryMask.SECRET_KEY.IsMatch(pair.Key) != isSecret) Rebuild(); };
                form.Children.Add(row);
            }
            form.Children.Add(Kit.Link("+ " + add, () => { list.Add(new ConnectorDraft.Pair()); Rebuild(); }));
        }

        void Rebuild()
        {
            form.Children.Clear();
            form.Children.Add(Field("Name", draft.Name, v => draft.Name = v, "Name"));
            form.Children.Add(nameNote);
            form.Children.Add(Header("Type"));
            var type = new RadioButtons { MaxColumns = 2 };
            type.Items.Add("Web Address");
            type.Items.Add("Command");
            type.SelectedIndex = draft.Kind == ConnectorDraft.Kinds.Web ? 0 : 1;
            type.SelectionChanged += (_, _) =>
            {
                var kind = type.SelectedIndex == 1 ? ConnectorDraft.Kinds.Command : ConnectorDraft.Kinds.Web;
                if (kind != draft.Kind) { draft.Kind = kind; Rebuild(); }
            };
            form.Children.Add(type);
            form.Children.Add(typeNote);
            if (draft.Kind == ConnectorDraft.Kinds.Web)
            {
                form.Children.Add(Header("Web Address"));
                form.Children.Add(Field("https://example.com/mcp", draft.Url, v => draft.Url = v, "Web Address"));
                var auth = new ComboBox { Header = "Sign-In", MinWidth = 200 };
                foreach (var a in Enum.GetValues<ConnectorDraft.Auths>()) auth.Items.Add(ConnectorDraft.AuthTitle(a));
                auth.SelectedIndex = (int)draft.Auth;
                auth.SelectionChanged += (_, _) => { var a = (ConnectorDraft.Auths)auth.SelectedIndex; if (a != draft.Auth) { draft.Auth = a; Rebuild(); } };
                form.Children.Add(auth);
                if (draft.Auth == ConnectorDraft.Auths.Bearer)
                {
                    var line = new Grid { ColumnSpacing = 8 };
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var token = new PasswordBox { PlaceholderText = "Token", Password = draft.Token };
                    AutomationProperties.SetName(token, "Token");
                    token.PasswordChanged += (_, _) => { draft.Token = token.Password; Update(); };
                    line.Children.Add(token);
                    var paste = Kit.Button("Paste", async () => { if (await Kit.Paste() is { } t) token.Password = t; });
                    Grid.SetColumn(paste, 1);
                    line.Children.Add(paste);
                    form.Children.Add(line);
                }
                Pairs("Headers", "Add Header", draft.Headers, true);
            }
            else
            {
                form.Children.Add(Header("Command"));
                form.Children.Add(Field("npx", draft.Command, v => draft.Command = v, "Command"));
                form.Children.Add(Header("Arguments"));
                foreach (var arg in draft.Args.ToList())
                {
                    var row = new Grid { ColumnSpacing = 8 };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.Children.Add(Field("Argument", arg.Value, v => arg.Value = v, "Argument"));
                    var remove = new Button { Content = Kit.Glyph("", 12) };
                    AutomationProperties.SetName(remove, "Remove");
                    remove.Click += (_, _) => { draft.Args.Remove(arg); Rebuild(); };
                    Grid.SetColumn(remove, 1);
                    row.Children.Add(remove);
                    form.Children.Add(row);
                }
                form.Children.Add(Kit.Link("+ Add Argument", () => { draft.Args.Add(new ConnectorDraft.Pair()); Rebuild(); }));
                Pairs("Environment Variables", "Add Environment Variable", draft.Env, true);
                form.Children.Add(Header("Working Directory"));
                form.Children.Add(Field("Optional", draft.Cwd, v => draft.Cwd = v, "Working Directory"));
            }
            Update();
        }

        void Update()
        {
            if (draft.TrimmedName.Length > 0 && !draft.NameValid) { nameNote.Text = "Names use 1-64 letters, digits, dots, dashes, or underscores."; nameNote.Foreground = Kit.Critical; }
            else if (draft.NameTaken(Existing())) { nameNote.Text = "That name is already used."; nameNote.Foreground = Kit.Critical; }
            else { nameNote.Text = $"Add a connector to {model.BotName}."; nameNote.Foreground = Kit.Secondary; }
            typeNote.Text = draft.Kind == ConnectorDraft.Kinds.Web ? "A service on the internet." : "A program on the computer running Hermes.";
            dialog.IsPrimaryButtonEnabled = draft.IsComplete(Existing()) && !adding;
            dialog.PrimaryButtonText = adding ? "Adding…" : "Add";
        }

        dialog.PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            if (adding || !draft.IsComplete(Existing()) || model.Api is not { } api) return;
            var deferral = e.GetDeferral();
            adding = true; Update();
            var name = draft.TrimmedName;
            try
            {
                await api.McpAddAsync(name, draft.Config, draft.Bearer, model.Profile);
                draft.Token = "";
                var reloaded = await api.ReloadMcpAsync();
                await model.ReloadServers();
                if (!reloaded) model.ServersNotice = "Saved. Its tools load in new chats.";
                added = name;
                e.Cancel = false;
            }
            catch (Exception x)
            {
                if (ConnectorDraft.Reason(x) is { } reason) { nameNote.Text = reason; nameNote.Foreground = Kit.Critical; }
                else refused.Add(name);
            }
            adding = false;
            if (added == null) Update();
            deferral.Complete();
        };
        // Cancel with something typed asks first ("Discard This Connector?"). One dialog shows at a time, so the
        // question is asked in place: the second Cancel discards.
        var armed = false;
        dialog.Closing += (_, e) =>
        {
            if (e.Result == ContentDialogResult.Primary || added != null || !draft.HasContent || armed) return;
            if (adding) { e.Cancel = true; return; }
            e.Cancel = true;
            armed = true;
            dialog.CloseButtonText = "Discard";
            nameNote.Text = "Discard This Connector?";
            nameNote.Foreground = Kit.Caution;
        };
        Rebuild();
        await Kit.Show(model.Root, dialog);
        return added;
    }

}
