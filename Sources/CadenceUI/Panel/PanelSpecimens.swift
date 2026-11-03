// The menu-bar panel in every row of its table (docs/SPEC.md section 4.2), from sample data with ACME titles only.
// Shared by `make token-sheet` and the snapshot suite, so both draw the same twelve panels.
import CadenceCore
import Foundation

public enum PanelSpecimens {
    public struct Sample: Sendable {
        public let name: String
        public let input: PanelInput
    }

    static let day = LocalDate(year: 2026, month: 10, day: 29)!

    static let titles = [
        "Ship the retry budget for the ACME capture path",
        "Review ACME-4821 webhook retry",
        "Write the ADR for proof export",
        "Pair on the ACME billing migration",
        "Draft the replay tool",
        "Follow up on the ACME alert",
        "Update the on-call runbook",
    ]

    static func tasks(_ statuses: [TaskStatus], origin: PlanOrigin = .selfReported) -> [PlanTask] {
        statuses.enumerated().map { index, status in
            PlanTask(
                id: "t\(index)", day: day.description, position: Int64(index), title: titles[index % titles.count],
                origin: origin, status: status, plannedAt: "2026-10-29T09:05:00+05:30")
        }
    }

    static func story(_ edit: (inout DayStory.Input) -> Void) -> DayStory {
        var input = DayStory.Input(date: day)
        input.countedWorkdays = 18
        input.usualByNow = 6...9
        edit(&input)
        return DayStory(input)
    }

    static func sample(_ name: String, _ story: DayStory, _ edit: (inout PanelInput) -> Void = { _ in }) -> Sample {
        var input = PanelInput(story: story, date: day)
        input.showsTempo = false
        edit(&input)
        return Sample(name: name, input: input)
    }

    public static var samples: [Sample] {
        let live: [TaskStatus] = [.done, .done, .open, .open, .open]
        return [
            sample("First run", story { $0.firstRun = true; $0.countedWorkdays = 0 }),
            sample("Morning, no plan", story { $0.carried = 2 }) {
                $0.carried = tasks([.open, .open], origin: .carried)
            },
            sample("Yesterday still open", story { $0.previous = .init(date: LocalDate(year: 2026, month: 10, day: 28)!, graceOpen: true, sealedBefore: 18) }) {
                $0.carried = tasks([.open, .open, .open], origin: .carried)
            },
            sample("In rhythm, a tick held for Undo", story { $0.planned = 7; $0.resolved = 2; $0.done = 2; $0.items = 8 }) {
                $0.plan = tasks([.done, .done, .open, .open, .open, .open, .open])
                $0.held = "t2"
                $0.items = 8
                $0.startedAt = "09:41"
            },
            sample("Wrap-up due", story { $0.wrapUpReminder = "17:30"; $0.planned = 5; $0.resolved = 3; $0.items = 9 }) {
                $0.plan = tasks([.done, .done, .dropped, .open, .open])
                $0.items = 9
                $0.startedAt = "09:41"
            },
            sample("Nothing logged by wrap-up", story { $0.wrapUpReminder = "17:30" }),
            sample("Sealed", story { $0.sealedAt = "18:12"; $0.planned = 5; $0.resolved = 5 }) {
                $0.plan = tasks([.done, .done, .done, .slipped, .done])
                $0.items = 8
                $0.sealedAt = "18:12"
            },
            sample("On leave", story { $0.dayOff = .leave }),
            sample("Capture paused", story { $0.paused = true; $0.planned = 5; $0.resolved = 2; $0.items = 7 }) {
                $0.plan = tasks(live)
                $0.items = 7
                $0.startedAt = "09:41"
                $0.pausedUntil = "15:00"
            },
            sample("A source is behind", story { $0.behind = .init(source: "GitHub", lastSync: "13:40"); $0.planned = 5; $0.items = 7 }) {
                $0.plan = tasks(live)
                $0.items = 7
                $0.startedAt = "09:41"
                $0.behind = .init(source: "GitHub", lastSync: "13:40")
            },
            sample("Store problem", story { $0.storeProblem = true }),
            sample("Discreet mode", story { $0.planned = 5; $0.resolved = 2; $0.items = 8 }) {
                $0.plan = tasks(live).enumerated().map { index, task in
                    var shown = task
                    shown.title = "Task \(index + 1)"
                    return shown
                }
                $0.items = 8
                $0.startedAt = "09:41"
            },
        ]
    }
}
