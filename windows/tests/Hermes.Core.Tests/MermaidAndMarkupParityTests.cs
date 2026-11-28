using System.Text.Json.Nodes;
using Hermes.Core.Attachments;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// Wave 3B parity tests covering offline Mermaid parsing (including all safety caps & M5 Cartesian fan-out guard),
/// Image Mark Up model/undo/prompt composition, and Calm Chat Readability rules on ClarifySettled.
public class MermaidAndMarkupParityTests
{
    // =========================================================================
    // MARK: MermaidParser
    // =========================================================================

    [Fact]
    public void MermaidLanguageDetectionMatchesMermaidAndMmdOnly()
    {
        Assert.True(MermaidParser.IsMermaidLanguage("mermaid"));
        Assert.True(MermaidParser.IsMermaidLanguage("MERMAID"));
        Assert.True(MermaidParser.IsMermaidLanguage("  mmd  "));
        Assert.False(MermaidParser.IsMermaidLanguage("markdown"));
        Assert.False(MermaidParser.IsMermaidLanguage("csharp"));
        Assert.False(MermaidParser.IsMermaidLanguage(""));
        Assert.False(MermaidParser.IsMermaidLanguage(null));
    }

    [Fact]
    public void ParsesFlowchartDirectionsShapesSubgraphsAndChainedEdges()
    {
        const string source = """
            ---
            title: Architecture
            ---
            %% Leading comment
            flowchart LR
                subgraph api [API Layer]
                    A[Start] --> B(Validate) ==>|ok| C([Done])
                    B -.->|retry| D{Retry?}
                    D --- E((Queue))
                    E --> F[(Database)]
                    F --> G{{Metrics}}
                    G --> H>Flagged]
                end
                style A fill:#f9f
                classDef default fill:#fff
                click A "https://example.com"
            """;

        var diagram = MermaidParser.Parse(source);
        Assert.NotNull(diagram);
        Assert.Equal("Flowchart", diagram.KindLabel);
        var flow = Assert.IsType<MermaidKind.Flowchart>(diagram.Kind);
        Assert.Equal(MermaidDirection.LeftRight, flow.Direction);

        var sub = Assert.Single(flow.Subgraphs);
        Assert.Equal("api", sub.Id);
        Assert.Equal("API Layer", sub.Title);

        var byId = flow.Nodes.ToDictionary(n => n.Id, StringComparer.Ordinal);
        Assert.Equal(MermaidNodeShape.Rect, byId["A"].Shape);
        Assert.Equal("Start", byId["A"].Label);
        Assert.Equal("api", byId["A"].Subgraph);
        Assert.Equal(MermaidNodeShape.Rounded, byId["B"].Shape);
        Assert.Equal(MermaidNodeShape.Stadium, byId["C"].Shape);
        Assert.Equal(MermaidNodeShape.Diamond, byId["D"].Shape);
        Assert.Equal(MermaidNodeShape.Circle, byId["E"].Shape);
        Assert.Equal(MermaidNodeShape.Cylinder, byId["F"].Shape);
        Assert.Equal(MermaidNodeShape.Hexagon, byId["G"].Shape);
        Assert.Equal(MermaidNodeShape.Rect, byId["H"].Shape);

        Assert.Contains(flow.Edges, e => e is { From: "A", To: "B", Style: MermaidEdgeStyle.Solid, Directed: true });
        Assert.Contains(flow.Edges, e => e is { From: "B", To: "C", Label: "ok", Style: MermaidEdgeStyle.Thick, Directed: true });
        Assert.Contains(flow.Edges, e => e is { From: "B", To: "D", Label: "retry", Style: MermaidEdgeStyle.Dashed, Directed: true });
        Assert.Contains(flow.Edges, e => e is { From: "D", To: "E", Style: MermaidEdgeStyle.Open, Directed: false });
    }

    [Fact]
    public void ParsesFlowchartDirectionsAndEmojiLabelsWithCleanHtml()
    {
        var bt = Assert.IsType<MermaidKind.Flowchart>(MermaidParser.Parse("graph BT\nA --> B")!.Kind);
        Assert.Equal(MermaidDirection.BottomUp, bt.Direction);

        var rl = Assert.IsType<MermaidKind.Flowchart>(MermaidParser.Parse("graph RL\nA --> B")!.Kind);
        Assert.Equal(MermaidDirection.RightLeft, rl.Direction);

        var emojiFlow = Assert.IsType<MermaidKind.Flowchart>(
            MermaidParser.Parse("flowchart TD\nA[\"🚀 Launch<br/>&amp; Deploy fa:fa-rocket\"] -->|\"✅\"| B[Ready]; B --> C[Live]")!.Kind);
        Assert.Equal(3, emojiFlow.Nodes.Count);
        Assert.Contains("Launch", emojiFlow.Nodes[0].Label);
        Assert.Contains("& Deploy", emojiFlow.Nodes[0].Label);
        Assert.DoesNotContain("fa:fa-rocket", emojiFlow.Nodes[0].Label);
        Assert.Equal(2, emojiFlow.Edges.Count);
        Assert.Equal("✅", emojiFlow.Edges[0].Label);
    }

    [Fact]
    public void ParsesSequenceDiagramParticipantsAliasesAndArrowKinds()
    {
        const string source = """
            sequenceDiagram
                actor U as User
                participant A as App
                participant G as Gateway
                U->>A: Send prompt
                A-->>G: Stream RPC
                G-)A: Token delta
                A->A: Render
                Note over A: Skipped note line
            """;

        var diagram = MermaidParser.Parse(source);
        Assert.NotNull(diagram);
        Assert.Equal("Sequence Diagram", diagram.KindLabel);
        var seq = Assert.IsType<MermaidKind.Sequence>(diagram.Kind);
        Assert.Equal(["User", "App", "Gateway"], seq.Participants);
        Assert.Equal(4, seq.Messages.Count);
        Assert.Equal(new MermaidSequenceMessage("User", "App", "Send prompt", Dashed: false, OpenArrow: false), seq.Messages[0]);
        Assert.Equal(new MermaidSequenceMessage("App", "Gateway", "Stream RPC", Dashed: true, OpenArrow: false), seq.Messages[1]);
        Assert.Equal(new MermaidSequenceMessage("Gateway", "App", "Token delta", Dashed: false, OpenArrow: true), seq.Messages[2]);
        Assert.Equal(new MermaidSequenceMessage("App", "App", "Render", Dashed: false, OpenArrow: true), seq.Messages[3]);
    }

    [Fact]
    public void ParsesStateDiagramWithStartEndAndMultilineNotes()
    {
        const string source = """
            stateDiagram-v2
                [*] --> Idle
                state "In Progress" as Working
                Idle --> Working : start
                note right of Working
                    ignored multiline note
                end note
                Working : Streaming tokens
                Working --> [*] : finish
            """;

        var diagram = MermaidParser.Parse(source);
        Assert.NotNull(diagram);
        Assert.Equal("State Diagram", diagram.KindLabel);
        var state = Assert.IsType<MermaidKind.State>(diagram.Kind);
        Assert.Contains(state.Nodes, n => n.Id == "__start__" && n.Shape == MermaidNodeShape.Circle);
        Assert.Contains(state.Nodes, n => n.Id == "__end__" && n.Shape == MermaidNodeShape.Circle);
        Assert.Contains(state.Nodes, n => n.Id == "Working" && n.Label.Contains("In Progress") && n.Label.Contains("Streaming tokens"));
        Assert.Equal(3, state.Edges.Count);
        Assert.Equal("start", state.Edges[1].Label);
        Assert.Equal("finish", state.Edges[2].Label);
    }

    [Fact]
    public void ParsesPieChartAndRejectsInvalidOrOversizedSlices()
    {
        const string source = """
            pie showData
                title Latency Budget
                "Network" : 45
                "Parse" : 15.5
                "Render" : 39.5
                "Zero" : 0
                "Negative" : -10
                "Huge" : 1e20
            """;

        var diagram = MermaidParser.Parse(source);
        Assert.NotNull(diagram);
        Assert.Equal("Pie Chart", diagram.KindLabel);
        var pie = Assert.IsType<MermaidKind.Pie>(diagram.Kind);
        Assert.Equal("Latency Budget", pie.Title);
        Assert.True(pie.ShowData);
        Assert.Equal(3, pie.Slices.Count);
        Assert.Equal("Network", pie.Slices[0].Label);
        Assert.Equal(45, pie.Slices[0].Value);

        Assert.Null(MermaidParser.Parse("pie\n\"Zero\" : 0\n\"Bad\" : -5"));
    }

    [Fact]
    public void ParsesGenericDiagramKindsAndRejectsEmptyOrUnknownText()
    {
        var gantt = MermaidParser.Parse("gantt\n    title Release\n    section Build\n    Ship :a1, 2026-01-01, 5d");
        Assert.NotNull(gantt);
        Assert.Equal("Gantt Chart", gantt.KindLabel);
        var generic = Assert.IsType<MermaidKind.Generic>(gantt.Kind);
        Assert.True(generic.Lines.Count >= 2);

        Assert.Equal("Class Diagram", MermaidParser.Parse("classDiagram\nAnimal <|-- Duck")!.KindLabel);
        Assert.Equal("ER Diagram", MermaidParser.Parse("erDiagram\nCUSTOMER ||--o{ ORDER : places")!.KindLabel);
        Assert.Equal("C4 Diagram", MermaidParser.Parse("C4Context\nPerson(u, \"User\")")!.KindLabel);
        Assert.Null(MermaidParser.Parse("classDiagram\n"));
        Assert.Null(MermaidParser.Parse("just some regular text, not mermaid"));
        Assert.Null(MermaidParser.Parse("   \n\t "));
    }

    [Fact]
    public void EnforcesAllMermaidSafetyCaps()
    {
        // MaxSourceLength
        var hugeSource = "flowchart TD\nA --> B\n" + new string(' ', MermaidParser.MaxSourceLength);
        Assert.Null(MermaidParser.Parse(hugeSource));

        // MaxLines
        var tooManyLines = "flowchart TD\n" + string.Join("\n", Enumerable.Range(0, MermaidParser.MaxLines + 5).Select(_ => "%% c"));
        Assert.Null(MermaidParser.Parse(tooManyLines));

        // MaxLineLength
        var longLine = "flowchart TD\nA[\"" + new string('x', MermaidParser.MaxLineLength + 10) + "\"] --> B";
        Assert.Null(MermaidParser.Parse(longLine));

        // MaxNodes (161 nodes -> null)
        var tooManyNodes = "flowchart TD\n" + string.Join("\n", Enumerable.Range(0, MermaidParser.MaxNodes + 1).Select(i => $"N{i}[Node {i}]"));
        Assert.Null(MermaidParser.Parse(tooManyNodes));

        // MaxEdges (401 edges -> null)
        var edgeLines = new List<string> { "flowchart TD" };
        for (var i = 0; i <= MermaidParser.MaxEdges; i++)
            edgeLines.Add($"N{i % 20} --> N{(i + 1) % 20}");
        Assert.Null(MermaidParser.Parse(string.Join("\n", edgeLines)));

        // MaxParticipants (17 participants -> null)
        var seqParticipants = "sequenceDiagram\n" + string.Join("\n", Enumerable.Range(0, MermaidParser.MaxParticipants + 1).Select(i => $"participant P{i}"));
        Assert.Null(MermaidParser.Parse(seqParticipants + "\nP0->>P1: hi"));

        // MaxMessages (121 messages -> null)
        var seqMessages = "sequenceDiagram\n" + string.Join("\n", Enumerable.Range(0, MermaidParser.MaxMessages + 1).Select(i => $"A->>B: msg {i}"));
        Assert.Null(MermaidParser.Parse(seqMessages));

        // MaxSlices (25 slices -> null)
        var pieSlices = "pie\n" + string.Join("\n", Enumerable.Range(0, MermaidParser.MaxSlices + 1).Select(i => $"\"S{i}\" : {i + 1}"));
        Assert.Null(MermaidParser.Parse(pieSlices));
    }

    [Fact]
    public void EnforcesM5CartesianFanOutOverflowGuard()
    {
        // Exact boundary: 20 left x 20 right = 400 == MaxEdges -> allowed.
        var left20 = string.Join(" & ", Enumerable.Range(0, 20).Select(i => $"L{i}"));
        var right20 = string.Join(" & ", Enumerable.Range(0, 20).Select(i => $"R{i}"));
        var exact = MermaidParser.Parse($"flowchart TD\n{left20} --> {right20}");
        Assert.NotNull(exact);
        var exactFlow = Assert.IsType<MermaidKind.Flowchart>(exact.Kind);
        Assert.Equal(MermaidParser.MaxEdges, exactFlow.Edges.Count);

        // Over boundary: 20 left x 21 right = 420 > MaxEdges -> rejected cleanly before allocating edges.
        var right21 = string.Join(" & ", Enumerable.Range(0, 21).Select(i => $"R{i}"));
        Assert.Null(MermaidParser.Parse($"flowchart TD\n{left20} --> {right21}"));

        // Huge fan-out: 40 left x 40 right = 1,600 > MaxEdges -> rejected immediately.
        var left40 = string.Join(" & ", Enumerable.Range(0, 40).Select(i => $"A{i}"));
        var right40 = string.Join(" & ", Enumerable.Range(0, 40).Select(i => $"B{i}"));
        Assert.Null(MermaidParser.Parse($"flowchart TD\n{left40} --> {right40}"));
    }

    [Fact]
    public void FlowRanksHandlesDagsAndCyclesSafely()
    {
        var dagNodes = new[]
        {
            new MermaidFlowNode("A", "A", MermaidNodeShape.Rect),
            new MermaidFlowNode("B", "B", MermaidNodeShape.Rect),
            new MermaidFlowNode("C", "C", MermaidNodeShape.Rect),
        };
        var dagEdges = new[]
        {
            new MermaidFlowEdge("A", "B", "", MermaidEdgeStyle.Solid, true),
            new MermaidFlowEdge("B", "C", "", MermaidEdgeStyle.Solid, true),
        };
        var dagRanks = MermaidLayoutMath.FlowRanks(dagNodes.Select(n => n.Id).ToList(), dagEdges.Select(e => (e.From, e.To)).ToList());
        Assert.Equal(0, dagRanks["A"]);
        Assert.Equal(1, dagRanks["B"]);
        Assert.Equal(2, dagRanks["C"]);

        // Pure cycle must terminate cleanly with finite non-negative ranks.
        var cycleEdges = new[]
        {
            new MermaidFlowEdge("A", "B", "", MermaidEdgeStyle.Solid, true),
            new MermaidFlowEdge("B", "C", "", MermaidEdgeStyle.Solid, true),
            new MermaidFlowEdge("C", "A", "", MermaidEdgeStyle.Solid, true),
        };
        var cycleRanks = MermaidLayoutMath.FlowRanks(dagNodes.Select(n => n.Id).ToList(), cycleEdges.Select(e => (e.From, e.To)).ToList());
        Assert.Equal(3, cycleRanks.Count);
        Assert.All(cycleRanks.Values, r => Assert.True(r >= 0));
    }

    // =========================================================================
    // MARK: ImageMarkupModel
    // =========================================================================

    [Fact]
    public void MarkupToolsColorsAndPointClampingMatchSpec()
    {
        Assert.Equal(5, ImageMarkupTools.All.Length);
        Assert.Equal("Pin Note", ImageMarkupTool.Pin.Title());
        Assert.Equal(0.036, ImageMarkupTool.Highlighter.DefaultWidthRatio(), 6);
        Assert.Equal(0.38, new ImageMarkupStroke(ImageMarkupTool.Highlighter, ImageMarkupColor.Yellow, 0.036, [new(0.1, 0.2)]).Opacity, 6);
        Assert.Equal(1.0, new ImageMarkupStroke(ImageMarkupTool.Pen, ImageMarkupColor.Red, 0.010, [new(0.1, 0.2)]).Opacity, 6);

        Assert.Equal(6, ImageMarkupColors.All.Length);
        Assert.Equal((0.96, 0.24, 0.22, 1.0), ImageMarkupColor.Red.Rgba());
        Assert.Equal((1.0, 1.0, 1.0, 1.0), ImageMarkupColor.White.Rgba());
        Assert.Equal((0.08, 0.08, 0.10, 1.0), ImageMarkupColor.Black.Rgba());

        var clampedLow = new ImageMarkupPoint(-0.5, double.NegativeInfinity);
        Assert.Equal((0.0, 0.0), (clampedLow.X, clampedLow.Y));
        var clampedHigh = new ImageMarkupPoint(2.5, double.PositiveInfinity);
        Assert.Equal((1.0, 1.0), (clampedHigh.X, clampedHigh.Y));
        var nanPoint = new ImageMarkupPoint(double.NaN, double.NaN);
        Assert.Equal((0.0, 0.0), (nanPoint.X, nanPoint.Y));

        var fromZero = ImageMarkupPoint.FromCanvas(0.5, 0.25, 0, 0);
        Assert.Equal((0.5, 0.25), (fromZero.X, fromZero.Y));
        var canvas = new ImageMarkupPoint(0.25, 0.5).ToCanvas(400, 200);
        Assert.Equal((100.0, 100.0), canvas);

        Assert.Equal(24, ImageMarkupDocument.BadgeDiameter(100));
        Assert.Equal(48, ImageMarkupDocument.BadgeDiameter(2000));
        Assert.Equal(2, ImageMarkupDocument.LineWidth(double.NaN, 500));
        Assert.Equal(2, ImageMarkupDocument.LineWidth(double.PositiveInfinity, 500));
        Assert.Equal(100, ImageMarkupDocument.LineWidth(10.0, 500));
    }

    [Fact]
    public void MarkupDocumentEnforces50StepUndoRedoPinRenumberingAndPointCaps()
    {
        var doc = new ImageMarkupDocument();
        Assert.True(doc.IsEmpty);
        Assert.False(doc.CanUndo);
        Assert.False(doc.CanRedo);

        // Empty strokes are ignored.
        doc.AddStroke(new ImageMarkupStroke(ImageMarkupTool.Pen, ImageMarkupColor.Red, 0.01, []));
        Assert.True(doc.IsEmpty);

        // Oversized stroke points are capped at MaxStrokePoints.
        var hugePoints = Enumerable.Range(0, ImageMarkupDocument.MaxStrokePoints + 250)
            .Select(i => new ImageMarkupPoint(i / 5000.0, 0.5))
            .ToList();
        doc.AddStroke(new ImageMarkupStroke(ImageMarkupTool.Pen, ImageMarkupColor.Blue, 0.01, hugePoints));
        Assert.Equal(ImageMarkupDocument.MaxStrokePoints, doc.Strokes[0].Points.Count);

        // Pin add, update, remove renumbers 1..N.
        var p1 = doc.AddPin(new(0.1, 0.2), ImageMarkupColor.Red, "  Fix sky  ");
        var p2 = doc.AddPin(new(0.5, 0.5), ImageMarkupColor.Green, "Brighten tree");
        var p3 = doc.AddPin(new(0.8, 0.8), ImageMarkupColor.Yellow, "Remove sign");
        Assert.Equal([1, 2, 3], doc.Pins.Select(p => p.Number).ToArray());
        Assert.Equal("Fix sky", doc.Pins[0].Note);

        doc.UpdatePin(p2.Id, "Warm up foliage");
        Assert.Equal("Warm up foliage", doc.Pins[1].Note);

        doc.RemovePin(p1.Id);
        Assert.Equal([1, 2], doc.Pins.Select(p => p.Number).ToArray());
        Assert.Equal("Warm up foliage", doc.Pins[0].Note);
        Assert.Equal("Remove sign", doc.Pins[1].Note);

        // Clear + Undo restores everything.
        doc.Clear();
        Assert.True(doc.IsEmpty);
        Assert.True(doc.Undo());
        Assert.Equal(1, doc.Strokes.Count);
        Assert.Equal(2, doc.Pins.Count);
        Assert.True(doc.CanRedo);

        // New edit clears redo stack.
        doc.AddPin(new(0.3, 0.3), ImageMarkupColor.White, "Extra");
        Assert.False(doc.CanRedo);

        // 50-step MaxHistory cap.
        var historyDoc = new ImageMarkupDocument();
        for (var i = 0; i < ImageMarkupDocument.MaxHistory + 15; i++)
            historyDoc.AddStroke(new ImageMarkupStroke(ImageMarkupTool.Pen, ImageMarkupColor.Red, 0.01, [new(0.1, 0.1)]));
        Assert.Equal(ImageMarkupDocument.MaxHistory + 15, historyDoc.Strokes.Count);

        var undoCount = 0;
        while (historyDoc.Undo()) undoCount++;
        Assert.Equal(ImageMarkupDocument.MaxHistory, undoCount);
        Assert.Equal(15, historyDoc.Strokes.Count);

        var redoCount = 0;
        while (historyDoc.Redo()) redoCount++;
        Assert.Equal(ImageMarkupDocument.MaxHistory, redoCount);
        Assert.Equal(ImageMarkupDocument.MaxHistory + 15, historyDoc.Strokes.Count);
    }

    [Fact]
    public void MarkupPromptComposesNotePinsAndEmptyStatesCleanly()
    {
        Assert.Equal("", ImageMarkupPrompt.Compose("   ", [], hasMarks: false));
        Assert.Equal("Please edit this image: Make it warmer", ImageMarkupPrompt.Compose("Make it warmer", [], hasMarks: false));
        Assert.Equal("Please edit the marked-up areas of this image.", ImageMarkupPrompt.Compose("", [], hasMarks: true));

        var pins = new List<ImageMarkupPin>
        {
            new("b", 2, new(0.6, 0.6), ImageMarkupColor.Blue, "Replace\nwith\r\nblue sky"),
            new("a", 1, new(0.2, 0.2), ImageMarkupColor.Red, "  Remove pole  "),
            new("c", 3, new(0.9, 0.9), ImageMarkupColor.Yellow, "   "),
        };

        var composed = ImageMarkupPrompt.Compose("Keep shadows natural", pins, hasMarks: true);
        Assert.Equal(
            "Please edit the marked-up areas of this image: Keep shadows natural\n1. Remove pole\n2. Replace with blue sky",
            composed);

        var pinsOnly = ImageMarkupPrompt.Compose("", pins, hasMarks: true);
        Assert.Equal(
            "Please edit the marked-up areas of this image:\n1. Remove pole\n2. Replace with blue sky",
            pinsOnly);
    }

    // =========================================================================
    // MARK: ClarifySettled Calm Chat Readability
    // =========================================================================

    private static ChatMessage UserMsg(string text, string id = "u", ChatSender? sender = null) =>
        new(id, Role.User, [new TextPart(text)]) { Sender = sender };

    private static ChatMessage AssistantMsg(string id, params ChatPart[] parts) =>
        new(id, Role.Assistant, parts);

    private static ToolCall ClarifyCall(string question, string? answer, string status, string callId = "c1")
    {
        var result = new JsonObject
        {
            ["responses"] = new JsonArray(new JsonObject
            {
                ["question"] = question,
                ["user_response"] = answer,
                ["status"] = status,
                ["choices_offered"] = new JsonArray("Yes", "No"),
            }),
        }.ToJsonString();
        return new ToolCall(callId, "clarify", null, null, ToolState.Done, ResultText: result);
    }

    [Fact]
    public void IsNormalHumanTurnFiltersSyntheticMarkersAndBotDeliveries()
    {
        Assert.True(ClarifyLate.IsNormalHumanTurn(UserMsg("Looks great, ship it.")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(AssistantMsg("a1", new TextPart("Hi"))));
        Assert.False(ClarifyLate.IsNormalHumanTurn(new ChatMessage("s1", Role.System, [new TextPart("Model changed")])));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("Hi", sender: new ChatSender("bot", "Ivy", null, "ivy", null))));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Hermes HQ draft d-12345678: send]\nSend this")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Hermes HQ ask a-12345678: 1]\nYes.")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Hermes HQ question q-12345678: answer]\nMy answer")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Hermes HQ order o-12345678: pay]\nPay now")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Hermes HQ travel flights: pick]\nPick flight")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("Message from 🤖 Ops: done")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("Prefix [INTERNAL NOTIFICATION] body")));
        Assert.False(ClarifyLate.IsNormalHumanTurn(UserMsg("[Cronjob \"Daily Digest\"] summary")));
    }

    [Fact]
    public void UnansweredClarifyCardBecomesStaleAndFoldedAfterLaterHumanTurnOrClarify()
    {
        var call = ClarifyCall("Deploy to prod?", null, "unanswered");
        var reply = AssistantMsg("a1", new ToolPart(call));
        var activeHistory = new List<ChatMessage> { UserMsg("Deploy", "u1"), reply };

        Assert.False(ClarifyLate.HasLaterHumanTurn("a1", activeHistory));
        var activeCard = SettledClarify.Card(call, reply, activeHistory)!;
        Assert.True(activeCard.Answerable);
        Assert.False(activeCard.StaleUnanswered);
        Assert.False(activeCard.Folded);

        // System notice or synthetic marker does not make it stale.
        var withNotice = new List<ChatMessage>(activeHistory)
        {
            new("sys", Role.System, [new TextPart("Model changed")]),
        };
        Assert.False(ClarifyLate.HasLaterHumanTurn("a1", withNotice));

        // Later normal human turn makes unanswered card stale & folded and drops Answer Now.
        var movedOn = new List<ChatMessage>(activeHistory)
        {
            UserMsg("Actually never mind, let's work on tests instead.", "u2"),
        };
        Assert.True(ClarifyLate.HasLaterHumanTurn("a1", movedOn));
        var staleCard = SettledClarify.Card(call, reply, movedOn)!;
        Assert.False(staleCard.Answerable);
        Assert.True(staleCard.StaleUnanswered);
        Assert.True(staleCard.Folded);

        // A later clarify call also makes the earlier unanswered card stale.
        var laterClarify = AssistantMsg("a2", new ToolPart(ClarifyCall("Which tests?", null, "unanswered", "c2")));
        var withLaterClarify = new List<ChatMessage>(activeHistory) { laterClarify };
        Assert.True(ClarifyLate.HasLaterHumanTurn("a1", withLaterClarify));
    }

    [Fact]
    public void AnsweredClarifyCardStaysOpenInSameTurnAndFoldsAfterNextHumanTurn()
    {
        var call = ClarifyCall("Which target?", "Windows", "answered");
        var reply = AssistantMsg("a1", new ToolPart(call), new TextPart("Building for Windows."));
        var sameTurn = new List<ChatMessage>
        {
            UserMsg("Build it", "u1"),
            reply,
            AssistantMsg("a2", new TextPart("Done building.")),
        };

        Assert.False(ClarifyLate.HasMovedPastTurn("a1", sameTurn));
        var openCard = SettledClarify.Card(call, reply, sameTurn)!;
        Assert.False(openCard.Folded);
        Assert.False(openCard.StaleUnanswered);
        Assert.False(openCard.Answerable);

        // Once user sends a new normal turn, answered card folds calmly.
        var nextTurn = new List<ChatMessage>(sameTurn)
        {
            UserMsg("Now package the installer.", "u2"),
        };
        Assert.True(ClarifyLate.HasMovedPastTurn("a1", nextTurn));
        var foldedCard = SettledClarify.Card(call, reply, nextTurn)!;
        Assert.True(foldedCard.Folded);
        Assert.False(foldedCard.StaleUnanswered);

        // Queued answer (int.MaxValue) never folds yet.
        Assert.False(ClarifyLate.HasMovedPastTurn("a1", nextTurn, answeredAt: int.MaxValue));
    }

    [Fact]
    public void DetectsAdjacentAnswerEchoAcrossSystemNoticesAndComputesReach()
    {
        var call = ClarifyCall("Which branch?", null, "unanswered");
        var key = ClarifyLate.Key(["Which branch?"]);
        var lateText = ClarifyLate.Message(key, [("Which branch?", "main")]);

        var history = new List<ChatMessage>
        {
            UserMsg("Merge it", "u1"),
            AssistantMsg("a1", new ToolPart(call)),
            new("sys1", Role.System, [new TextPart("Model changed")]),
            UserMsg(lateText, "u2"),
        };

        Assert.True(ClarifyLate.IsAdjacentAnswerEcho(history, 3, key));
        Assert.False(ClarifyLate.IsAdjacentAnswerEcho(history, 3, "q-00000000"));
        Assert.False(ClarifyLate.IsAdjacentAnswerEcho(history, 0, key));
        Assert.False(ClarifyLate.IsAdjacentAnswerEcho(history, 99, key));

        // Intervening user message breaks adjacency.
        var nonAdjacent = new List<ChatMessage>
        {
            UserMsg("Merge it", "u1"),
            AssistantMsg("a1", new ToolPart(call)),
            UserMsg("Wait a second", "u2"),
            UserMsg(lateText, "u3"),
        };
        Assert.False(ClarifyLate.IsAdjacentAnswerEcho(nonAdjacent, 3, key));

        // Reach looks back to the earlier settled clarify card when a later human turn or answer arrives.
        Assert.Equal(1, ClarifyLate.Reach(3, 0, history));
        Assert.Equal(1, ClarifyLate.Reach(2, 0, nonAdjacent));
    }
}
