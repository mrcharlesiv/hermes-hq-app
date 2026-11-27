"""Compile the production drawing methods, not a second implementation of the row rules.

Only the rest of MessageView (menus, commands, etc.) and the platform edges are replaced.
ChatBubbleLane itself is linked whole. Tests inspect the resulting control tree, not source text.
"""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
view = (root / 'Controls/MessageView.cs').read_text(encoding='utf-8')
palette = (root / 'Features/Settings/ThemeService.cs').read_text(encoding='utf-8')
model = (root / 'ViewModels/ChatViewModel.cs').read_text(encoding='utf-8')


def section(source, start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]


members = (section(view, '    public const string UserBubbleName', '    // MARK: A reply')
           + section(view, '    public const string SenderNameId', '    /// The latest reply\'s action row')
           + section(view, '    /// Bubbles:', '    /// The error card (spec'))
selectors = section(palette, '    private static readonly (string Key, Func<ThemeTokens', '    private static readonly Dictionary')
projection = section(model, '    private List<MessageDisplay> Displays(', '\n}')
output.write_text('#nullable enable\nusing Hermes.Core.Attachments;\nusing Hermes.Core.Chat;\nusing Hermes.Core.Model;\n'
                  'using Hermes.Core.Settings;\nusing Hermes.Core.Transcripts;\n'
                  'using HermesHQ.Features.Settings;\nusing HermesHQ.ViewModels;\nusing Microsoft.UI.Xaml;\n'
                  'using Microsoft.UI.Xaml.Controls;\nusing Microsoft.UI.Xaml.Media;\nusing Microsoft.UI.Text;\n'
                  'namespace HermesHQ.Controls { partial class MessageView {\n' + members + '\n} }\n'
                  'namespace HermesHQ.ViewModels { partial class ChatViewModel {\n' + projection + '\n} }\n'
                  'namespace HermesHQ.Features.Settings { static partial class ThemeService {\n'
                  + selectors + '\n} }\n', encoding='utf-8')
