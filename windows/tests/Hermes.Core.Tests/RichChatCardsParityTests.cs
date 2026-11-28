using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Asks;
using Hermes.Core.Auth;
using Hermes.Core.Drafts;
using Hermes.Core.Model;
using Hermes.Core.Net;
using Hermes.Core.Notifications;
using Hermes.Core.Shopping;
using Hermes.Core.Travel;

namespace Hermes.Core.Tests;

/// Parity tests for Wave 3A rich chat cards: Travel (`show_flights`, `show_hotels`),
/// Shopping (`show_products`, `order_card`), Drafts (`draft_message` w/ Cc & Bcc),
/// Asks (`ask_to_act` v1 + v2), and `PushPolicy` capability status parsing & handshakes.
public sealed class RichChatCardsParityTests
{
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");

    private static ToolCall MakeToolCall(string id, string name, JsonObject args, ToolState state = ToolState.Done) =>
        new(id, name, null, null, state, ArgsJson: args.ToJsonString());

    private static ChatMessage BotMessage(string id, params ChatPart[] parts) =>
        new(id, Role.Assistant, parts);

    private static ChatMessage UserMessage(string id, string text) =>
        new(id, Role.User, [new TextPart(text)]);

    // MARK: 1. Travel Cards (Flights & Hotels)

    [Fact]
    public void TravelToolContractsAndFlightsParsingValidateAndTrackBooking()
    {
        Assert.True(TravelCards.IsTravelTool("show_flights"));
        Assert.True(TravelCards.IsTravelTool("show_hotels"));
        Assert.False(TravelCards.IsTravelTool("show_products"));
        Assert.False(TravelCards.IsTravelTool(null));

        var args = new JsonObject
        {
            ["step"] = "Checking the fare",
            ["note"] = "Best morning departures to New York.",
            ["relaxed_filters"] = new JsonArray("Nonstop only"),
            ["follow_ups"] = new JsonArray("Show business class", "Return Sunday"),
            ["flights"] = new JsonArray(
                new JsonObject
                {
                    ["airline"] = "Example Air",
                    ["flight_number"] = 412, // numeric coerced to string
                    ["origin"] = "sfo",
                    ["destination"] = "jfk",
                    ["depart_time"] = "08:15",
                    ["arrive_time"] = "16:45",
                    ["duration"] = "5h 30m",
                    ["stops"] = 0,
                    ["cabin"] = "Economy",
                    ["fare_tier"] = "Main Cabin",
                    ["price"] = 348,
                    ["was"] = 412,
                    ["currency"] = "USD",
                    ["url"] = "https://example.com/flights/ea412",
                    ["badge"] = "Best",
                    ["carry_on"] = "1 carry-on included",
                    ["checked_bag"] = "$35 first bag",
                    ["change_rule"] = "Free changes, pay fare difference",
                    ["refund_rule"] = "Credit before departure",
                    ["why"] = new JsonArray("Nonstop with full carry-on included"),
                    ["caution"] = new JsonArray("Seat selection extra at front"),
                },
                new JsonObject
                {
                    ["airline"] = "CloudJet",
                    ["flight_number"] = "CJ 88",
                    ["origin"] = "SFO",
                    ["destination"] = "JFK",
                    ["depart_time"] = "10:05",
                    ["arrive_time"] = "20:10",
                    ["duration"] = "7h 05m",
                    ["stops"] = 1,
                    ["stop_summary"] = "1 stop · DEN",
                    ["price"] = "279.00",
                    ["currency"] = "USD",
                    ["url"] = "https://example.com/flights/cj88",
                    ["segments"] = new JsonArray(
                        new JsonObject
                        {
                            ["airline"] = "CloudJet",
                            ["flight_number"] = "CJ 88",
                            ["origin"] = "sfo",
                            ["destination"] = "den",
                            ["depart_time"] = "10:05",
                            ["arrive_time"] = "13:30",
                            ["duration"] = "2h 25m",
                            ["layover"] = "1h 15m layover in Denver",
                        },
                        new JsonObject
                        {
                            ["airline"] = "CloudJet",
                            ["flight_number"] = "CJ 91",
                            ["origin"] = "DEN",
                            ["destination"] = "JFK",
                            ["depart_time"] = "14:45",
                            ["arrive_time"] = "20:10",
                            ["duration"] = "3h 25m",
                        }),
                },
                // Insecure http URL must be dropped cleanly.
                new JsonObject
                {
                    ["airline"] = "Bad Air",
                    ["origin"] = "SFO",
                    ["destination"] = "JFK",
                    ["price"] = 99,
                    ["url"] = "http://insecure.example.com/bad",
                }),
        };

        var call = MakeToolCall("t-f1", TravelCards.FlightsTool, args);
        var parsed = TravelCards.ParseFlights(call);
        Assert.NotNull(parsed);
        Assert.Equal(2, parsed!.Flights.Count);
        Assert.Equal("Checking the fare", parsed.Step);
        Assert.Equal(["Nonstop only"], parsed.RelaxedFilters);
        Assert.Equal("Relaxed filters: Nonstop only", TravelCards.RelaxedFiltersText(parsed));

        var f0 = parsed.Flights[0];
        Assert.Equal("412", f0.FlightNumber);
        Assert.Equal("SFO → JFK", f0.RouteLabel);
        Assert.Equal("Nonstop", f0.StopsLabel);
        Assert.Equal(412, f0.Was);
        Assert.Equal(2, parsed.Flights[1].Segments.Count);
        Assert.Equal("DEN", parsed.Flights[1].Segments[0].Destination);

        // Book & Watch Price marker round-trip + RewriteMarkerBubble
        var bookMsg = TravelCards.FormatMessage(TravelAsk.Book, f0);
        var ans = TravelCards.ParseAnswer(bookMsg);
        Assert.NotNull(ans);
        Assert.Equal(f0.Id, ans!.Value.Id);
        Assert.Equal(TravelAsk.Book, ans.Value.Ask);
        var bubble = TravelCards.RewriteMarkerBubble(bookMsg);
        Assert.NotNull(bubble);
        Assert.StartsWith("Book:", bubble!);
        Assert.Null(TravelCards.RewriteMarkerBubble("Plain user message"));

        var watchMsg = TravelCards.FormatMessage(TravelAsk.WatchPrice, f0);
        Assert.StartsWith("Watch price:", TravelCards.RewriteMarkerBubble(watchMsg)!);

        var msgs = new[]
        {
            BotMessage("m1", new ToolPart(call)),
            UserMessage("u1", bookMsg),
        };
        var answers = TravelCards.Answers(msgs, queued: [watchMsg]);
        Assert.Contains(TravelAsk.Book, answers.For(f0.Id));
        Assert.Contains(TravelAsk.WatchPrice, answers.For(f0.Id));
        Assert.False(DraftCards.IsNormalHumanTurn(msgs[1]));

        // 256 KB whole-args limit
        var huge = new JsonObject { ["note"] = new string('x', TravelCards.MaxArgsBytes) };
        Assert.Null(TravelCards.WholeArgsText(TravelCards.FlightsTool, huge));
        Assert.NotNull(TravelCards.WholeArgsText(TravelCards.FlightsTool, args));
        Assert.Null(TravelCards.WholeArgsText("terminal", args));
    }

    [Fact]
    public void TravelHotelsNormalizeRatingsCoordinatesImagesAndSubtitles()
    {
        var args = new JsonObject
        {
            ["location"] = "Manhattan, NY",
            ["check_in"] = "Dec 12",
            ["check_out"] = "Dec 15",
            ["guests"] = 2,
            ["note"] = "Top rated stays near Midtown.",
            ["hotels"] = new JsonArray(
                new JsonObject
                {
                    ["name"] = "The Harbor House",
                    ["neighborhood"] = "SoHo",
                    ["address"] = "120 Crosby St, New York, NY 10012",
                    ["latitude"] = 40.7243,
                    ["longitude"] = -73.9975,
                    ["stars"] = 4,
                    ["rating"] = 9.2, // 10-pt scale normalizes to 4.6
                    ["reviews"] = 842,
                    ["price_per_night"] = 289,
                    ["total_price"] = 960,
                    ["was"] = 340,
                    ["currency"] = "USD",
                    ["url"] = "https://example.com/hotels/harbor-house",
                    ["image"] = "https://example.com/img/h1.jpg",
                    ["images"] = new JsonArray(
                        "https://example.com/img/h1.jpg", // duplicate removed
                        "https://example.com/img/h2.jpg",
                        "http://example.com/img/insecure.jpg"),
                    ["badge"] = "Free cancel",
                    ["cancellation"] = "Free cancellation until Dec 10",
                    ["amenities"] = new JsonArray("Wi-Fi", "Gym", "Rooftop bar"),
                },
                new JsonObject
                {
                    ["name"] = "Out-of-bounds Coord Inn",
                    ["address"] = "555 Example Ave",
                    ["latitude"] = 999,
                    ["longitude"] = -200,
                    ["stars"] = 7, // invalid star count -> null
                    ["price"] = 199,
                    ["url"] = "https://example.com/hotels/oob",
                }),
        };

        var parsed = TravelCards.ParseHotels(MakeToolCall("t-h1", TravelCards.HotelsTool, args));
        Assert.NotNull(parsed);
        Assert.Equal("Manhattan, NY · Dec 12 – Dec 15 · 2", TravelCards.HotelMetaWords(parsed!));
        Assert.Equal(2, parsed.Hotels.Count);

        var h0 = parsed.Hotels[0];
        Assert.True(h0.HasCoordinates);
        Assert.Equal(40.7243, h0.Latitude);
        Assert.Equal(-73.9975, h0.Longitude);
        Assert.Equal(4.6, h0.Rating);
        Assert.Equal(2, h0.Images.Count);
        Assert.Equal("★ 4.6 · SoHo", TravelCards.HotelSubtitle(h0));
        Assert.Equal(["Wi-Fi", "Gym", "Rooftop bar"], h0.Amenities);

        var h1 = parsed.Hotels[1];
        Assert.False(h1.HasCoordinates);
        Assert.Null(h1.Stars);
        Assert.Equal("555 Example Ave", TravelCards.HotelSubtitle(h1));

        // Safe web URI gate
        Assert.True(TravelCards.IsSafeWebUri(new Uri("https://example.com/hotel")));
        Assert.True(TravelCards.IsSafeWebUri(new Uri("http://example.com/hotel")));
        Assert.False(TravelCards.IsSafeWebUri(new Uri("javascript:alert(1)")));
        Assert.False(TravelCards.IsSafeWebUri(new Uri("file:///C:/Windows/win.ini")));

        // Hotel watch price bubble includes hotel name
        var watchMsg = TravelCards.FormatMessage(TravelAsk.WatchPrice, h0);
        Assert.StartsWith("Watch price: The Harbor House", TravelCards.RewriteMarkerBubble(watchMsg)!);
    }

    // MARK: 2. Shopping Cards (Products & Orders)

    [Fact]
    public void ShoppingIdsMatchAddOnVectorsAndProductsParseLeniently()
    {
        Assert.True(ShoppingCards.IsShoppingTool("show_products"));
        Assert.True(ShoppingCards.IsShoppingTool("order_card"));
        Assert.False(ShoppingCards.IsShoppingTool("show_flights"));

        // Exact SHA-256 vectors from Tests/Shopping/ShoppingCardsTests.swift
        Assert.Equal("p-d6dc20a2",
            ShoppingCards.ProductId("Trail Runner 2", "Example Outfitters", "https://example.com/p/trail-runner-2"));
        Assert.Equal("p-d6dc20a2",
            ShoppingCards.ProductId("  Trail Runner 2\n", "Example Outfitters ", " https://example.com/p/trail-runner-2"));

        var items = new[]
        {
            new OrderItem("Trail Runner 2", "", 1, null, null),
            new OrderItem("Wool Socks", "", 2, null, null),
        };
        Assert.Equal("o-4a928c2e", ShoppingCards.OrderId("Example Outfitters", 140.39, "USD", items));
        Assert.NotEqual("o-4a928c2e", ShoppingCards.OrderId("Example Outfitters", 140.40, "USD", items));

        // Prices and ratings formatting
        Assert.Equal("$129.99", ShoppingCards.FormatPrice(129.99, "USD", Us));
        Assert.Equal("$1,234.50", ShoppingCards.FormatPrice(1234.5, "USD", Us));
        Assert.Equal("€20.00", ShoppingCards.FormatPrice(20, "EUR", Us));
        Assert.Equal("4.6 (1,234)", ShoppingCards.RatingText(4.6, 1234, Us));
        Assert.Equal("4.0", ShoppingCards.RatingText(4, null, Us));
        Assert.Equal("Free", ShoppingCards.ChargeAmountText(0, "USD", Us));
        Assert.Equal("−$5.00", ShoppingCards.ChargeAmountText(-5, "USD", Us));

        // Lenient product parsing: drops invalid items, clamps rating, keeps https images deduped
        var args = new JsonObject
        {
            ["note"] = "Top trail shoes",
            ["follow_ups"] = new JsonArray("Cheaper", "Waterproof"),
            ["products"] = new JsonArray(
                new JsonObject { ["title"] = "No Store", ["url"] = "https://example.com/a" },
                new JsonObject { ["title"] = "Insecure", ["store"] = "Shop", ["url"] = "http://example.com/a" },
                new JsonObject
                {
                    ["title"] = "Trail Runner 2",
                    ["store"] = "Example Outfitters",
                    ["url"] = "https://example.com/p/trail-runner-2",
                    ["price"] = 129.99,
                    ["was"] = 159.99,
                    ["currency"] = "USD",
                    ["image"] = "https://example.com/a.jpg",
                    ["images"] = new JsonArray("https://example.com/b.jpg", "https://example.com/a.jpg", "http://example.com/c.jpg"),
                    ["rating"] = 9.0, // clamped to 5.0
                    ["reviews"] = 1234,
                    ["stock"] = "preorder",
                    ["options"] = new JsonArray(new JsonObject { ["name"] = "Colour", ["value"] = "Navy" }),
                    ["specs"] = new JsonArray(new JsonObject { ["label"] = "Weight", ["value"] = "280 g" }),
                    ["why"] = "Wide toe box", // single string accepted
                },
                new JsonObject
                {
                    ["title"] = "Out Of Stock Shoe",
                    ["store"] = "Example Outfitters",
                    ["url"] = "https://example.com/p/oos",
                    ["price"] = "$99.99", // symbol string -> null price
                    ["stock"] = "out",
                }),
        };

        var parsed = ShoppingCards.ParseProducts(MakeToolCall("p1", ShoppingCards.ProductsTool, args));
        Assert.NotNull(parsed);
        Assert.Equal(2, parsed!.Products.Count);
        var p0 = parsed.Products[0];
        Assert.Equal("p-d6dc20a2", p0.Id);
        Assert.Equal(5.0, p0.Rating);
        Assert.Equal(StockState.Preorder, p0.Stock);
        Assert.True(p0.Buyable);
        Assert.Equal(2, p0.Images.Count);
        Assert.Equal(["Wide toe box"], p0.Why);
        Assert.Equal("Colour: Navy", ShoppingCards.OptionsText(p0));

        var p1 = parsed.Products[1];
        Assert.Null(p1.Price);
        Assert.False(p1.Buyable);
        Assert.Null(ShoppingCards.WatchPriceMessage(p1));

        // 256 KB limit
        var huge = new JsonObject { ["note"] = new string('x', ShoppingCards.MaxArgsBytes) };
        Assert.Null(ShoppingCards.WholeArgsText(ShoppingCards.ProductsTool, huge));
    }

    [Fact]
    public void ShoppingOrdersResolveItemsTrackStatesAndRewriteBubbles()
    {
        var prodCall = MakeToolCall("p1", ShoppingCards.ProductsTool, new JsonObject
        {
            ["products"] = new JsonArray(new JsonObject
            {
                ["title"] = "Trail Runner 2",
                ["store"] = "Example Outfitters",
                ["url"] = "https://example.com/p/trail-runner-2",
                ["price"] = 129.99,
                ["why"] = new JsonArray("Great grip on wet trails"),
            }),
        });
        var orderArgs1 = new JsonObject
        {
            ["store"] = "Example Outfitters",
            ["site"] = "https://example.com/checkout",
            ["total"] = 140.39,
            ["currency"] = "USD",
            ["items"] = new JsonArray(
                new JsonObject { ["title"] = "Trail Runner 2", ["detail"] = "Color: Navy, Size: 10", ["qty"] = 1, ["price"] = 129.99 },
                new JsonObject { ["title"] = "Wool Socks", ["qty"] = 2, ["url"] = "https://example.com/p/socks" }),
            ["charges"] = new JsonArray(
                new JsonObject { ["label"] = "Shipping", ["amount"] = 0 },
                new JsonObject { ["label"] = "Tax", ["amount"] = 10.40 }),
            ["ship_to"] = new JsonObject { ["name"] = "Wren Example", ["address"] = "1 Demo Street" },
            ["pay_with"] = "Visa ending 4242",
            ["arrives"] = "Fri, Nov 20",
        };
        var orderCall1 = MakeToolCall("o1", ShoppingCards.OrderTool, orderArgs1);
        var order1 = ShoppingCards.ParseOrder(orderCall1)!;
        Assert.Equal("o-4a928c2e", order1.Id);

        var history = ShoppingCards.CatalogProducts([BotMessage("m1", new ToolPart(prodCall))]);
        var openable = ShoppingCards.OpenableItemIndices(order1, history);
        Assert.Equal(new HashSet<int> { 0, 1 }, openable);

        var resolved0 = ShoppingCards.ProductFor(order1.Items[0], order1, history)!;
        Assert.Equal("https://example.com/p/trail-runner-2", resolved0.Url.AbsoluteUri);
        Assert.Equal(["Great grip on wet trails"], resolved0.Why);
        Assert.Contains(new ProductChoice("Color", "Navy"), resolved0.Options);
        Assert.Contains(new ProductChoice("Size", "10"), resolved0.Options);

        // Pay / Cancel / Buy bubble rewriting (including titles containing " from ")
        var giftProduct = resolved0 with { Title = "Gift from the Hills", Options = [new ProductChoice("Colour", "Navy")] };
        Assert.Equal("Buy: Gift from the Hills (Colour: Navy)",
            ShoppingCards.RewriteMarkerBubble(ShoppingCards.BuyMessage(giftProduct)));
        Assert.Equal("Notify me: Trail Runner 2",
            ShoppingCards.RewriteMarkerBubble(ShoppingCards.WatchStockMessage(resolved0 with { Options = [] })));
        Assert.Equal("Notify me of a price drop: Trail Runner 2",
            ShoppingCards.RewriteMarkerBubble(ShoppingCards.WatchPriceMessage(resolved0)!));
        Assert.Equal("Pay $140.39", ShoppingCards.RewriteMarkerBubble(ShoppingCards.PayMessage(order1)));
        Assert.Equal("Cancel order", ShoppingCards.RewriteMarkerBubble(ShoppingCards.CancelMessage(order1)));

        // Order states: waiting -> replaced by newer order -> approved/cancelled
        var orderArgs2 = JsonNode.Parse(orderArgs1.ToJsonString())!.AsObject();
        orderArgs2["total"] = 145.79;
        var orderCall2 = MakeToolCall("o2", ShoppingCards.OrderTool, orderArgs2);

        var mOrder1 = BotMessage("mo1", new ToolPart(orderCall1));
        var mOrder2 = BotMessage("mo2", new ToolPart(orderCall2));

        var waiting = ShoppingCards.Answers([mOrder1]);
        Assert.Equal(OrderState.Waiting, waiting.OrderStates["o1"]);

        var replaced = ShoppingCards.Answers([mOrder1, mOrder2]);
        Assert.Equal(OrderState.Replaced, replaced.OrderStates["o1"]);
        Assert.Equal(OrderState.Waiting, replaced.OrderStates["o2"]);

        var approved = ShoppingCards.Answers([mOrder1], queued: [ShoppingCards.PayMessage(order1)]);
        Assert.Equal(OrderState.Approved, approved.OrderStates["o1"]);
        Assert.Equal("You approved $140.39", ShoppingCards.StatusText(OrderState.Approved, order1, Us));
        Assert.Equal("Cancelled. Nothing was charged.", ShoppingCards.StatusText(OrderState.Cancelled, order1, Us));
        Assert.Equal("A newer order replaced this one", ShoppingCards.StatusText(OrderState.Replaced, order1, Us));
    }

    // MARK: 3. Draft Cards (To / Cc / Bcc, 12-name cap, boilerplate, SendMessage, folding)

    [Fact]
    public void DraftCardsParseToCcBccPreserveIdAndFormatSendMessage()
    {
        Assert.True(DraftCards.IsDraftTool("draft_message"));
        Assert.False(DraftCards.IsDraftTool("send_message"));

        const string body = "Hi Dana, the Q3 numbers are in the shared folder. Can we meet Thursday at 2 to go through them?";
        // Exact SHA-256 vector from Tests/Drafts/DraftCardsTests.swift / drafts.py
        Assert.Equal("d-0629889e", DraftCards.Id("Slack", "#finance", "", body));

        var emailArgs = new JsonObject
        {
            ["app"] = "Email — from owner@example.com",
            ["to"] = "alex@example.com",
            ["cc"] = new JsonArray("finance@example.com", "  ", "ops@example.com\nlegal@example.com"),
            ["bcc"] = "archive@example.com;",
            ["subject"] = "Q4 update",
            ["body"] = "  " + body + "\n",
            ["thread"] = new JsonArray(
                new JsonObject { ["from"] = "Dana", ["when"] = "Mon 4:52 PM", ["text"] = "Are Q4 numbers final?" },
                new JsonObject { ["sender"] = "Luis", ["body"] = "Tomorrow morning." }),
        };

        var draft = DraftCards.Parse(MakeToolCall("c1", DraftCards.Tool, emailArgs));
        Assert.NotNull(draft);
        Assert.Equal("Email", draft!.AppName);
        Assert.Equal("owner@example.com", draft.From);
        Assert.Equal("finance@example.com, ops@example.com, legal@example.com", draft.Cc);
        Assert.Equal("archive@example.com", draft.Bcc);
        Assert.Equal(DraftCards.Id("Email — from owner@example.com", "alex@example.com", "Q4 update", body), draft.Id);
        Assert.Equal(2, draft.Thread.Count);
        Assert.Equal("Show Conversation (2)", DraftCards.ThreadTitle(draft));

        var fields = DraftCards.Fields(draft);
        Assert.Equal(["To", "Cc", "Bcc", "From", "Subject"], fields.Select(f => f.Label).ToArray());
        Assert.True(fields[0].People && fields[1].People && fields[2].People);
        Assert.True(fields[4].Strong);

        // SendMessage includes Cc, Bcc, Subject when present
        var sendMsg = DraftCards.SendMessage(draft, draft.Body);
        Assert.Contains("Send this to alex@example.com (Email) from owner@example.com exactly as written:", sendMsg);
        Assert.Contains("Cc: finance@example.com, ops@example.com, legal@example.com", sendMsg);
        Assert.Contains("Bcc: archive@example.com", sendMsg);
        Assert.Contains("Subject: Q4 update", sendMsg);
        Assert.Equal("Send it", DraftCards.RewriteMarkerBubble(sendMsg));

        // Edited draft carries "I edited it." lead and updates bubble wording
        var editedMsg = DraftCards.SendMessage(draft, "Updated body text.");
        Assert.Contains("]\nI edited it. Send this to ", editedMsg);
        Assert.Equal("Send it with my edits", DraftCards.RewriteMarkerBubble(editedMsg));
        var parsedEdited = DraftCards.ParseAnswer(editedMsg);
        Assert.Equal(new DraftAnswer.Send("Updated body text."), parsedEdited?.Answer);

        // Skip message
        var skipMsg = DraftCards.SkipMessage(draft);
        Assert.Equal("Don’t send it", DraftCards.RewriteMarkerBubble(skipMsg));
        Assert.Equal(new DraftAnswer.Skip(), DraftCards.ParseAnswer(skipMsg)?.Answer);

        // 12-name cap in ShownPeople: 13 names shown whole, 14 names caps at 12 + ", and 2 more"
        var thirteen = string.Join(", ", Enumerable.Range(1, 13).Select(i => $"u{i}@example.com"));
        Assert.DoesNotContain("more", DraftCards.ShownPeople(thirteen));
        var fourteen = string.Join(", ", Enumerable.Range(1, 14).Select(i => $"u{i}@example.com"));
        var shown14 = DraftCards.ShownPeople(fourteen);
        Assert.EndsWith(", and 2 more", shown14);
        Assert.Contains("u12@example.com", shown14);
        Assert.DoesNotContain("u13@example.com", shown14);
    }

    [Fact]
    public void DraftCardsDetectBoilerplateAndFoldSupersededAndStaleDrafts()
    {
        // Ready boilerplate detection
        Assert.True(DraftCards.IsReadyBoilerplate("Your Slack draft for #finance is ready to review. Nothing's been sent."));
        Assert.True(DraftCards.IsReadyBoilerplate("Your revised email to Dana is ready for review. Nothing has been sent."));
        Assert.True(DraftCards.IsReadyBoilerplate("Your text to Dana is ready to send."));
        Assert.True(DraftCards.IsReadyBoilerplate("Nothing's been sent yet."));
        Assert.False(DraftCards.IsReadyBoilerplate("I left out the Q4 projection until we confirm it."));
        Assert.False(DraftCards.IsReadyBoilerplate("Your draft is ready. See https://example.com for details."));
        Assert.False(DraftCards.IsReadyBoilerplate("Your draft is ready.\nSecond line."));
        Assert.False(DraftCards.IsReadyBoilerplate(null));

        var c1 = MakeToolCall("c1", DraftCards.Tool, new JsonObject { ["app"] = "Slack", ["to"] = "#finance", ["body"] = "First draft" });
        var c2 = MakeToolCall("c2", DraftCards.Tool, new JsonObject { ["app"] = "Slack", ["to"] = "#finance", ["body"] = "Revised draft" });
        var c3 = MakeToolCall("c3", DraftCards.Tool, new JsonObject { ["app"] = "Slack", ["to"] = "#design", ["body"] = "Design draft" });

        // Same destination supersedes c1; sibling target c3 stays live
        var messages = new[]
        {
            BotMessage("m1", new ToolPart(c1)),
            BotMessage("m2", new ToolPart(c2)),
            BotMessage("m3", new ToolPart(c3)),
        };
        var superseded = DraftCards.SupersededRowIds(messages);
        Assert.Contains(DraftCards.RowId("m1", "c1"), superseded);
        Assert.DoesNotContain(DraftCards.RowId("m2", "c2"), superseded);
        Assert.DoesNotContain(DraftCards.RowId("m3", "c3"), superseded);

        // Stale folding after 2 normal human turns (1 human turn stays live)
        var oneTurn = new[] { BotMessage("m1", new ToolPart(c1)), UserMessage("u1", "Quick question?") };
        Assert.Empty(DraftCards.StaleRowIds(oneTurn));

        var twoTurns = new[]
        {
            BotMessage("m1", new ToolPart(c1)),
            UserMessage("u1", "Quick question?"),
            UserMessage("u2", "Let's check Monday's agenda instead."),
        };
        Assert.Contains(DraftCards.RowId("m1", "c1"), DraftCards.StaleRowIds(twoTurns));

        // Adjacent answer echo detection
        var d2 = DraftCards.Parse(c2)!;
        var echoMsgs = new[]
        {
            BotMessage("m2", new ToolPart(c2)),
            UserMessage("u1", DraftCards.SendMessage(d2, d2.Body)),
        };
        Assert.True(DraftCards.IsAdjacentAnswerEcho(echoMsgs, 1, d2.Id));
    }

    // MARK: 4. Ask-to-Act Cards (`ask_to_act`)

    [Fact]
    public void AskCardsParseV1AndV2MatchVectorRewriteBubblesAndDetectBoilerplate()
    {
        Assert.True(AskCards.IsAskTool("ask_to_act"));
        Assert.False(AskCards.IsAskTool("clarify"));

        // Exact SHA-256 vector from Tests/Asks/AskCardsTests.swift
        Assert.Equal("a-9cfc6386", AskCards.Id(
            "Start with the pilot group?",
            "Dana Reyes",
            "Ready to go live. Start with the pilot group?",
            ["Yes", "No"]));

        const string yesReply = "Yes — let's start with the pilot group.";
        var args = new JsonObject
        {
            ["question"] = "Start with the pilot group?",
            ["then"] = "I'll draft the reply. Nothing gets sent.",
            ["app"] = "Slack",
            ["from"] = "Dana Reyes",
            ["where"] = "DM",
            ["when"] = "11:03 AM",
            ["quote"] = "Ready to go live. Start with the pilot group?",
            ["attachments"] = new JsonArray(
                new JsonObject { ["name"] = "Q3_Plan", ["note"] = "Draft plan" },
                "Notes.txt"),
            ["link"] = new JsonObject { ["title"] = "Open Dana's DM", ["url"] = "https://example.com/slack/dm" },
            ["replies"] = new JsonArray("  " + yesReply + "\n", ""),
            ["reply_to"] = new JsonObject { ["app"] = "Slack", ["to"] = "Dana Reyes" },
        };

        var call = MakeToolCall("a1", AskCards.Tool, args);
        var ask = AskCards.Parse(call);
        Assert.NotNull(ask);
        Assert.Equal("a-9cfc6386", ask!.Id);
        Assert.Equal(["Yes", "No"], ask.Choices);
        Assert.Equal(2, ask.Attachments.Count);
        Assert.Equal("Dana Reyes · DM · 11:03 AM", AskCards.SourceDetail(ask));
        Assert.Equal(yesReply, AskCards.Reply(ask, 0));
        Assert.Null(AskCards.Reply(ask, 1));
        Assert.Equal("Reply to Dana Reyes · Slack", AskCards.ReplyHeading(ask.ReplyTo!));

        // v1 choice message + bubble
        var yesMsg = AskCards.ChoiceMessage(ask, 0)!;
        Assert.Equal("Yes", AskCards.RewriteMarkerBubble(yesMsg));
        Assert.Equal("You answered: Yes", AskCards.StatusText(ask, AskCards.ParseAnswer(yesMsg)!.Value.Answer));

        // other message + bubble
        var otherMsg = AskCards.OtherMessage(ask, "Only team leads first.");
        Assert.Equal("Only team leads first.", AskCards.RewriteMarkerBubble(otherMsg));

        // v2 send message (plain & edited)
        var sendMsg = AskCards.SendMessage(ask, 0, yesReply)!;
        Assert.Equal("Yes · Send the reply", AskCards.RewriteMarkerBubble(sendMsg));
        var parsedSend = AskCards.ParseAnswer(sendMsg)!.Value;
        Assert.Equal(new AskAnswer.Sent(1, "Yes.", yesReply), parsedSend.Answer);
        Assert.Equal("You answered: Yes · Reply approved", AskCards.StatusText(ask, parsedSend.Answer));

        var editedSend = AskCards.SendMessage(ask, 0, "Pilot group first, everyone else next week.")!;
        Assert.Equal("Yes · Send it with my edits", AskCards.RewriteMarkerBubble(editedSend));

        // Boilerplate detection
        Assert.True(AskCards.IsReadyBoilerplate("Let me know how you'd like to proceed."));
        Assert.True(AskCards.IsReadyBoilerplate("Waiting on you."));
        Assert.True(AskCards.IsReadyBoilerplate("Your decision card is ready for review."));
        Assert.False(AskCards.IsReadyBoilerplate("Dana mentioned the client wants this before noon."));
        Assert.False(AskCards.IsReadyBoilerplate(null));

        // Add-on handshake checks `actCards`, NOT legacy `askCards`
        Assert.True(AskCards.CardsUntold(new JsonObject { ["actCards"] = true, ["actCardsShown"] = false }));
        Assert.False(AskCards.CardsUntold(new JsonObject { ["askCards"] = true, ["askCardsShown"] = false }));

        // Stale folding when a later human turn lands
        var staleMsgs = new[]
        {
            BotMessage("m1", new ToolPart(call)),
            UserMessage("u2", "Let's pause that for now."),
        };
        Assert.Contains(AskCards.RowId("m1", "a1"), AskCards.StaleRowIds(staleMsgs));
    }

    // MARK: 5. PushPolicy Capability Status Parsing & Handshakes

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<(HttpMethod Method, string Path)> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.Method, request.RequestUri?.AbsolutePath ?? ""));
            return Task.FromResult(respond(request));
        }
    }

    [Fact]
    public async Task PushPolicyReadsCardCapabilitiesAndSendsPutHandshakes()
    {
        const string statusJson = """
            {
                "seal": true,
                "tasks": true,
                "goal_pages": 4,
                "pluginVersion": "0.9.87",
                "kinds": ["turnDone", "approval", "input"],
                "travelCards": true,
                "travelCardsShown": false,
                "shoppingCards": true,
                "shoppingCardsShown": false,
                "draftCards": true,
                "draftCardsShown": true,
                "actCards": true,
                "actCardsShown": false,
                "toolPermissions": true,
                "toolPermissionsAsk": false
            }
            """;

        var handler = new StubHandler(req =>
        {
            var path = req.RequestUri?.AbsolutePath ?? "";
            if (req.Method == HttpMethod.Get && path == "/api/plugins/hermes-hq-push/status")
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(statusJson, Encoding.UTF8, "application/json"),
                };
            if (req.Method == HttpMethod.Put && path.StartsWith("/api/plugins/hermes-hq-push/", StringComparison.Ordinal))
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent("""{"ok":true}""", Encoding.UTF8, "application/json"),
                };
            return new HttpResponseMessage(HttpStatusCode.NotFound);
        });

        await using var session = new GatewaySession(
            GatewayAddress.Validated("http://127.0.0.1:9"),
            new StoredAccount("http://127.0.0.1:9", "qa"),
            new MemoryTokenStore(),
            handler);

        var status = await PushPolicy.ReadStatusAsync(session);
        Assert.True(status.Installed);
        Assert.Equal("0.9.87", status.Version);
        Assert.True(status.Seals);
        Assert.True(status.Tasks);
        Assert.True(status.Goals);
        Assert.True(status.TravelCards);
        Assert.False(status.TravelCardsShown);
        Assert.True(status.ShoppingCards);
        Assert.False(status.ShoppingCardsShown);
        Assert.True(status.DraftCards);
        Assert.True(status.DraftCardsShown);
        Assert.True(status.ActCards);
        Assert.False(status.ActCardsShown);
        Assert.True(status.ToolPermissions);
        Assert.False(status.ToolPermissionsAsk);

        // When `toolPermissionsAsk` is omitted from JSON, default is true (HermesKit PushPolicy parity).
        Assert.True(PushPolicy.ToolPermissionsAsk(new JsonObject { ["toolPermissions"] = true }));

        // SyncCardCapabilitiesAsync sends PUT only for untold capabilities (travel, shopping, asks — NOT drafts).
        await PushPolicy.SyncCardCapabilitiesAsync(session, status);
        var puts = handler.Requests.Where(r => r.Method == HttpMethod.Put).Select(r => r.Path).ToList();
        Assert.Contains("/api/plugins/hermes-hq-push/travel/cards", puts);
        Assert.Contains("/api/plugins/hermes-hq-push/shopping/cards", puts);
        Assert.Contains("/api/plugins/hermes-hq-push/asks/cards", puts);
        Assert.DoesNotContain("/api/plugins/hermes-hq-push/drafts/cards", puts);

        // Direct handshake helpers all hit the exact expected PUT routes.
        Assert.True(await PushPolicy.EnableTravelCardsAsync(session));
        Assert.True(await PushPolicy.EnableShoppingCardsAsync(session));
        Assert.True(await PushPolicy.EnableDraftCardsAsync(session));
        Assert.True(await PushPolicy.EnableAskCardsAsync(session));
        Assert.Contains((HttpMethod.Put, "/api/plugins/hermes-hq-push/drafts/cards"), handler.Requests);
    }
}
