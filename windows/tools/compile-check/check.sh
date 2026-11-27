#!/bin/zsh
# Type-check the WinUI app's C# without Windows. Usage: windows/tools/compile-check/check.sh
set -e
cd "$(dirname "$0")"
mkdir -p obj
python3 gen-stubs.py ../../src/HermesHQ.Windows obj/XamlStubs.g.cs
DOTNET=${DOTNET:-$(command -v dotnet || echo $HOME/.dotnet/dotnet)}
DOTNET_CLI_TELEMETRY_OPTOUT=1 $DOTNET build -p:Platform=x64 -v q -nologo "$@"
