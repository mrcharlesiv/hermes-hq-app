using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;

namespace Hermes.Core.Shopping;

public enum StockState
{
    InStock,
    Out,
    Preorder,
    Backorder,
}

public sealed record ProductChoice(string Name, string Value);

public sealed record ProductSpec(string Label, string Value);

/// The same product at another store (Where to Buy).
public sealed record ProductOffer(
    string Store,
    Uri Url,
    double? Price,
    double? Was,
    StockState Stock,
    string Delivery);

/// One product option from `show_products` (HermesKit/Shopping/ShoppingCards.swift `Product`).
public sealed record ProductOption(
    string Id,
    string Title,
    string Store,
    Uri Url,
    double? Price,
    string Currency,
    double? Was,
    IReadOnlyList<Uri> Images,
    string Brand,
    double? Rating,
    int? Reviews,
    string Badge,
    StockState Stock,
    string Delivery,
    IReadOnlyList<string> Why,
    IReadOnlyList<string> Caution,
    IReadOnlyList<ProductChoice> Options,
    IReadOnlyList<ProductSpec> Specs,
    IReadOnlyList<ProductOffer> Offers)
{
    public Uri? Image => Images.Count > 0 ? Images[0] : null;
    public bool Buyable => Stock != StockState.Out;
}

/// Parsed payload of `show_products` (HermesKit/Shopping/ShoppingCards.swift `Products`).
public sealed record ProductList(
    string Note,
    IReadOnlyList<ProductOption> Products,
    IReadOnlyList<string> FollowUps);

public sealed record OrderItem(
    string Title,
    string Detail,
    int Qty,
    double? Price,
    Uri? Image,
    Uri? Url = null,
    IReadOnlyList<ProductChoice>? Options = null)
{
    public IReadOnlyList<ProductChoice> SafeOptions => Options ?? [];
}

public sealed record OrderCharge(string Label, double Amount);

/// Parsed payload of `order_card` (HermesKit/Shopping/ShoppingCards.swift `Order`).
public sealed record OrderCard(
    string Id,
    string Store,
    Uri? Site,
    IReadOnlyList<OrderItem> Items,
    IReadOnlyList<OrderCharge> Charges,
    double Total,
    string Currency,
    string ShipName,
    string ShipAddress,
    string PayWith,
    string Arrives,
    string Note);

public enum ShoppingAsk
{
    Buy,
    WatchStock,
    WatchPrice,
}

public enum OrderAnswer
{
    Pay,
    Cancel,
}

public enum OrderState
{
    Waiting,
    Approved,
    Cancelled,
    Replaced,
}

/// Everything the chat's messages say about its shopping cards (HermesKit/Shopping/ShoppingCards.swift `Answers`).
public sealed record ShoppingAnswers(
    IReadOnlyDictionary<string, IReadOnlySet<ShoppingAsk>> Asked,
    IReadOnlyDictionary<string, OrderAnswer> Orders,
    IReadOnlyDictionary<string, OrderState> OrderStates)
{
    public static ShoppingAnswers Empty { get; } = new(
        new Dictionary<string, IReadOnlySet<ShoppingAsk>>(),
        new Dictionary<string, OrderAnswer>(),
        new Dictionary<string, OrderState>());

    public IReadOnlySet<ShoppingAsk> ForProduct(string id) =>
        Asked.TryGetValue(id, out var set) ? set : EmptySet;

    private static readonly IReadOnlySet<ShoppingAsk> EmptySet = new HashSet<ShoppingAsk>();
}

/// Port of HermesKit/Shopping/ShoppingCards.swift: product (`show_products`) and order (`order_card`) cards,
/// 256 KB whole-args preservation, add-on handshake metadata, deterministic ids, order item resolution, and markers.
public static class ShoppingCards
{
    public const string ProductsTool = "show_products";
    public const string OrderTool = "order_card";
    public const string CardsPath = "/shopping/cards";
    public const string ProductLead = "[Hermes HQ shopping ";
    public const string OrderLead = "[Hermes HQ order ";
    public const int MaxArgsBytes = 256_000;

    public const int MaxProducts = 12;
    public const int MaxImages = 8;
    public const int MaxWhy = 3;
    public const int MaxCaution = 2;
    public const int MaxOptions = 4;
    public const int MaxSpecs = 8;
    public const int MaxOffers = 5;
    public const int MaxFollowUps = 3;
    public const int MaxItems = 20;
    public const int MaxCharges = 6;

    /// Locale used for bot-facing messages (HermesKit `ShoppingCards.messageLocale`).
    public static readonly CultureInfo MessageCulture = CultureInfo.GetCultureInfo("en-US");

    private const string WatchJob = "Set up a scheduled job that checks every 6 hours (use your price watch job if you have one)";
    private static readonly char[] Newlines = ['\r', '\n', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029'];
    private static readonly Regex ProductMark = new(
        @"^\s*\[Hermes HQ shopping (p-[0-9a-f]{8}): (buy|watch stock|watch price)\]",
        RegexOptions.CultureInvariant);
    private static readonly Regex OrderMark = new(
        @"^\s*\[Hermes HQ order (o-[0-9a-f]{8}): (pay|cancel)\]",
        RegexOptions.CultureInvariant);

    // MARK: Shared Contracts

    public static bool IsShoppingTool(string? name) => name is ProductsTool or OrderTool;

    public static string? RewriteMarkerBubble(string? text) =>
        string.IsNullOrEmpty(text) ? null : BubbleWords(text);

    // MARK: Add-on handshake

    public static bool CardsUntold(JsonObject? status) =>
        status?.Bool("shoppingCards") == true && status?.Bool("shoppingCardsShown") != true;

    public static string? WholeArgsText(string name, JsonObject? args)
    {
        if (!IsShoppingTool(name) || args == null || args.Count == 0) return null;
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

    public static ProductList? ParseProducts(ToolCall call) =>
        ReadArgs(call, ProductsTool) is { } args ? ParseProducts(args) : null;

    public static ProductList? ParseProducts(JsonObject args)
    {
        var list = new List<ProductOption>();
        if (args.Arr("products") is { } arr)
        {
            foreach (var item in arr)
            {
                if (item is JsonObject obj && ParseProduct(obj) is { } product)
                {
                    list.Add(product);
                    if (list.Count >= MaxProducts) break;
                }
            }
        }
        if (list.Count == 0) return null;

        var followUps = ReadStrings(args.Get("follow_ups") ?? args.Get("followUps"), MaxFollowUps, 60);
        return new ProductList(
            Note: OneLine(args.Get("note"), 200),
            Products: list,
            FollowUps: followUps);
    }

    public static ProductOption? ParseProduct(JsonObject o)
    {
        var title = Trimmed(o.Get("title"));
        var store = Trimmed(o.Get("store"));
        var link = Trimmed(o.Get("url"));
        if (title.Length == 0 || store.Length == 0 || ParseHttps(link) is not { } url)
            return null;

        var price = Amount(o.Get("price"));
        var images = new List<Uri>();
        var seen = new HashSet<Uri>();
        void AddImage(JsonNode? node)
        {
            if (images.Count >= 1 + MaxImages) return;
            if (ParseHttps(Trimmed(node)) is { } img && seen.Add(img))
                images.Add(img);
        }
        AddImage(o.Get("image"));
        if (o.Arr("images") is { } imgArr)
            foreach (var v in imgArr) AddImage(v);

        double? rating = Amount(o.Get("rating")) is { } rawRating ? Math.Clamp(rawRating, 0, 5) : null;
        int? reviews = Amount(o.Get("reviews")) is { } rawReviews && rawReviews >= 0 && rawReviews < 1e12
            ? (int)rawReviews
            : null;

        var offers = new List<ProductOffer>();
        if (o.Arr("offers") is { } offerArr)
        {
            foreach (var item in offerArr)
            {
                if (item is JsonObject oo && ParseOffer(oo) is { } offer)
                {
                    offers.Add(offer);
                    if (offers.Count >= MaxOffers) break;
                }
            }
        }

        return new ProductOption(
            Id: ProductId(title, store, link),
            Title: Cut(title, 160),
            Store: Cut(store, 60),
            Url: url,
            Price: price,
            Currency: Currency(o.Get("currency")),
            Was: Above(Amount(o.Get("was")), price),
            Images: images,
            Brand: OneLine(o.Get("brand"), 60),
            Rating: rating,
            Reviews: reviews,
            Badge: OneLine(o.Get("badge"), 24),
            Stock: ParseStock(o.Get("stock")),
            Delivery: OneLine(o.Get("delivery"), 80),
            Why: ReadStrings(o.Get("why"), MaxWhy, 120),
            Caution: ReadStrings(o.Get("caution"), MaxCaution, 120),
            Options: ReadPairs(o.Get("options"), "name", "value", MaxOptions).Select(p => new ProductChoice(p.A, p.B)).ToList(),
            Specs: ReadPairs(o.Get("specs"), "label", "value", MaxSpecs).Select(p => new ProductSpec(p.A, p.B)).ToList(),
            Offers: offers);
    }

    public static ProductOffer? ParseOffer(JsonObject o)
    {
        var store = Trimmed(o.Get("store"));
        if (store.Length == 0 || ParseHttps(Trimmed(o.Get("url"))) is not { } url) return null;
        var price = Amount(o.Get("price"));
        return new ProductOffer(
            Store: Cut(store, 60),
            Url: url,
            Price: price,
            Was: Above(Amount(o.Get("was")), price),
            Stock: ParseStock(o.Get("stock")),
            Delivery: OneLine(o.Get("delivery"), 80));
    }

    public static OrderCard? ParseOrder(ToolCall call) =>
        ReadArgs(call, OrderTool) is { } args ? ParseOrder(args) : null;

    public static OrderCard? ParseOrder(JsonObject o)
    {
        var store = Trimmed(o.Get("store"));
        if (store.Length == 0 || Amount(o.Get("total")) is not { } total) return null;

        var items = new List<OrderItem>();
        if (o.Arr("items") is { } itemArr)
        {
            foreach (var item in itemArr)
            {
                if (item is not JsonObject io) continue;
                var title = Trimmed(io.Get("title"));
                if (title.Length == 0) continue;
                var opts = ReadPairs(io.Get("options"), "name", "value", MaxOptions)
                    .Select(p => new ProductChoice(p.A, p.B)).ToList();
                items.Add(new OrderItem(
                    Title: title,
                    Detail: OneLine(io.Get("detail"), 120),
                    Qty: Quantity(io.Get("qty")),
                    Price: Amount(io.Get("price")),
                    Image: ParseHttps(Trimmed(io.Get("image"))),
                    Url: ParseHttps(Trimmed(io.Get("url"))),
                    Options: opts));
                if (items.Count >= MaxItems) break;
            }
        }
        if (items.Count == 0) return null;

        var charges = new List<OrderCharge>();
        if (o.Arr("charges") is { } chargeArr)
        {
            foreach (var item in chargeArr)
            {
                if (item is not JsonObject co || Amount(co.Get("amount")) is not { } amt) continue;
                var label = Trimmed(co.Get("label"));
                if (label.Length == 0) continue;
                charges.Add(new OrderCharge(Cut(label, 40), amt));
                if (charges.Count >= MaxCharges) break;
            }
        }

        var ship = o.Obj("ship_to") ?? o.Obj("shipTo");
        var code = Currency(o.Get("currency"));
        return new OrderCard(
            Id: OrderId(store, total, code, items),
            Store: Cut(store, 60),
            Site: ParseHttps(Trimmed(o.Get("site"))),
            Items: items,
            Charges: charges,
            Total: total,
            Currency: code,
            ShipName: OneLine(ship?.Get("name"), 80),
            ShipAddress: OneLine(ship?.Get("address"), 200),
            PayWith: OneLine(o.Get("pay_with") ?? o.Get("payWith"), 60),
            Arrives: OneLine(o.Get("arrives"), 60),
            Note: OneLine(o.Get("note"), 160));
    }

    // MARK: Order Item -> Product Resolution

    /// Every product shown by `show_products` across `messages` (newest last).
    public static IReadOnlyList<ProductOption> CatalogProducts(IReadOnlyList<ChatMessage> messages)
    {
        var list = new List<ProductOption>();
        foreach (var message in messages)
        {
            if (message.Role != Role.Assistant) continue;
            foreach (var tool in message.Tools)
            {
                if (ParseProducts(tool) is { } shown)
                    list.AddRange(shown.Products);
            }
        }
        return list;
    }

    /// Resolves the product page an order item opens (HermesKit/Shopping/ShoppingCards.swift `product(for:in:matching:)`).
    public static ProductOption? ProductFor(OrderItem item, OrderCard order, IReadOnlyList<ProductOption>? history = null)
    {
        IReadOnlyList<ProductOption> prior = history ?? [];
        var selectedOptions = ParsedOptions(item);
        if (item.Url is { } directUrl)
        {
            for (var i = prior.Count - 1; i >= 0; i--)
                if (prior[i].Url == directUrl)
                    return Applying(selectedOptions, item, prior[i]);
        }

        static string Norm(string text) => text.Trim().ToLowerInvariant();
        var normTitle = Norm(item.Title);
        var normStore = Norm(order.Store);
        if (normTitle.Length > 0)
        {
            for (var i = prior.Count - 1; i >= 0; i--)
            {
                if (Norm(prior[i].Title) == normTitle && Norm(prior[i].Store) == normStore)
                {
                    var matched = Applying(selectedOptions, item, prior[i]);
                    return item.Url != null ? matched with { Url = item.Url } : matched;
                }
            }
            if (item.Url == null)
            {
                for (var i = prior.Count - 1; i >= 0; i--)
                {
                    if (Norm(prior[i].Title) == normTitle && (normStore.Length == 0 || Norm(prior[i].Store).Length == 0))
                        return Applying(selectedOptions, item, prior[i]);
                }
            }
        }

        var url = item.Url ?? order.Site;
        if (url == null) return null;
        return new ProductOption(
            Id: ProductId(item.Title, order.Store, url.AbsoluteUri),
            Title: Cut(item.Title, 160),
            Store: order.Store,
            Url: url,
            Price: item.Price,
            Currency: order.Currency,
            Was: null,
            Images: item.Image != null ? [item.Image] : [],
            Brand: "",
            Rating: null,
            Reviews: null,
            Badge: "",
            Stock: StockState.InStock,
            Delivery: order.Arrives,
            Why: [],
            Caution: [],
            Options: selectedOptions,
            Specs: [],
            Offers: []);
    }

    public static IReadOnlySet<int> OpenableItemIndices(OrderCard order, IReadOnlyList<ProductOption>? history = null)
    {
        var set = new HashSet<int>();
        for (var i = 0; i < order.Items.Count; i++)
            if (ProductFor(order.Items[i], order, history) != null)
                set.Add(i);
        return set;
    }

    private static ProductOption Applying(IReadOnlyList<ProductChoice> options, OrderItem item, ProductOption baseProduct)
    {
        var images = baseProduct.Images.ToList();
        if (item.Image != null && !images.Contains(item.Image))
            images.Insert(0, item.Image);
        return baseProduct with
        {
            Options = options.Count > 0 ? options : baseProduct.Options,
            Price = item.Price ?? baseProduct.Price,
            Images = images,
        };
    }

    private static IReadOnlyList<ProductChoice> ParsedOptions(OrderItem item)
    {
        if (item.SafeOptions.Count > 0) return item.SafeOptions;
        if (item.Detail.Length == 0) return [];
        var parts = item.Detail.Split(',').Select(p => p.Trim()).Where(p => p.Length > 0).Take(MaxOptions).ToList();
        var list = new List<ProductChoice>(parts.Count);
        for (var i = 0; i < parts.Count; i++)
        {
            var part = parts[i];
            var colon = part.IndexOf(':');
            if (colon >= 0)
            {
                var k = part[..colon].Trim();
                var v = part[(colon + 1)..].Trim();
                if (k.Length > 0 && v.Length > 0)
                {
                    list.Add(new ProductChoice(k, v));
                    continue;
                }
            }
            list.Add(new ProductChoice(i == 0 ? "Option" : "Detail", part));
        }
        return list;
    }

    // MARK: IDs (matching hermes-hq-push & Swift)

    /// "p-" and the first 8 hex digits of SHA-256 over `title\nstore\nurl`, each trimmed.
    public static string ProductId(string title, string store, string url) =>
        "p-" + Hex8(string.Join("\n", title.Trim(), store.Trim(), url.Trim()));

    /// "o-" and the first 8 hex digits of SHA-256 over `store\ntotal\ncurrency\n` + each item's `qty x title`.
    public static string OrderId(string store, double total, string currency, IReadOnlyList<OrderItem> items)
    {
        var head = string.Join("\n",
            store.Trim(),
            total.ToString("F2", CultureInfo.InvariantCulture),
            currency.Trim());
        var lines = items.Select(i => $"{i.Qty} x {i.Title.Trim()}");
        return "o-" + Hex8(head + "\n" + string.Join("\n", lines));
    }

    private static string Hex8(string text)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return Convert.ToHexString(hash.AsSpan(0, 4)).ToLowerInvariant();
    }

    // MARK: Words

    public static string FormatPrice(double amount, string currency, CultureInfo? culture = null)
    {
        var c = culture ?? CultureInfo.CurrentCulture;
        var code = string.IsNullOrWhiteSpace(currency) ? "USD" : currency.Trim().ToUpperInvariant();
        var negative = amount < 0;
        var abs = Math.Abs(amount);
        var formattedNumber = code is "JPY" or "KRW"
            ? abs.ToString("N0", c)
            : abs.ToString("N2", c);
        var prefix = code switch
        {
            "USD" => "$",
            "EUR" => "€",
            "GBP" => "£",
            "JPY" => "¥",
            "CNY" => "CN¥",
            "CAD" => "CA$",
            "AUD" => "A$",
            "NZD" => "NZ$",
            "HKD" => "HK$",
            "SGD" => "S$",
            "MXN" => "MX$",
            "BRL" => "R$",
            "INR" => "₹",
            "KRW" => "₩",
            _ => null,
        };
        if (prefix != null)
            return negative ? $"-{prefix}{formattedNumber}" : $"{prefix}{formattedNumber}";
        return negative ? $"-{formattedNumber} {code}" : $"{formattedNumber} {code}";
    }

    public static string? PriceText(ProductOption product, CultureInfo? culture = null) =>
        product.Price is { } p ? FormatPrice(p, product.Currency, culture) : null;

    public static string? WasText(ProductOption product, CultureInfo? culture = null) =>
        product.Was is { } w ? FormatPrice(w, product.Currency, culture) : null;

    /// "4.6 (1,234)", "4.6", or null without a rating.
    public static string? RatingText(double? rating, int? reviews, CultureInfo? culture = null)
    {
        if (rating is not { } r) return null;
        var c = culture ?? CultureInfo.CurrentCulture;
        var stars = r.ToString("F1", c);
        if (reviews is not { } rev || rev <= 0) return stars;
        return $"{stars} ({rev.ToString("N0", c)})";
    }

    public static string? StockText(StockState stock) => stock switch
    {
        StockState.InStock => null,
        StockState.Out => "Out of stock",
        StockState.Preorder => "Pre-order",
        StockState.Backorder => "Back-ordered",
        _ => null,
    };

    public static string OptionsText(ProductOption product) =>
        string.Join(", ", product.Options.Select(o => $"{o.Name}: {o.Value}"));

    public static string TotalText(OrderCard order, CultureInfo? culture = null) =>
        FormatPrice(order.Total, order.Currency, culture);

    /// "−$5.00" for a discount, "$10.40" for a charge, "Free" for nothing (App/Shopping/OrderCardView.swift).
    public static string ChargeAmountText(double value, string currency, CultureInfo? culture = null)
    {
        if (value == 0) return "Free";
        var text = FormatPrice(Math.Abs(value), currency, culture);
        return value < 0 ? "−" + text : text;
    }

    // MARK: Answers

    private static string Named(ProductOption product)
    {
        var opts = OptionsText(product);
        return opts.Length == 0 ? product.Title : $"{product.Title} ({opts})";
    }

    public static string BuyMessage(ProductOption product)
    {
        var cost = PriceText(product, MessageCulture) is { } price ? $" for {price}" : "";
        return string.Join("\n",
            $"[Hermes HQ shopping {product.Id}: buy]",
            $"Buy this for me: {Named(product)} from {product.Store}{cost}.",
            product.Url.AbsoluteUri,
            "Check the price and that it is in stock, take it to the last step of checkout, then show me the order with order_card and wait for my answer before you pay.");
    }

    public static string WatchStockMessage(ProductOption product) =>
        string.Join("\n",
            $"[Hermes HQ shopping {product.Id}: watch stock]",
            $"Tell me when this is back in stock: {Named(product)} at {product.Store}.",
            product.Url.AbsoluteUri,
            WatchJob + " and tells me only when it is available.");

    public static string? WatchPriceMessage(ProductOption product)
    {
        if (PriceText(product, MessageCulture) is not { } cost) return null;
        return string.Join("\n",
            $"[Hermes HQ shopping {product.Id}: watch price]",
            $"Tell me when the price of this drops below {cost}: {product.Title} at {product.Store}.",
            product.Url.AbsoluteUri,
            WatchJob + " and tells me only when it drops.");
    }

    public static string? FormatMessage(ShoppingAsk ask, ProductOption product) => ask switch
    {
        ShoppingAsk.Buy => BuyMessage(product),
        ShoppingAsk.WatchStock => WatchStockMessage(product),
        ShoppingAsk.WatchPrice => WatchPriceMessage(product),
        _ => null,
    };

    public static string PayMessage(OrderCard order) =>
        $"[Hermes HQ order {order.Id}: pay]\nPlace this order now: {order.Store}, total {TotalText(order, MessageCulture)}. "
        + "Pay exactly this total. If the total on the page is different now, stop and show me a new order card.";

    public static string CancelMessage(OrderCard order) =>
        $"[Hermes HQ order {order.Id}: cancel]\nDon't place this order. Nothing should be charged.";

    public static (string Id, ShoppingAsk Ask)? ParseProductAnswer(string text)
    {
        if (string.IsNullOrEmpty(text) || !text.TrimStart().StartsWith(ProductLead, StringComparison.Ordinal))
            return null;
        var m = ProductMark.Match(text);
        if (!m.Success) return null;
        var ask = m.Groups[2].Value switch
        {
            "buy" => ShoppingAsk.Buy,
            "watch stock" => ShoppingAsk.WatchStock,
            "watch price" => ShoppingAsk.WatchPrice,
            _ => (ShoppingAsk?)null,
        };
        return ask is { } a ? (m.Groups[1].Value, a) : null;
    }

    public static (string Id, OrderAnswer Answer)? ParseOrderAnswer(string text)
    {
        if (string.IsNullOrEmpty(text) || !text.TrimStart().StartsWith(OrderLead, StringComparison.Ordinal))
            return null;
        var m = OrderMark.Match(text);
        if (!m.Success) return null;
        var ans = m.Groups[2].Value switch
        {
            "pay" => OrderAnswer.Pay,
            "cancel" => OrderAnswer.Cancel,
            _ => (OrderAnswer?)null,
        };
        return ans is { } a ? (m.Groups[1].Value, a) : null;
    }

    /// Your bubble's words for an answer: "Buy: Trail Runner 2", "Pay $140.39".
    public static string? BubbleWords(string text)
    {
        if (ParseOrderAnswer(text) is { } orderFound)
        {
            if (orderFound.Answer != OrderAnswer.Pay) return "Cancel order";
            var line = SecondLine(text);
            var at = line.LastIndexOf(", total ", StringComparison.Ordinal);
            if (at >= 0)
            {
                var rest = line[(at + ", total ".Length)..];
                var stop = rest.IndexOf(". Pay exactly", StringComparison.Ordinal);
                var total = stop >= 0 ? rest[..stop] : rest;
                if (total.Length > 0) return $"Pay {total}";
            }
            return "Pay";
        }

        if (ParseProductAnswer(text) is not { } productFound) return null;
        var pLine = SecondLine(text);
        switch (productFound.Ask)
        {
            case ShoppingAsk.Buy:
                return Between(pLine, "Buy this for me: ", " from ") is { } buyName ? $"Buy: {buyName}" : "Buy";
            case ShoppingAsk.WatchStock:
                return Between(pLine, "Tell me when this is back in stock: ", " at ") is { } stockName ? $"Notify me: {stockName}" : "Notify me";
            case ShoppingAsk.WatchPrice:
                var colon = pLine.IndexOf(": ", StringComparison.Ordinal);
                if (colon < 0) return "Notify me of a price drop";
                return Between(pLine[(colon + 2)..], "", " at ") is { } priceName
                    ? $"Notify me of a price drop: {priceName}"
                    : "Notify me of a price drop";
            default:
                return null;
        }
    }

    public static ShoppingAnswers Answers(IReadOnlyList<ChatMessage> messages, IEnumerable<string>? queued = null)
    {
        var asked = new Dictionary<string, HashSet<ShoppingAsk>>(StringComparer.Ordinal);
        var orders = new Dictionary<string, OrderAnswer>(StringComparer.Ordinal);
        var orderCalls = new List<(string CallId, string OrderId)>();

        void Read(string text)
        {
            if (ParseProductAnswer(text) is { } p)
            {
                if (!asked.TryGetValue(p.Id, out var set)) { set = []; asked[p.Id] = set; }
                set.Add(p.Ask);
            }
            if (ParseOrderAnswer(text) is { } o)
                orders[o.Id] = o.Answer;
        }

        foreach (var message in messages)
        {
            foreach (var part in message.Parts)
            {
                if (part is TextPart tp && message.Role == Role.User)
                    Read(tp.Text);
                else if (part is ToolPart { Call: var call } && message.Role == Role.Assistant && call.Name == OrderTool)
                {
                    if (ParseOrder(call) is { } order)
                        orderCalls.Add((call.Id, order.Id));
                }
            }
        }
        if (queued != null)
            foreach (var q in queued) Read(q);

        var orderStates = new Dictionary<string, OrderState>(StringComparer.Ordinal);
        for (var i = 0; i < orderCalls.Count; i++)
        {
            var card = orderCalls[i];
            if (orders.TryGetValue(card.OrderId, out var ans))
                orderStates[card.CallId] = ans == OrderAnswer.Pay ? OrderState.Approved : OrderState.Cancelled;
            else
                orderStates[card.CallId] = i < orderCalls.Count - 1 ? OrderState.Replaced : OrderState.Waiting;
        }

        return new ShoppingAnswers(
            asked.ToDictionary(kv => kv.Key, kv => (IReadOnlySet<ShoppingAsk>)kv.Value, StringComparer.Ordinal),
            orders,
            orderStates);
    }

    public static string? StatusText(OrderState state, OrderCard order, CultureInfo? culture = null) => state switch
    {
        OrderState.Waiting => null,
        OrderState.Approved => $"You approved {TotalText(order, culture)}",
        OrderState.Cancelled => "Cancelled. Nothing was charged.",
        OrderState.Replaced => "A newer order replaced this one",
        _ => null,
    };

    public static string? AskedText(IReadOnlySet<ShoppingAsk> asks)
    {
        if (asks.Contains(ShoppingAsk.Buy)) return "Asked to buy";
        if (asks.Contains(ShoppingAsk.WatchStock) || asks.Contains(ShoppingAsk.WatchPrice)) return "Watching";
        return null;
    }

    // MARK: Helpers

    private static string SecondLine(string text)
    {
        var lines = text.Trim().Split('\n');
        return lines.Length > 1 ? lines[1].TrimEnd('\r') : "";
    }

    private static string? Between(string line, string lead, string end)
    {
        if (!line.StartsWith(lead, StringComparison.Ordinal)) return null;
        var stop = line.LastIndexOf(end, StringComparison.Ordinal);
        if (stop < lead.Length) return null;
        var words = line[lead.Length..stop].Trim();
        return words.Length == 0 ? null : words;
    }

    private static string Trimmed(JsonNode? value) =>
        value is JsonValue jv && jv.TryGetValue(out string? s) ? s.Trim() : "";

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

    private static IReadOnlyList<(string A, string B)> ReadPairs(JsonNode? value, string keyA, string keyB, int max)
    {
        var list = new List<(string, string)>();
        if (value is not JsonArray arr) return list;
        foreach (var item in arr)
        {
            if (item is not JsonObject obj) continue;
            var a = OneLine(obj.Get(keyA), 40);
            var b = OneLine(obj.Get(keyB), 80);
            if (a.Length == 0 || b.Length == 0) continue;
            list.Add((a, b));
            if (list.Count >= max) break;
        }
        return list;
    }

    private static double? Amount(JsonNode? value)
    {
        if (value is not JsonValue jv) return null;
        if (jv.GetValueKind() == JsonValueKind.Number)
        {
            double d;
            if (jv.TryGetValue(out double dv)) d = dv;
            else if (jv.TryGetValue(out long lv)) d = lv;
            else if (jv.TryGetValue(out int iv)) d = iv;
            else if (jv.TryGetValue(out decimal dec)) d = (double)dec;
            else if (jv.TryGetValue(out float fv)) d = fv;
            else return null;
            return double.IsFinite(d) && Math.Abs(d) < 1e12 ? d : null;
        }
        if (jv.TryGetValue(out string? s))
        {
            var cleaned = s.Trim().Replace(",", "", StringComparison.Ordinal);
            if (double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                && double.IsFinite(parsed) && Math.Abs(parsed) < 1e12)
                return parsed;
        }
        return null;
    }

    private static double? Above(double? was, double? price) =>
        was.HasValue && price.HasValue && was.Value > price.Value ? was : null;

    private static int Quantity(JsonNode? value) =>
        Amount(value) is { } n && n >= 1 ? (int)Math.Min(n, 999) : 1;

    private static string Currency(JsonNode? value)
    {
        var code = Trimmed(value);
        return code.Length == 3 && code.All(char.IsLetter) ? code : "USD";
    }

    private static StockState ParseStock(JsonNode? value) => Trimmed(value).ToLowerInvariant() switch
    {
        "out" => StockState.Out,
        "preorder" => StockState.Preorder,
        "backorder" => StockState.Backorder,
        _ => StockState.InStock,
    };

    private static Uri? ParseHttps(string text)
    {
        if (!text.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return null;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri)) return null;
        return string.IsNullOrEmpty(uri.Host) ? null : uri;
    }
}
