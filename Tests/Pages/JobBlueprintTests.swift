// [jobs] Job templates (docs/spec/3x-jobs.md §6.6): first values, example defaults, option labels, hints, error
// cleaning and a malformed catalog.

import Foundation
import Testing
@testable import HermesHQNative

struct JobBlueprintTests {
    nonisolated static let catalog: JSONValue = ["blueprints": [
        ["key": "morning-brief", "title": "Morning briefing", "description": "A short daily briefing.", "fields": [
            ["name": "time", "type": "time", "label": "What time?", "default": "08:00", "help": "24h local time, e.g. 08:00"],
            ["name": "deliver", "type": "enum", "label": "Where to deliver?", "default": "origin", "options": ["origin", "local", "telegram"], "strict": false],
        ]],
        ["key": "price-watch", "title": "Price & availability watch", "fields": [
            ["name": "item", "type": "text", "label": "What exactly to watch?", "default": "a product URL or exact flight/hotel/listing description",
             "help": "URL or precise description — variant, dates, seller"],
            ["name": "condition", "type": "text", "label": "Alert me when…", "default": "the all-in price drops below my target"],
            ["name": "interval_h", "type": "enum", "label": "How often?", "default": "6", "options": ["1", "3", "6", "12", "24"],
             "help": "hours between checks — be gentle with rate limits"],
            ["name": "note", "type": "text", "optional": true],
        ]],
    ]]

    @Test func decodesTheCatalog() {
        let list = Blueprint.list(Self.catalog)
        #expect(list.map(\.key) == ["morning-brief", "price-watch"])
        #expect(list[0].fields.map(\.name) == ["time", "deliver"])
        #expect(list[0].fields[1].strict == false && list[0].fields[0].strict)
        #expect(list[1].fields[3].optional && list[1].fields[3].title == "Note")
    }

    @Test func aMalformedCatalogIsNeverFatal() {
        let odd: JSONValue = ["blueprints": [
            "junk", 7, ["title": "no key"], ["key": ""], ["key": "bare"], ["key": "bare", "title": "twice"],
            ["key": "a/b", "title": "مرحبا", "fields": "nope"],
            ["key": "fields", "fields": [["label": "no name"], ["name": "x"], ["name": "x"], 3, ["name": "pick", "type": "enum"],
                                         ["name": "odd", "type": "colour", "default": 4]]],
        ]]
        let list = Blueprint.list(odd)
        #expect(list.map(\.key) == ["bare", "a/b", "fields"])
        #expect(list[0].title == "Bare" && list[0].fields.isEmpty)
        #expect(list[1].title == "مرحبا" && list[1].fields.isEmpty)
        #expect(list[2].fields.map(\.name) == ["x", "pick", "odd"])
        #expect(JobBlueprints.control(list[2].fields[1]) == .text, "a choice without choices is asked as text")
        #expect(JobBlueprints.control(list[2].fields[2]) == .text, "an unknown type is asked as text")
        #expect(Blueprint.list(.null).isEmpty && Blueprint.list(["blueprints": "x"]).isEmpty)
    }

    @Test func firstValues() {
        let list = Blueprint.list(Self.catalog)
        #expect(JobBlueprints.initialValues(list[0]) == ["time": "08:00", "deliver": "local"])
        let watch = JobBlueprints.initialValues(list[1])
        #expect(watch["item"] == "", "an example default starts empty")
        #expect(watch["condition"] == "the all-in price drops below my target")
        #expect(watch["interval_h"] == "6" && watch["note"] == "")
    }

    @Test func exampleDefaults() {
        func field(_ value: String, type: String = "text") -> BlueprintField { BlueprintField(name: "f", type: type, defaultValue: value) }
        #expect(JobBlueprints.isExampleDefault(field("a product URL or exact flight/hotel/listing description")))
        #expect(JobBlueprints.isExampleDefault(field("a book or a course, anything")))
        #expect(JobBlueprints.isExampleDefault(field("Two or three topics, comma separated")))
        #expect(JobBlueprints.isExampleDefault(field("some keywords, like this")))
        #expect(!JobBlueprints.isExampleDefault(field("take a break and stretch")))
        #expect(!JobBlueprints.isExampleDefault(field("Spanish vocabulary")))
        #expect(!JobBlueprints.isExampleDefault(field("a or b", type: "enum")))
    }

    @Test func optionLabels() {
        let recurrence = BlueprintField(name: "recurrence", type: "weekdays")
        #expect(["everyday", "weekdays", "weekends"].map { JobBlueprints.optionLabel(recurrence, $0) } == ["Every day", "Weekdays", "Weekends"])
        let day = BlueprintField(name: "day", type: "enum")
        #expect(JobBlueprints.optionLabel(day, "sunday") == "Sunday")
        let hour = BlueprintField(name: "start_hour", type: "enum")
        #expect(["0", "7", "12", "17", "23"].map { JobBlueprints.optionLabel(hour, $0) } == ["12 AM", "7 AM", "12 PM", "5 PM", "11 PM"])
        #expect(JobBlueprints.optionLabel(hour, "24") == "24")
        let minutes = BlueprintField(name: "interval_min", type: "enum")
        #expect(["30", "60", "90"].map { JobBlueprints.optionLabel(minutes, $0) } == ["Every 30 minutes", "Every hour", "Every 90 minutes"])
        #expect(JobBlueprints.optionLabel(BlueprintField(name: "interval_minutes"), "15") == "Every 15 minutes")
        let hours = BlueprintField(name: "interval_h", type: "enum")
        #expect(["1", "6", "24"].map { JobBlueprints.optionLabel(hours, $0) } == ["Every hour", "Every 6 hours", "Once a day"])
        #expect(JobBlueprints.optionLabel(BlueprintField(name: "interval_hours"), "2") == "Every 2 hours")
        #expect(JobBlueprints.optionLabel(BlueprintField(name: "tone"), "friendly") == "Friendly")
        #expect(JobBlueprints.optionLabel(BlueprintField(name: "count"), "3") == "3")
    }

    @Test func fieldHelpAndPlaceholder() {
        let list = Blueprint.list(Self.catalog)
        #expect(JobBlueprints.fieldHelp(list[0].fields[0]) == "Times follow the clock on the computer running Hermes.")
        #expect(JobBlueprints.fieldHelp(list[0].fields[1]) == nil, "the deliver slot's rows explain themselves")
        #expect(JobBlueprints.fieldHelp(list[1].fields[0]) == nil, "a text field's hint is its placeholder")
        #expect(JobBlueprints.fieldHelp(list[1].fields[2]) == "Hours between checks — be gentle with rate limits")
        #expect(JobBlueprints.fieldHelp(BlueprintField(name: "start_hour", type: "enum", options: ["7"], help: "first hour of the active window (24h)"))
                == "First hour of the active window")
        #expect(JobBlueprints.placeholder(list[1].fields[0]) == "URL or precise description — variant, dates, seller")
        #expect(JobBlueprints.placeholder(list[1].fields[1]) == "Alert me when…")
    }

    @Test func fieldErrors() {
        let brief = Blueprint.list(Self.catalog)[0]
        #expect(JobBlueprints.cleanFieldError("422: missing required value: time (What time?)") == "missing required value: time (What time?)")
        #expect(JobBlueprints.cleanFieldError("invalid time '25:00' — use HH:MM (24h)") == "invalid time '25:00' — use HH:MM (24h)")
        #expect(JobBlueprints.fieldNamed(in: "missing required value: time (What time?)", of: brief) == "time")
        #expect(JobBlueprints.fieldNamed(in: "invalid time '25:00' — use HH:MM (24h)", of: brief) == "time")
        #expect(JobBlueprints.fieldNamed(in: "deliver='fax' not allowed — one of origin, local", of: brief) == "deliver")
        #expect(JobBlueprints.fieldNamed(in: "The provider refused the request.", of: brief) == nil)
        #expect(JobBlueprints.fieldNamed(in: "missing required value: nope (x)", of: brief) == nil)
    }

    @Test func timesAndCompleteness() {
        #expect(JobBlueprints.time("08:15").map { [$0.hour, $0.minute] } == [8, 15])
        #expect(JobBlueprints.time("8:05").map { [$0.hour, $0.minute] } == [8, 5])
        #expect(JobBlueprints.time("25:00") == nil && JobBlueprints.time("") == nil && JobBlueprints.time("soon") == nil)
        #expect(JobBlueprints.timeValue(hour: 7, minute: 5) == "07:05")
        let watch = Blueprint.list(Self.catalog)[1]
        #expect(JobBlueprints.isIncomplete(watch, JobBlueprints.initialValues(watch)), "the example default left its field blank")
        var values = JobBlueprints.initialValues(watch)
        values["item"] = "PS5 at example.com"
        #expect(!JobBlueprints.isIncomplete(watch, values), "an optional blank does not block")
        #expect(JobBlueprints.matches(watch, "price") && JobBlueprints.matches(watch, "") && !JobBlueprints.matches(watch, "habit"))
    }
}
