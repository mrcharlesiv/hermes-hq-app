"""Run the direct page's fit and installed key/model routes on inert receivers, not a desktop."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree as ET

WINDOWS = Path(__file__).resolve().parents[1]
UI = WINDOWS / 'src/HermesHQ.Windows'
FIXTURE = WINDOWS / 'tests/direct-composer'
PAGE = UI / 'Pages/ChatPage.xaml.cs'
CONTROLLER = UI / 'Features/Composer/ComposerController.cs'
XN = '{http://schemas.microsoft.com/winfx/2006/xaml}Name'


def method(text, signature):
    # read_text normalizes physical CRLF. Use the real body or fail closed when its shape changes.
    match = re.search(r'^    ' + re.escape(signature) + r'(?: =>\s*[^\n]+;|\n    \{.*?^    \})$', text, re.M | re.S)
    if not match:
        raise AssertionError(f'No production method: {signature}')
    return match[0]


def line(text, needle):
    hits = [s.strip() for s in text.splitlines() if needle in s]
    if len(hits) != 1:
        raise AssertionError(f'Expected one binding for {needle}: {len(hits)}')
    return hits[0]


def textbox_defaults():
    """Bind the replay to the app's installed WinUI template, not a guessed inner width."""
    packages = Path(os.environ.get('NUGET_PACKAGES') or Path.home() / '.nuget/packages')
    app = ET.parse(UI / 'HermesHQ.Windows.csproj')
    sdk, = (e.attrib['Version'] for e in app.iter('PackageReference') if e.get('Include') == 'Microsoft.WindowsAppSDK')
    nuspec, = (packages / 'microsoft.windowsappsdk' / sdk).glob('*.nuspec')
    version, = {e.attrib['version'] for e in ET.parse(nuspec).findall('.//{*}dependency')
                if e.get('id') == 'Microsoft.WindowsAppSDK.WinUI'}
    root = ET.parse(packages / 'microsoft.windowsappsdk.winui' / version.strip('[]') / 'lib/native/Microsoft.UI/Themes/generic.xaml')
    key = XN.replace('}Name', '}Key')
    style, = [e for e in root.iter() if e.get(key) == 'DefaultTextBoxStyle']
    placeholder, = [e for e in style.iter() if e.get(XN) == 'PlaceholderTextContentPresenter']
    assert placeholder.tag.endswith('}TextBlock') and all(placeholder.get(k) == v for k, v in {
        'Grid.Column': '0', 'Grid.ColumnSpan': '2', 'Margin': '{TemplateBinding BorderThickness}',
        'Padding': '{TemplateBinding Padding}', 'Text': '{TemplateBinding PlaceholderText}',
        'TextWrapping': '{TemplateBinding TextWrapping}'}.items())
    def value(prop):
        setter, = [s for s in style if s.get('Property') == prop]
        ref = re.fullmatch(r'\{ThemeResource (\w+)\}', setter.attrib['Value'])
        assert ref, prop
        result, = {e.text for e in root.iter() if e.get(key) == ref[1]}
        assert result, prop
        return result
    return value('FontSize'), value('Padding')


class DirectComposerTests(unittest.TestCase):
    def setUp(self):
        self.controller = CONTROLLER.read_text(encoding='utf-8')
        self.page = PAGE.read_text(encoding='utf-8')
        self.nodes = {e.get(XN): e for e in ET.parse(UI / 'Pages/ChatPage.xaml').iter() if e.get(XN)}

    def run_host(self, files, generated, arguments=()):
        dotnet = shutil.which('dotnet') or str(Path.home() / '.dotnet' / ('dotnet.exe' if os.name == 'nt' else 'dotnet'))
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            project = ET.fromstring('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
                '<TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>'
                '<TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup></Project>')
            items = ET.SubElement(project, 'ItemGroup')
            for path in files:
                ET.SubElement(items, 'Compile', Include=str(path))
            (work / 'Production.g.cs').write_text('#nullable enable\n' + generated, encoding='utf-8')
            proj = work / 'Replay.csproj'
            ET.ElementTree(project).write(proj, encoding='utf-8')
            env = os.environ | {'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': '1'}
            for args in [('restore', str(proj), '--source', tmp, '-p:NuGetAudit=false'),
                         ('run', '--project', str(proj), '--no-restore', '--disable-build-servers', '--', *arguments)]:
                run = subprocess.run([dotnet, *args], cwd=WINDOWS, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            return run.stdout.strip()

    def test_actual_model_menu_binding_reaches_the_picker_receiver(self):
        more, chip = self.nodes['MoreButton'], self.nodes['ComposerModel']
        self.assertEqual(more.get('AutomationProperties.Name'), 'Chat Actions')
        self.assertEqual([e.get(XN) for e in more.findall('.//{*}MenuFlyout')], ['MoreMenu'])
        self.assertEqual(chip.get('Click'), 'ComposerModel_Click')
        self.assertIn('MoreMenu = MoreMenu', self.page)
        self.assertIn('ChatExtensions.OnOpen.Add(ctx => _ = new ComposerController(ctx))',
                      (UI / 'Features/Composer/ComposerFeature.cs').read_text(encoding='utf-8'))
        methods = [method(self.controller, s) for s in ('private void AddMenuItems()', 'private void UpdateMenuItems()',
                                                        'private void ShowModels(string? query)')]
        generated = '\n'.join(['partial class Route {', *methods,
            method(self.page, 'private void ComposerModel_Click(object sender, RoutedEventArgs e)'),
            'public void Install() { var ctx = _ctx;', line(self.controller, 'ctx.OpenModelPicker ='),
            line(self.controller, 'AddMenuItems();'), line(self.page, 'MoreButton.Visibility = MoreMenu.Items.Count'), '}}'])
        receipt = self.run_host([FIXTURE / 'MenuReceiver.cs'], generated)
        self.assertIn('both routes: same picker, current chat, null query; no model selected', receipt)

    def test_installed_direct_row_and_retained_editor(self):
        edit, lane = self.nodes['Composer'], self.nodes['ComposerMetrics']
        self.assertEqual(edit.get('PreviewKeyDown'), 'Composer_PreviewKeyDown')
        self.assertEqual(edit.get('TextChanged'), 'Composer_TextChanged')
        self.assertEqual((lane.get('Opacity'), lane.get('IsHitTestVisible'), lane.get('AutomationProperties.AccessibilityView')),
                         ('0', 'False', 'Raw'))
        # Use the real accessory glyph sizes plus the real XAML styles and tracks (read by the receiver).
        plus = (UI / 'Features/Attachments/ChatAttachments.cs').read_text(encoding='utf-8')
        self.assertIn('ctx.ComposerLeading.Children.Add(_plus)', plus)
        self.assertIn('ctx.ComposerLeading.Children.Insert(0, _commands)', self.controller)
        command = re.search(r'_commands = Ui.Quiet\(Ui.Glyph\("[^"]+", (\d+)\)', self.controller)
        attach = re.search(r'_plus = new Button\s*\{\s*Style = .*?"QuietButtonStyle".*?FontSize = (\d+)', plus, re.S)
        assert command and attach, 'cannot measure both installed leading buttons'
        generated = '\n'.join(['global using Features = HermesHQ.Features;', 'partial class Row {',
            'void Install() { var opening = _ctx; var ctx = opening;', line(self.page, '_composerFit = new('),
            line(self.page, 'opening.SetModelChip ='), line(self.controller, 'ctx.ComposerKeys.Add(OnKey)'), '}',
            'record Args(string Title); public void Title(string title) { var args = new Args(title);',
            line(self.page, '_composerFit.SetTitle('), '}',
            'public void Model(string? name, bool options = false) { _c.Options = options ? new() : null;',
            'var current = (Id: name == null ? "" : "fixture", Name: name ?? "");', line(self.controller, '_ctx.SetModelChip('), '}',
            method(self.controller, 'private static bool Down(VirtualKey key)'),
            method(self.controller, 'private bool OnKey(KeyRoutedEventArgs e)'),
            method(self.page, 'private void Composer_PreviewKeyDown(object sender, KeyRoutedEventArgs e)'), '}'])
        receipt = self.run_host([UI / 'Features/Composer/DirectComposerFit.cs', FIXTURE / 'LayoutReceiver.cs', FIXTURE / 'CheckLayout.cs'],
                                generated, [str(UI), command[1], attach[1], *textbox_defaults()])
        self.assertIn('exact fits, scaled text, stable rows and retained input: PASS', receipt)
        print(receipt)


if __name__ == '__main__':
    unittest.main()
