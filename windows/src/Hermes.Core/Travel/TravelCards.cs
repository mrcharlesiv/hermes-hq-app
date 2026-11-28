using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Shopping;

namespace Hermes.Core.Travel;

/// One flight segment inside a multi-leg itinerary (HermesKit/Travel/TravelCards.swift `Segment`).
public sealed record FlightLeg(
    string Airline,
    string FlightNumber,
    string Origin,
    string Destination,
    string DepartTime,
    string ArriveTime,
    string Duration,
    string Layover);

/// One flight option from `show_flights` (HermesKit/Travel/TravelCards.swift `Flight`).
public sealed record FlightOption(
    string Id,
    string Airline,
    string FlightNumber,
    string Origin,
    string Destination,
    string DepartTime,
    string ArriveTime,
    string Duration,
    int Stops,
    string StopSummary,
    string Cabin,
    string FareTier,
    double Price,
    double? Was,
    string Currency,
    Uri Url,
    string Badge,
    string CarryOn,
    string CheckedBag,
    string ChangeRule,
    string RefundRule,
    IReadOnlyList<FlightLeg> Segments,
    IReadOnlyList<string> Why,
    IReadOnlyList<string> Caution)
{
    public string RouteLabel => $"{Origin} → {Destination}";

    public string StopsLabel => !string.IsNullOrEmpty(StopSummary)
        ? StopSummary
        : Stops switch
        {
            0 => "Nonstop",
            1 => "1 stop",
            _ => $"{Stops} stops",
        };
}

/// Parsed payload of `show_flights` (HermesKit/Travel/TravelCards.swift `Flights`).
public sealed record FlightList(
    string Note,
    string Step,
    IReadOnlyList<string> RelaxedFilters,
    IReadOnlyList<FlightOption> Flights,
    IReadOnlyList<string> FollowUps);

/// One hotel option from `show_hotels` (HermesKit/Travel/TravelCards.swift `Hotel`).
public sealed record HotelOption(
    string Id,
    string Name,
    string Neighborhood,
    string Address,
    double? Latitude,
    double? Longitude,
    int? Stars,
    double? Rating,
    int? Reviews,
    double? PricePerNight,
    double? TotalPrice,
    string Currency,
    double? Was,
    Uri Url,
    IReadOnlyList<Uri> Images,
    string Badge,
    string Cancellation,
    string Breakfast,
    string Distance,
    IReadOnlyList<string> Amenities,
    IReadOnlyList<string> Why,
    IReadOnlyList<string> Caution)
{
    public Uri? Image => Images.Count > 0 ? Images[0] : null;
    public bool HasCoordinates => Latitude.HasValue && Longitude.HasValue;
}

/// Parsed payload of `show_hotels` (HermesKit/Travel/TravelCards.swift `Hotels`).
public sealed record HotelList(
    string Note,
    string Step,
    string Location,
    string CheckIn,
    string CheckOut,
    string Guests,
    IReadOnlyList<HotelOption> Hotels,
    IReadOnlyList<string> FollowUps);

public enum TravelAsk
{
    Book,
    WatchPrice,
}

/// Travel asks already sent in this chat, indexed by flight or hotel id (HermesKit/Travel/TravelCards.swift `Answers`).
public sealed record TravelAnswers(IReadOnlyDictionary<string, IReadOnlySet<TravelAsk>> Asked)
{
    public static TravelAnswers Empty { get; } = new(new Dictionary<string, IReadOnlySet<TravelAsk>>());

    public IReadOnlySet<TravelAsk> For(string id) =>
        Asked.TryGetValue(id, out var set) ? set : EmptySet;

    private static readonly IReadOnlySet<TravelAsk> EmptySet = new HashSet<TravelAsk>();
}

/// Port of HermesKit/Travel/TravelCards.swift: flight (`show_flights`) and hotel (`show_hotels`) cards,
/// 256 KB whole-args preservation, add-on capability handshake metadata, deterministic ids, and transcript markers.
public static class TravelCards
{
    public const string FlightsTool = "show_flights";
    public const string HotelsTool = "show_hotels";
    public const string CardsPath = "/travel/cards";
    public const string Lead = "[Hermes HQ travel ";
    public const int MaxArgsBytes = 256_000;

    public const int MaxFlights = 12;
    public const int MaxHotels = 12;
    public const int MaxImages = 12;
    public const int MaxSegments = 6;
    public const int MaxAmenities = 10;
    public const int MaxWhy = 3;
    public const int MaxCaution = 2;
    public const int MaxFollowUps = 3;
    public const int MaxRelaxed = 4;

    private static readonly char[] Newlines = ['\r', '\n', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];
    private static readonly Regex MarkRegex = new(
        @"^\s*\[Hermes HQ travel ([fh]-[0-9a-f]{8}): (book|watch price)\]",
        RegexOptions.CultureInvariant);

    // MARK: Shared Contracts

    public static bool IsTravelTool(string? name) => name is FlightsTool or HotelsTool;

    public static string? RewriteMarkerBubble(string? text) =>
        string.IsNullOrEmpty(text) ? null : BubbleWords(text);

    // MARK: Add-on handshake

    public static bool CardsUntold(JsonObject? status) =>
        status?.Bool("travelCards") == true && status?.Bool("travelCardsShown") != true;

    public static string? WholeArgsText(string name, JsonObject? args)
    {
        if (!IsTravelTool(name) || args == null || args.Count == 0) return null;
        var text = args.ToJsonString();
        return Encoding.UTF8.GetByteCount(text) <= MaxArgsBytes ? text : null;
    }

    // MARK: Parsing

    private static JsonObject? ReadArgs(ToolCall call, string expectedTool)
    {
        if (call.Name != expectedTool || call.State == ToolState.Failed) return null;
        if (!string.IsNullOrWhiteSpace(call.ArgsJson) && J.Parse(call.ArgsJson) is JsonObject jsonObj)
            return jsonObj;
        if (!string.IsNullOrWhiteSpace(call.ArgsText) && J.Parse(call.ArgsText) is JsonObject textObj)
            return textObj;
        return null;
    }

    public static FlightList? ParseFlights(ToolCall call) =>
        ReadArgs(call, FlightsTool) is { } args ? ParseFlights(args) : null;

    public static FlightList? ParseFlights(JsonObject args)
    {
        var list = new List<FlightOption>();
        if (args.Arr("flights") is { } arr)
        {
            foreach (var item in arr)
            {
                if (item is JsonObject obj && ParseFlight(obj) is { } flight)
                {
                    list.Add(flight);
                    if (list.Count >= MaxFlights) break;
                }
            }
        }
        if (list.Count == 0) return null;

        var relaxed = ReadStrings(args.Get("relaxed_filters") ?? args.Get("relaxedFilters"), MaxRelaxed, 60);
        var followUps = ReadStrings(args.Get("follow_ups") ?? args.Get("followUps"), MaxFollowUps, 60);
        return new FlightList(
            Note: OneLine(args.Get("note"), 200),
            Step: OneLine(args.Get("step") ?? args.Get("status"), 60),
            RelaxedFilters: relaxed,
            Flights: list,
            FollowUps: followUps);
    }

    public static FlightOption? ParseFlight(JsonObject o)
    {
        var airline = Trimmed(o.Get("airline"));
        var origin = Trimmed(o.Get("origin") ?? o.Get("from")).ToUpperInvariant();
        var dest = Trimmed(o.Get("destination") ?? o.Get("to")).ToUpperInvariant();
        var link = Trimmed(o.Get("url"));
        if (airline.Length == 0 || origin.Length == 0 || dest.Length == 0
            || Fare(o.Get("price")) is not { } price
            || ParseHttps(link) is not { } url)
            return null;

        var flightNum = OneLine(o.Get("flight_number") ?? o.Get("flightNumber"), 24);
        var depart = OneLine(o.Get("depart_time") ?? o.Get("departTime") ?? o.Get("depart"), 40);
        var arrive = OneLine(o.Get("arrive_time") ?? o.Get("arriveTime") ?? o.Get("arrive"), 40);
        var stops = Whole(Amount(o.Get("stops")), 0, 9) ?? 0;

        var segments = new List<FlightLeg>();
        if (o.Arr("segments") is { } segArr)
        {
            foreach (var item in segArr)
            {
                if (item is not JsonObject s) continue;
                var segOrigin = Trimmed(s.Get("origin") ?? s.Get("from")).ToUpperInvariant();
                var segDest = Trimmed(s.Get("destination") ?? s.Get("to")).ToUpperInvariant();
                if (segOrigin.Length == 0 || segDest.Length == 0) continue;
                segments.Add(new FlightLeg(
                    Airline: OneLine(s.Get("airline"), 60),
                    FlightNumber: OneLine(s.Get("flight_number") ?? s.Get("flightNumber"), 24),
                    Origin: Cut(segOrigin, 8),
                    Destination: Cut(segDest, 8),
                    DepartTime: OneLine(s.Get("depart_time") ?? s.Get("departTime") ?? s.Get("depart"), 40),
                    ArriveTime: OneLine(s.Get("arrive_time") ?? s.Get("arriveTime") ?? s.Get("arrive"), 40),
                    Duration: OneLine(s.Get("duration"), 30),
                    Layover: OneLine(s.Get("layover"), 60)));
                if (segments.Count >= MaxSegments) break;
            }
        }

        return new FlightOption(
            Id: FlightId(airline, origin, dest, depart, link),
            Airline: Cut(airline, 60),
            FlightNumber: flightNum,
            Origin: Cut(origin, 8),
            Destination: Cut(dest, 8),
            DepartTime: depart,
            ArriveTime: arrive,
            Duration: OneLine(o.Get("duration"), 30),
            Stops: stops,
            StopSummary: OneLine(o.Get("stop_summary") ?? o.Get("stopSummary"), 60),
            Cabin: OneLine(o.Get("cabin"), 40),
            FareTier: OneLine(o.Get("fare_tier") ?? o.Get("fareTier"), 40),
            Price: price,
            Was: Above(Amount(o.Get("was")), price),
            Currency: Currency(o.Get("currency")),
            Url: url,
            Badge: OneLine(o.Get("badge"), 28),
            CarryOn: OneLine(o.Get("carry_on") ?? o.Get("carryOn"), 80),
            CheckedBag: OneLine(o.Get("checked_bag") ?? o.Get("checkedBag"), 80),
            ChangeRule: OneLine(o.Get("change_rule") ?? o.Get("changeRule"), 120),
            RefundRule: OneLine(o.Get("refund_rule") ?? o.Get("refundRule"), 120),
            Segments: segments,
            Why: ReadStrings(o.Get("why"), MaxWhy, 120),
            Caution: ReadStrings(o.Get("caution"), MaxCaution, 120));
    }

    public static HotelList? ParseHotels(ToolCall call) =>
        ReadArgs(call, HotelsTool) is { } args ? ParseHotels(args) : null;

    public static HotelList? ParseHotels(JsonObject args)
    {
        var list = new List<HotelOption>();
        if (args.Arr("hotels") is { } arr)
        {
            foreach (var item in arr)
            {
                if (item is JsonObject obj && ParseHotel(obj) is { } hotel)
                {
                    list.Add(hotel);
                    if (list.Count >= MaxHotels) break;
                }
            }
        }
        if (list.Count == 0) return null;

        var followUps = ReadStrings(args.Get("follow_ups") ?? args.Get("followUps"), MaxFollowUps, 60);
        return new HotelList(
            Note: OneLine(args.Get("note"), 200),
            Step: OneLine(args.Get("step") ?? args.Get("status"), 60),
            Location: OneLine(args.Get("location"), 80),
            CheckIn: OneLine(args.Get("check_in") ?? args.Get("checkIn"), 40),
            CheckOut: OneLine(args.Get("check_out") ?? args.Get("checkOut"), 40),
            Guests: OneLine(args.Get("guests"), 40),
            Hotels: list,
            FollowUps: followUps);
    }

    public static HotelOption? ParseHotel(JsonObject o)
    {
        var name = Trimmed(o.Get("name") ?? o.Get("title"));
        var link = Trimmed(o.Get("url"));
        if (name.Length == 0 || ParseHttps(link) is not { } url) return null;

        var images = new List<Uri>();
        var seen = new HashSet<Uri>();
        void AddImage(JsonNode? node)
        {
            if (images.Count >= MaxImages) return;
            if (ParseHttps(Trimmed(node)) is { } img && seen.Add(img))
                images.Add(img);
        }
        AddImage(o.Get("image"));
        if (o.Arr("images") is { } imgArr)
            foreach (var v in imgArr) AddImage(v);

        var lat = Coordinate(o.Get("latitude") ?? o.Get("lat"), 90);
        var lng = Coordinate(o.Get("longitude") ?? o.Get("lng") ?? o.Get("lon"), 180);
        var hasCoords = lat.HasValue && lng.HasValue;
        var stars = Whole(Amount(o.Get("stars")), 1, 5);
        double? rating = Amount(o.Get("rating")) is { } rawRating
            ? Math.Clamp(rawRating > 5 ? rawRating / 2.0 : rawRating, 0, 5)
            : null;
        int? reviews = Amount(o.Get("reviews")) is { } rawReviews && rawReviews >= 0 && rawReviews < 1e9
            ? (int)rawReviews
            : null;
        var nightly = Fare(o.Get("price_per_night") ?? o.Get("pricePerNight") ?? o.Get("price"));
        var total = Fare(o.Get("total_price") ?? o.Get("totalPrice") ?? o.Get("total"));
        var rawAddress = Trimmed(o.Get("address"));

        return new HotelOption(
            Id: HotelId(name, rawAddress, link),
            Name: Cut(name, 140),
            Neighborhood: OneLine(o.Get("neighborhood") ?? o.Get("area"), 80),
            Address: OneLine(o.Get("address"), 200),
            Latitude: hasCoords ? lat : null,
            Longitude: hasCoords ? lng : null,
            Stars: stars,
            Rating: rating,
            Reviews: reviews,
            PricePerNight: nightly,
            TotalPrice: total,
            Currency: Currency(o.Get("currency")),
            Was: Above(Amount(o.Get("was")), nightly),
            Url: url,
            Images: images,
            Badge: OneLine(o.Get("badge"), 28),
            Cancellation: OneLine(o.Get("cancellation"), 100),
            Breakfast: OneLine(o.Get("breakfast"), 60),
            Distance: OneLine(o.Get("distance"), 60),
            Amenities: ReadStrings(o.Get("amenities"), MaxAmenities, 40),
            Why: ReadStrings(o.Get("why"), MaxWhy, 120),
            Caution: ReadStrings(o.Get("caution"), MaxCaution, 120));
    }

    // MARK: Words & Layout Helpers (App/Travel/TravelCardsView.swift)

    public static string RelaxedFiltersText(FlightList list) =>
        $"Relaxed filters: {string.Join(", ", list.RelaxedFilters)}";

    /// "Manhattan, NY · Dec 12 – Dec 15 · 2 guests".
    public static string HotelMetaWords(HotelList model)
    {
        var dates = string.Join(" – ", new[] { model.CheckIn, model.CheckOut }.Where(s => s.Length > 0));
        return string.Join(" · ", new[] { model.Location, dates, model.Guests }.Where(s => s.Length > 0));
    }

    /// Secondary line on a hotel tile: rating + neighborhood, else address, distance, or star class.
    public static string HotelSubtitle(HotelOption hotel)
    {
        var primaryParts = new List<string>(2);
        if (hotel.Rating is { } r)
            primaryParts.Add(string.Create(CultureInfo.InvariantCulture, $"★ {r:F1}"));
        if (hotel.Neighborhood.Length > 0)
            primaryParts.Add(hotel.Neighborhood);
        if (primaryParts.Count > 0) return string.Join(" · ", primaryParts);
        if (hotel.Address.Length > 0) return hotel.Address;
        if (hotel.Distance.Length > 0) return hotel.Distance;
        if (hotel.Stars is { } stars) return $"{stars}-star";
        return "";
    }

    public static bool IsSafeWebUri(Uri? uri) =>
        uri != null && uri.IsAbsoluteUri
        && (uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)
            || uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase))
        && !string.IsNullOrEmpty(uri.Host);

    // MARK: Actions & Transcript Answers

    public static string RawValue(TravelAsk ask) => ask == TravelAsk.Book ? "book" : "watch price";

    public static string FormatMessage(TravelAsk ask, FlightOption flight)
    {
        var header = $"[Hermes HQ travel {flight.Id}: {RawValue(ask)}]";
        var price = ShoppingCards.FormatPrice(flight.Price, flight.Currency, ShoppingCards.MessageCulture);
        var desc = $"{flight.Airline} {flight.RouteLabel} ({flight.DepartTime}–{flight.ArriveTime}) for {price}";
        return ask switch
        {
            TravelAsk.Book =>
                $"{header}\nBook this flight for me: {desc}.\n{flight.Url.AbsoluteUri}\nVerify the current fare, bag rules, and seat availability, then stop before final payment and confirm the total with me.",
            TravelAsk.WatchPrice =>
                $"{header}\nWatch the fare on this flight and tell me if it drops below {price}: {desc}.\n{flight.Url.AbsoluteUri}",
            _ => header,
        };
    }

    public static string FormatMessage(TravelAsk ask, HotelOption hotel)
    {
        var header = $"[Hermes HQ travel {hotel.Id}: {RawValue(ask)}]";
        var rate = hotel.PricePerNight is { } nightly
            ? $" at {ShoppingCards.FormatPrice(nightly, hotel.Currency, ShoppingCards.MessageCulture)}/night"
            : "";
        return ask switch
        {
            TravelAsk.Book =>
                $"{header}\nBook this hotel for me: {hotel.Name}{rate}.\n{hotel.Url.AbsoluteUri}\nVerify room availability, taxes, and cancellation terms, then stop before final payment and confirm the total with me.",
            TravelAsk.WatchPrice =>
                $"{header}\nWatch the nightly rate for this hotel and tell me if it drops: {hotel.Name}{rate}.\n{hotel.Url.AbsoluteUri}",
            _ => header,
        };
    }

    public static (string Id, TravelAsk Ask)? ParseAnswer(string text)
    {
        if (string.IsNullOrEmpty(text) || !text.TrimStart().StartsWith(Lead, StringComparison.Ordinal))
            return null;
        var m = MarkRegex.Match(text);
        if (!m.Success) return null;
        var ask = m.Groups[2].Value switch
        {
            "book" => TravelAsk.Book,
            "watch price" => TravelAsk.WatchPrice,
            _ => (TravelAsk?)null,
        };
        return ask is { } a ? (m.Groups[1].Value, a) : null;
    }

    public static TravelAnswers Answers(IReadOnlyList<ChatMessage> messages, IEnumerable<string>? queued = null)
    {
        var asked = new Dictionary<string, HashSet<TravelAsk>>(StringComparer.Ordinal);
        void Scan(string text)
        {
            if (ParseAnswer(text) is not { } found) return;
            if (!asked.TryGetValue(found.Id, out var set))
            {
                set = [];
                asked[found.Id] = set;
            }
            set.Add(found.Ask);
        }

        foreach (var message in messages)
        {
            if (message.Role != Role.User) continue;
            foreach (var part in message.Parts.OfType<TextPart>())
                Scan(part.Text);
        }
        if (queued != null)
            foreach (var q in queued) Scan(q);

        return new TravelAnswers(asked.ToDictionary(kv => kv.Key, kv => (IReadOnlySet<TravelAsk>)kv.Value, StringComparer.Ordinal));
    }

    /// Clean short bubble label for travel card actions.
    public static string? BubbleWords(string text)
    {
        if (ParseAnswer(text) is not { } found) return null;
        var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var second = lines.Length > 1 ? lines[1].TrimEnd('\r') : "";
        var prefix = found.Ask == TravelAsk.Book ? "Book" : "Watch price";
        var colon = second.IndexOf(':');
        if (colon >= 0)
        {
            var tail = second[(colon + 1)..].Trim(' ', '.');
            if (tail.Length > 0) return $"{prefix}: {Cut(tail, 72)}";
        }
        return prefix;
    }

    // MARK: IDs & Helpers

    public static string FlightId(string airline, string origin, string destination, string depart, string url)
    {
        var payload = string.Join("\n",
            airline.Trim(), origin.Trim(), destination.Trim(), depart.Trim(), url.Trim());
        return "f-" + Hex8(payload);
    }

    public static string HotelId(string name, string address, string url)
    {
        var payload = string.Join("\n", name.Trim(), address.Trim(), url.Trim());
        return "h-" + Hex8(payload);
    }

    private static string Hex8(string text)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(hash.AsSpan(0, 4)).ToLowerInvariant();
    }

    private static string Trimmed(JsonNode? value)
    {
        if (value is not JsonValue jv) return "";
        if (jv.TryGetValue(out string? s)) return s.Trim();
        if (jv.GetValueKind() == JsonValueKind.Number && TryReadDouble(jv, out var n) && double.IsFinite(n) && Math.Abs(n) < 1e15)
        {
            var rounded = Math.Round(n, MidpointRounding.AwayFromZero);
            return n == rounded
                ? ((long)n).ToString(CultureInfo.InvariantCulture)
                : n.ToString(CultureInfo.InvariantCulture);
        }
        return "";
    }

    private static string Cut(string text, int max) =>
        text.Length <= max ? text : text[..(max - 1)].Trim() + "…";

    private static string OneLine(JsonNode? value, int max)
    {
        var raw = Trimmed(value);
        if (raw.Length == 0) return "";
        var collapsed = string.Join(" ", raw.Split(Newlines, StringSplitOptions.RemoveEmptyEntries));
        return Cut(collapsed, max);
    }

    private static IReadOnlyList<string> ReadStrings(JsonNode? value, int max, int length)
    {
        var result = new List<string>();
        if (value is JsonArray arr)
        {
            foreach (var item in arr)
            {
                var s = OneLine(item, length);
                if (s.Length > 0)
                {
                    result.Add(s);
                    if (result.Count >= max) break;
                }
            }
        }
        else if (value is JsonValue jv && jv.TryGetValue(out string? _))
        {
            var s = OneLine(value, length);
            if (s.Length > 0) result.Add(s);
        }
        return result;
    }

    private static Uri? ParseHttps(string text)
    {
        if (text.Length == 0 || text.Length > 2048) return null;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;
        if (!uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) return null;
        if (string.IsNullOrEmpty(uri.Host) || !uri.Host.Contains('.')) return null;
        return uri;
    }

    private static double? Amount(JsonNode? value)
    {
        if (value is not JsonValue jv) return null;
        if (jv.GetValueKind() == JsonValueKind.Number && TryReadDouble(jv, out var d))
            return double.IsFinite(d) && Math.Abs(d) < 1e12 ? d : null;
        if (jv.TryGetValue(out string? s))
        {
            var cleaned = s.Trim().Replace(",", "", StringComparison.Ordinal);
            if (double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                && double.IsFinite(parsed) && Math.Abs(parsed) < 1e12)
                return parsed;
        }
        return null;
    }

    private static bool TryReadDouble(JsonValue jv, out double value)
    {
        if (jv.TryGetValue(out double d)) { value = d; return true; }
        if (jv.TryGetValue(out long l)) { value = l; return true; }
        if (jv.TryGetValue(out int i)) { value = i; return true; }
        if (jv.TryGetValue(out decimal dec)) { value = (double)dec; return true; }
        if (jv.TryGetValue(out float f)) { value = f; return true; }
        value = 0;
        return false;
    }

    private static double? Fare(JsonNode? value) =>
        Amount(value) is { } n && n > 0 && n < 10_000_000 ? n : null;

    private static int? Whole(double? value, int min, int max)
    {
        if (value is not { } v || !double.IsFinite(v)) return null;
        var rounded = Math.Round(v, MidpointRounding.AwayFromZero);
        if (rounded < min || rounded > max) return null;
        return (int)rounded;
    }

    private static double? Coordinate(JsonNode? value, double limit) =>
        Amount(value) is { } n && Math.Abs(n) <= limit ? n : null;

    private static double? Above(double? was, double? price) =>
        was.HasValue && price.HasValue && was.Value > price.Value ? was : null;

    private static string Currency(JsonNode? value)
    {
        var code = Trimmed(value).ToUpperInvariant();
        return code.Length == 3 && code.All(char.IsAscii) ? code : "USD";
    }
}
