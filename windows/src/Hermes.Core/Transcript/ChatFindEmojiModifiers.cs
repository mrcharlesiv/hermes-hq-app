using System.Buffers;
using System.Globalization;
using System.Text;

namespace Hermes.Core.Transcripts;

// Swift folds these five modifiers when attached to a Character. Search by original text elements: removing a tone
// from a whole string first can join two regional indicators into a flag and lose the original match boundaries.
internal static class ChatFindEmojiModifiers
{
    private static readonly SearchValues<string> Tones = SearchValues.Create(["🏻", "🏼", "🏽", "🏾", "🏿"], StringComparison.Ordinal);
    internal static bool ContainsTone(ReadOnlySpan<char> text) => text.ContainsAny(Tones);

    private readonly record struct Glyph(ReadOnlyMemory<char> Key, bool HasTone, bool Literal);

    private static bool HasNoBase(ReadOnlySpan<char> glyph)
    {
        Rune.DecodeFromUtf16(glyph, out var first, out _);
        return first.Value is >= 0x1F3FB and <= 0x1F3FF || Rune.GetUnicodeCategory(first) is
            UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
    }

    private static Glyph GlyphAt(string value, int start, out int end)
    {
        int width = StringInfo.GetNextTextElementLength(value, start);
        end = start + width;
        var raw = value.AsMemory(start, width);
        int tone = raw.Span.IndexOfAny(Tones);
        bool literal = HasNoBase(raw.Span);
        if (tone < 0 || literal) return new(raw, tone >= 0, literal);
        if (tone + 2 == width) return new(raw[..tone], true, false);

        // A modifier can also sit inside a joined emoji. Keep every other scalar; the key is never used for offsets.
        var key = new StringBuilder(width);
        var rest = raw.Span;
        do
        {
            key.Append(rest[..tone]);
            rest = rest[(tone + 2)..];
            tone = rest.IndexOfAny(Tones);
        } while (tone >= 0);
        return new(key.Append(rest).ToString().AsMemory(), true, false);
    }

    internal static IReadOnlyList<ChatFindRange> Ranges(string query, string text, CompareInfo compare, CompareOptions options)
    {
        var pattern = new List<Glyph>();
        for (int i = 0, end; i < query.Length; i = end) pattern.Add(GlyphAt(query, i, out end));
        var literalNeedle = pattern.Where(g => g.HasTone && g.Literal).Select(g => g.Key).ToArray();
        List<ChatFindRange>? literals = null;
        int firstLiteral = 0;
        bool SameLiterals(int start, int length)
        {
            if (!ContainsTone(text.AsSpan(start, length))) return literalNeedle.Length == 0;
            // Compare *original* standalone clusters literally; a collation hit may also contain e.g. ﬃ ↔ ffi.
            // Determine these boundaries in the whole source, never by re-segmenting a cut-out substring.
            literals ??= LiteralTones(text);
            while (firstLiteral < literals.Count && literals[firstLiteral].Start + literals[firstLiteral].Length <= start) firstLiteral++;
            int n = 0;
            for (int i = firstLiteral; i < literals.Count && literals[i].Start < start + length; i++)
            {
                var r = literals[i];
                if (n == literalNeedle.Length || r.Start < start || r.Start + r.Length > start + length ||
                    !literalNeedle[n++].Span.SequenceEqual(text.AsSpan(r.Start, r.Length))) return false;
            }
            return n == literalNeedle.Length;
        }
        ChatFindRange? NextOrdinary(int from)
        {
            while (from < text.Length)
            {
                int offset = compare.IndexOf(text.AsSpan(from), query.AsSpan(), options, out int length);
                if (offset < 0 || length == 0) break;
                int at = from + offset;
                if (SameLiterals(at, length)) return new(at, length);
                from = at + StringInfo.GetNextTextElementLength(text, at);
            }
            return null;
        }

        // Merge by original start. Keep the pending collation hit instead of rescanning the remaining text for
        // each variant. Genuine old matches (including collation expansions) still use the ordinary comparer.
        using var variants = VariantMatches(pattern, text, compare, options).GetEnumerator();
        bool more = variants.MoveNext();
        var ordinary = NextOrdinary(0);
        var hits = new List<ChatFindRange>();
        while (more || ordinary.HasValue)
        {
            var hit = more && (ordinary == null || variants.Current.Start <= ordinary.Value.Start) ? variants.Current : ordinary!.Value;
            hits.Add(hit);
            int end = hit.Start + hit.Length;
            while (more && variants.Current.Start < end) more = variants.MoveNext();
            if (ordinary is { } old && old.Start < end) ordinary = NextOrdinary(end);
        }
        return hits;
    }

    private static List<ChatFindRange> LiteralTones(string text)
    {
        var found = new List<ChatFindRange>();
        for (int i = 0, width; i < text.Length; i += width)
        {
            width = StringInfo.GetNextTextElementLength(text, i);
            var glyph = text.AsSpan(i, width);
            if (ContainsTone(glyph) && HasNoBase(glyph)) found.Add(new(i, width));
        }
        return found;
    }

    private static IEnumerable<ChatFindRange> VariantMatches(List<Glyph> pattern, string text, CompareInfo compare, CompareOptions options)
    {
        bool Same(Glyph a, Glyph b) => a.Key.Span.SequenceEqual(b.Key.Span) ||
            (!a.Literal && !b.Literal && SameBase(a.Key.Span, b.Key.Span, compare, options));

        // Prefix lengths let an overlapping or repeated pattern be scanned in one pass. Remember just one pattern's
        // worth of original UTF-16 starts; neither the length of a search key nor that of the query is a highlight.
        var prefix = new int[pattern.Count];
        int Advance(int n, Glyph glyph)
        {
            while (!Same(pattern[n], glyph))
            {
                if (n == 0) return 0;
                n = prefix[n - 1];
            }
            return n + 1;
        }
        for (int i = 1, n = 0; i < prefix.Length; i++)
            prefix[i] = n = Advance(n, pattern[i]);
        var starts = new int[pattern.Count];
        bool queryHasTone = pattern.Any(g => g.HasTone);
        for (int i = 0, slot = 0, n = 0, lastTone = -1; i < text.Length;)
        {
            starts[slot] = i;
            slot = (slot + 1) % starts.Length;
            var glyph = GlyphAt(text, i, out int end);
            if (glyph.HasTone) lastTone = i;
            n = Advance(n, glyph);
            if (n == pattern.Count)
            {
                int start = starts[slot];
                if (queryHasTone || lastTone >= start) yield return new(start, end - start);
                n = prefix[n - 1];
            }
            i = end;
        }
    }

    // Preserve structural scalars inside a variant (a joiner or spacing mark is not a skin tone). For the ordinary
    // pieces keep the same case/accent comparison, including composed vs decomposed accents of different lengths.
    private static bool SameBase(ReadOnlySpan<char> a, ReadOnlySpan<char> b, CompareInfo compare, CompareOptions options)
    {
        static int Structural(ReadOnlySpan<char> s)
        {
            int i = 0;
            foreach (var rune in s.EnumerateRunes())
            {
                if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Format or UnicodeCategory.Control or
                    UnicodeCategory.SpacingCombiningMark) return i;
                i += rune.Utf16SequenceLength;
            }
            return i;
        }
        while (true)
        {
            int ai = Structural(a), bi = Structural(b);
            if (compare.Compare(a[..ai], b[..bi], options) != 0) return false;
            a = a[ai..]; b = b[bi..];
            if (a.IsEmpty || b.IsEmpty) return a.IsEmpty && b.IsEmpty;
            Rune.DecodeFromUtf16(a, out _, out int width);
            if (!b.StartsWith(a[..width], StringComparison.Ordinal)) return false;
            a = a[width..]; b = b[width..];
        }
    }
}
