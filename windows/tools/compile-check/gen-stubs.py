#!/usr/bin/env python3
"""Stand-ins for what the XAML compiler generates (x:Name fields, InitializeComponent), so the app's C# can be
type-checked against the real WinUI reference assemblies on a Mac. The XAML itself is only checked for being
well-formed XML here; the real build on Windows compiles it."""
import pathlib, re, sys, xml.etree.ElementTree as ET
src = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
OTHER = {n: 'Microsoft.UI.Xaml.Controls.Primitives' for n in ('ToggleButton', 'RepeatButton', 'Popup', 'ScrollBar', 'Thumb')}
OTHER.update({n: 'Microsoft.UI.Xaml.Shapes' for n in ('Ellipse', 'Rectangle', 'Path', 'Line', 'Polygon', 'Polyline')})
OTHER.update({n: 'Microsoft.UI.Xaml.Documents' for n in ('Run', 'Paragraph', 'Hyperlink', 'Span', 'Bold', 'Italic')})
OTHER.update({n: 'Microsoft.UI.Xaml.Input' for n in ('KeyboardAccelerator',)})
OTHER.update({n: 'Microsoft.UI.Xaml.Media' for n in ('SolidColorBrush', 'ScaleTransform', 'TranslateTransform')})
OTHER.update({n: 'Microsoft.UI.Xaml' for n in ('ColumnDefinition', 'RowDefinition')})
OTHER.update({n: 'Microsoft.UI.Xaml.Controls' for n in ('ColumnDefinition', 'RowDefinition')})
X = '{http://schemas.microsoft.com/winfx/2006/xaml}'
lines = ['#nullable disable', '#pragma warning disable CS0169, CS0649, CS0414']
for xaml in sorted(src.rglob('*.xaml')):
    root = ET.parse(xaml).getroot()  # raises on malformed XAML
    cls = root.get(X + 'Class')
    if not cls: continue
    ns, name = cls.rsplit('.', 1)
    prefixes = {}
    for line in xaml.read_text().splitlines():
        for part in line.split():
            if part.startswith('xmlns:') and '"using:' in part:
                p, v = part[6:].split('=', 1); prefixes[p] = v.strip('">').split('using:')[1].rstrip('"')
    def type_of(el):
        uri, local = el.tag[1:].split('}')
        if uri.startswith('using:'): return uri[6:] + '.' + local
        return OTHER.get(local, 'Microsoft.UI.Xaml.Controls') + '.' + local
    fields = []
    for el in root.iter():
        n = el.get(X + 'Name')
        if n and el is not root: fields.append(f'        private {type_of(el)} {n};')
    # Event handlers: an attribute whose value names a method in the code-behind is wired as C# would wire it, so
    # a missing handler or a wrong signature fails here as it would in the real build.
    code = xaml.with_suffix('.xaml.cs').read_text() if xaml.with_suffix('.xaml.cs').exists() else ''
    methods = set(re.findall(r'\bvoid\s+([A-Za-z_]\w*)\s*\(', code))
    checks = []
    parents = {c: p for p in root.iter() for c in p}
    def data_type(el):
        while el is not None:
            dt = el.get(X + 'DataType')
            if dt and ':' in dt:
                pre, t = dt.split(':', 1)
                if pre in prefixes: return prefixes[pre] + '.' + t
            el = parents.get(el)
        return None
    for el in root.iter():
        local = el.tag.split('}')[-1]
        if '.' in local: continue  # property elements
        target = 'this' if el is root else f'default({type_of(el)})!'
        for attr, value in el.attrib.items():
            if attr.startswith('{') or '.' in attr: continue
            if value in methods:
                checks.append(f'            {target}.{attr} += {value};')
            m = re.fullmatch(r'\{x:Bind\s+([A-Za-z_][\w.]*)(?:\s*,.*)?\}', value.strip())
            if m:
                path = m.group(1)
                dt = data_type(parents.get(el))
                owner = f'default({dt})!' if dt else 'this'
                checks.append(f'            _ = {owner}.{path};')
    lines += [f'namespace {ns} {{', f'    partial class {name} {{', *fields,
              '        private void InitializeComponent() { }',
              '        private void __XamlChecks() {', *checks, '        }', '    }', '}']
out.write_text('\n'.join(lines) + '\n')
print(f'{out}: stubs for {sum(1 for _ in src.rglob("*.xaml"))} XAML files')
