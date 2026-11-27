"""Exercise both sides of the welcome's layout boundary with the local .NET SDK, not a desktop."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree as XML

WINDOWS = Path(__file__).resolve().parents[1]
UI = WINDOWS / 'src/HermesHQ.Windows'


class WelcomeScaleHostTest(unittest.TestCase):
    def test_frame_measure_arrange_and_render_transform_together(self):
        dotnet = shutil.which('dotnet') or str(Path.home() / '.dotnet' / ('dotnet.exe' if os.name == 'nt' else 'dotnet'))
        # Use the real outer transform without linking ThemeService's file preferences, system theme or window.
        service = (UI / 'Features/Settings/ThemeService.cs').read_text(encoding='utf-8')
        method = re.search(r'^    private static void ApplyScale\(\)\n    \{.*?^    \}', service, re.M | re.S)
        if method is None:
            self.fail('update the outer-frame replay when ThemeService changes')
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            (work / 'Frame.g.cs').write_text('using Microsoft.UI.Xaml; using Microsoft.UI.Xaml.Controls; '
                'using Microsoft.UI.Xaml.Media; namespace HermesHQ.Features.Settings; '
                'static partial class ThemeService {\n' + method[0] + '\n}', encoding='utf-8')
            project = XML.fromstring('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
                '<TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>'
                '</PropertyGroup></Project>')
            items = XML.SubElement(project, 'ItemGroup')
            XML.SubElement(items, 'ProjectReference', Include=str(WINDOWS / 'src/Hermes.Core/Hermes.Core.csproj'))
            for path in [UI / 'Features/Onboarding/WelcomeScaleHost.cs', WINDOWS / 'tests/welcome-scale/MeasureHost.cs']:
                XML.SubElement(items, 'Compile', Include=str(path))
            proj = work / 'MeasureHost.csproj'
            XML.ElementTree(project).write(proj, encoding='utf-8')
            env = os.environ | {'DOTNET_CLI_TELEMETRY_OPTOUT': '1', 'DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE': '1'}
            def run(*args):
                result = subprocess.run([dotnet, *args], cwd=WINDOWS, env=env, capture_output=True, text=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            run('restore', str(proj), '--source', str(work), '-p:NuGetAudit=false')  # both projects are package-free
            run('run', '--project', str(proj), '--no-restore', '--disable-build-servers', '--', str(UI))


if __name__ == '__main__':
    unittest.main()
