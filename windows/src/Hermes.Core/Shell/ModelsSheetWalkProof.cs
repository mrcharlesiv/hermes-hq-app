namespace Hermes.Core.Shell;

/// [WIN-45] The check behind the Models sheet walk (Services/ProofWalks.ModelsSheet.cs): every model row the sheet
/// draws shows its name in a drawn brush. Null when so; otherwise what is wrong.
public static class ModelsSheetWalkProof
{
    /// `expected` is the names the rows should read (Composer.ModelSheetModel.Row's Title, in order); `shown` is each
    /// row's name text as drawn and whether it has a visible brush (a non-transparent Foreground).
    public static string? RowsRead(IReadOnlyList<string> expected, IReadOnlyList<(string Text, bool Inked)> shown)
    {
        if (expected.Count == 0) return "the sheet has no model rows to read";
        var blank = shown.Count(r => string.IsNullOrWhiteSpace(r.Text));
        if (blank > 0) return $"{blank} of {shown.Count} model rows are blank";
        var unInked = shown.Where(r => !r.Inked).Select(r => r.Text).ToList();
        if (unInked.Count > 0) return $"rows with no brush (their words don't draw): {string.Join(", ", unInked)}";
        var texts = shown.Select(r => r.Text).ToList();
        if (!texts.SequenceEqual(expected))
            return $"the rows read {(texts.Count == 0 ? "nothing" : string.Join(", ", texts))}, not {string.Join(", ", expected)}";
        return null;
    }

    /// The row the sheet marks current (its accessible name ends “, Current”) is the model the composer's pill reads.
    public static string? CurrentMatchesPill(string? pill, IReadOnlyList<string> rowNames)
    {
        var current = rowNames.Where(n => n.EndsWith(CurrentSuffix, StringComparison.Ordinal)).ToList();
        if (current.Count != 1) return $"{current.Count} rows are marked current";
        var name = current[0][..^CurrentSuffix.Length];
        return name == pill ? null : $"the current row is {name}, the composer's pill reads {pill ?? "nothing"}";
    }

    /// A row's name as its words show it: its accessible name without the current mark.
    public static string Shown(string rowName) =>
        rowName.EndsWith(CurrentSuffix, StringComparison.Ordinal) ? rowName[..^CurrentSuffix.Length] : rowName;

    private const string CurrentSuffix = ", Current";
}
