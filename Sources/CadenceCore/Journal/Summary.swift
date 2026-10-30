import Foundation

/// Which days `cadence summary` covers (docs/SPEC.md section 9.5).
public enum SummaryRange: Sendable, Equatable {
    case week, month, cycle
    case custom(LocalDate, LocalDate)

    /// "week", "month", "cycle" or "YYYY-MM-DD..YYYY-MM-DD".
    public static func parse(_ text: String) throws(CadenceError) -> SummaryRange {
        switch text {
        case "week": return .week
        case "month": return .month
        case "cycle": return .cycle
        default:
            let parts = text.components(separatedBy: "..")
            guard parts.count == 2, let a = LocalDate(parts[0]), let b = LocalDate(parts[1]) else {
                throw .validation("--range: '\(text)' is not valid; use week, month, cycle or YYYY-MM-DD..YYYY-MM-DD")
            }
            guard a <= b else { throw .validation("--range: the range starts after it ends") }
            return .custom(a, b)
        }
    }

    public var label: String {
        switch self {
        case .week: "week"
        case .month: "month"
        case .cycle: "cycle"
        case .custom(let a, let b): "\(a)..\(b)"
        }
    }

    /// The first and last day. Week is Monday to `today`, month is the 1st to `today`.
    ///
    /// Cycle is the review cycle: from `cycleStart` (config has no cycle field yet, so the journal passes
    /// `profile.backfillFrom`) to `today`. Without a usable start, or one after today, it is from the
    /// 1 October on or before `today`, the financial year start in docs/SPEC.md section 5.1.
    public func resolve(today: LocalDate, cycleStart: LocalDate?) -> (from: LocalDate, to: LocalDate) {
        switch self {
        case .week:
            let offset = Weekday.allCases.firstIndex(of: today.weekday) ?? 0  // Monday is index 0
            return (today.adding(days: -offset), today)
        case .month:
            return (LocalDate(year: today.year, month: today.month, day: 1) ?? today, today)
        case .cycle:
            if let start = cycleStart, start <= today { return (start, today) }
            let year = today.month >= 10 ? today.year : today.year - 1
            return (LocalDate(year: year, month: 10, day: 1) ?? today, today)
        case .custom(let a, let b):
            return (a, b)
        }
    }
}

/// When a day's first or last activity fell, over the days that have one.
public struct ClockSpread: Sendable, Equatable {
    public var median: String
    public var earliest: String
    public var latest: String
    public var days: Int

    var json: JSONValue {
        ["median": .string(median), "earliest": .string(earliest), "latest": .string(latest), "days": .int(Int64(days))]
    }
}

/// The numbers for a range (docs/SPEC.md sections 5, 9.5, 11 and 12.1). A metric with no data is nil, which
/// prints as "-" and encodes as null: unknown is not zero. Findings are phase 4 and not computed here.
public struct Summary: Sendable, Equatable {
    public var label: String
    public var from: LocalDate
    public var to: LocalDate
    public var zone: String
    /// Workdays in the range by the configured workdays and declarations, whatever their state.
    public var workdays: Int

    public var sealedWorkdays: Int?
    /// Workdays whose outcome is final and that began after the ledger did.
    public var countedWorkdays: Int
    public var beforeLedger: Int

    public var planDone: Int?
    public var planTotal: Int?
    /// Slipped tasks by reason; nil when the range has no plan.
    public var slipsByReason: [String: Int]?

    public var mergedPRs: Int?
    public var assignedPRs: Int?
    public var selfInitiatedPRs: Int?
    public var reviews: Int?
    public var entries: Int?
    public var entriesByFamily: [String: Int]?

    public var firstActivity: ClockSpread?
    public var lastActivity: ClockSpread?

    public var aiDays: Int?
    public var aiCountedDays: Int
    public var aiSessions: Int?
    /// Output tokens by the daily pick (endpoint, then transcripts, then import; never summed across sources).
    public var outputTokens: Int?
    /// Days each source supplied the pick.
    public var tokenSources: [String: Int]
    /// Merged PRs with an AI marker, out of merged PRs whose marker was recorded (docs/SPEC.md section 11.1).
    public var assistedMerges: AssistedMerges? = nil
    /// Accepted entries with origin agent.
    public var agentEntries: Int? = nil
    /// Median Claude Code session length; nil when no session has both a start and an end.
    public var sessionLength: SessionLength? = nil
    public var cacheReuse: CacheReuse? = nil
    public var modelMix: ModelMix? = nil

    public var streak: Streak

    /// "The sentence your review needs", written only from the figures above. Nil when none is known.
    public var reviewSentence: String? {
        ReviewSentence.make(
            aiDays: aiDays.map { Share($0, of: aiCountedDays) }, assisted: assistedMerges, agentEntries: agentEntries)
    }

    static let definitions: [String: String] = [
        "sealed_workdays": "Workdays wrapped up by 23:59 the next day, counted from the day the ledger began; leave and holidays excluded, days still inside that window not counted yet, and workdays before the ledger began reported as before_ledger",
        "plan_done": "Planned tasks on counted workdays marked done by the end of their day; tasks moved to another day count on that day",
        "merged_prs": "Merged PRs authored, from the GitHub collector; assigned and self-initiated by ticket, the rest have no ticket",
        "reviews": "Review entries, one per PR per day",
        "ai_days": "Counted workdays with an AI coding session or usage record, from the first day any AI source recorded",
        "output_tokens": "Output tokens, one source per day by priority (endpoint, transcripts, import), never summed across sources",
        "ai_assisted_merges": "Merged PRs whose body carried an AI marker when the GitHub collector read it, out of merged PRs with a recorded marker; PRs with no recorded marker are in neither number and are counted as unrecorded. A marker is text in the PR body, so it shows a claim, not proof of AI use",
        "agent_entries": "Accepted entries with origin agent; proposed, dismissed and deleted ones are not counted",
        "session_length": GenAIMetrics.sessionLengthDefinition,
        "cache_reuse": GenAIMetrics.cacheReuseDefinition,
        "model_mix": GenAIMetrics.modelMixDefinition,
        "review_sentence": ReviewSentence.definition,
    ]

    private static func number(_ value: Int?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }

    private static func counts(_ map: [String: Int]?) -> JSONValue {
        guard let map else { return .null }
        return .object(map.mapValues { .int(Int64($0)) })
    }

    public var json: JSONValue {
        let d = Self.definitions
        return [
            "range": [
                "label": .string(label), "from": .string(from.description), "to": .string(to.description),
                "tz": .string(zone), "workdays": .int(Int64(workdays)),
            ],
            "sealed_workdays": [
                "value": Self.number(sealedWorkdays), "of": .int(Int64(countedWorkdays)),
                "before_ledger": .int(Int64(beforeLedger)), "definition": .string(d["sealed_workdays"] ?? ""),
            ],
            "plan_done": [
                "value": Self.number(planDone), "of": Self.number(planTotal), "definition": .string(d["plan_done"] ?? ""),
                "slipped_by_reason": Self.counts(slipsByReason),
            ],
            "merged_prs": [
                "value": Self.number(mergedPRs), "assigned": Self.number(assignedPRs),
                "self_initiated": Self.number(selfInitiatedPRs), "definition": .string(d["merged_prs"] ?? ""),
            ],
            "reviews": ["value": Self.number(reviews), "definition": .string(d["reviews"] ?? "")],
            "entries": ["value": Self.number(entries), "by_family": Self.counts(entriesByFamily)],
            "presence": [
                "first_activity": firstActivity?.json ?? .null, "last_activity": lastActivity?.json ?? .null,
            ],
            "ai": [
                "days": ["value": Self.number(aiDays), "of": .int(Int64(aiCountedDays)), "definition": .string(d["ai_days"] ?? "")],
                "sessions": Self.number(aiSessions),
                "session_length": [
                    "median_seconds": Self.number(sessionLength?.medianSeconds),
                    // Sessions are known but none has an end: a measured count of 0, not an unknown one.
                    "measured": Self.number(aiSessions == nil ? nil : (sessionLength?.measured ?? 0)),
                    "of": Self.number(aiSessions), "definition": .string(d["session_length"] ?? ""),
                ],
                "assisted_merges": GenAIMetrics.assistedJSON(assistedMerges, definition: d["ai_assisted_merges"] ?? ""),
                "agent_entries": ["value": Self.number(agentEntries), "definition": .string(d["agent_entries"] ?? "")],
                "output_tokens": [
                    "value": Self.number(outputTokens), "sources": Self.counts(tokenSources.isEmpty ? nil : tokenSources),
                    "definition": .string(d["output_tokens"] ?? ""),
                ],
                "cache_reuse": [
                    "percent": Self.number(cacheReuse?.percent),
                    "cache_read_tokens": cacheReuse.map { .int($0.cacheRead) } ?? .null,
                    "input_tokens": cacheReuse.map { .int($0.input) } ?? .null,
                    "sources": Self.counts(cacheReuse?.sources), "definition": .string(d["cache_reuse"] ?? ""),
                ],
                "model_mix": [
                    "models": modelMix.map { mix in
                        .array(mix.models.map { share in
                            ["model": .string(share.model), "output_tokens": .int(share.outputTokens), "percent": Self.number(mix.percent(of: share))]
                        })
                    } ?? .null,
                    "total_output_tokens": modelMix.map { .int($0.totalOutputTokens) } ?? .null,
                    "sources": Self.counts(modelMix?.sources), "definition": .string(d["model_mix"] ?? ""),
                ],
            ],
            "review_sentence": [
                "text": reviewSentence.map { .string($0) } ?? .null, "definition": .string(d["review_sentence"] ?? ""),
            ],
            "streak": streak.json,
            // Findings come from the templates and thresholds of phase 4 (T4.x). Never invented here.
            "findings": [],
        ]
    }
}

extension Journal {
    static let maxSummaryDays = 1100

    /// The range a `SummaryRange` names today, read in the profile zone.
    public func summary(_ range: SummaryRange) throws(CadenceError) -> Summary {
        let bounds = range.resolve(today: today(), cycleStart: config.profile.backfillFrom)
        return try summary(from: bounds.from, to: bounds.to, label: range.label)
    }

    /// Metrics for `from` through `to`. Read-only. The definitions match the proof export's summary
    /// (`ProofExporter`), except that every accepted entry counts here, not only those a proof lists.
    public func summary(from: LocalDate, to: LocalDate, label: String? = nil) throws(CadenceError) -> Summary {
        guard from <= to else { throw .validation("the range starts after it ends") }
        guard from.days(until: to) < Self.maxSummaryDays else {
            throw .validation("a summary covers at most \(Self.maxSummaryDays) days; use a shorter range")
        }
        let rules = DayRules(config: config)
        let now = clock.now()
        let low = SQLValue.text(from.description)
        let high = SQLValue.text(to.description)
        let declared = try declaredKinds()

        var ledgerStart: LocalDate?
        if let genesis = try store.readEvents("SELECT * FROM events WHERE type = 'ledger.genesis' ORDER BY seq LIMIT 1", []).first,
            let at = Timestamp.parse(genesis.at)
        {
            ledgerStart = config.dayBoundary.day(of: at, in: zone)
        }

        var dayRows: [String: SQLRow] = [:]
        for row in try rows("SELECT * FROM days WHERE date >= ? AND date <= ?", [low, high]) {
            dayRows[row.text("date") ?? ""] = row
        }
        func dayZone(_ key: String) -> TimeZone {
            dayRows[key]?.text("tz").flatMap { TimeZone(identifier: $0) } ?? zone
        }

        // Workdays: sealed within grace, or unsealed with the grace window closed.
        var workdays = 0
        var beforeLedger = 0
        var sealedInGrace = 0
        var countable: [String] = []
        for date in LocalDate.range(from, through: to) {
            guard rules.kind(of: date, declared: declared[date]) == .workday else { continue }
            workdays += 1
            if let start = ledgerStart, date < start {
                beforeLedger += 1
                continue
            }
            let key = date.description
            let tz = dayZone(key)
            let sealedAt = dayRows[key]?.text("sealed_at").flatMap { Timestamp.parse($0) }
            let counts = sealedAt.map { rules.sealCounts($0, for: date, in: tz) } ?? false
            if counts || rules.graceClosed(for: date, at: now, in: tz) {
                countable.append(key)
                if counts { sealedInGrace += 1 }
            }
        }
        let countableSet = Set(countable)

        // Plan.
        let taskRows = try rows(
            "SELECT day, status, reason, resolved_at FROM plan_tasks WHERE day >= ? AND day <= ? AND status != 'moved'",
            [low, high])
        let counted = taskRows.filter { countableSet.contains($0.text("day") ?? "") }
        let done = counted.filter { row in
            guard row.text("status") == "done", let day = row.text("day").flatMap({ LocalDate($0) }),
                let at = row.text("resolved_at").flatMap({ Timestamp.parse($0) })
            else { return false }
            return config.dayBoundary.day(of: at, in: dayZone(day.description)) <= day
        }
        var slips: [String: Int] = [:]
        for row in counted where row.text("status") == "slipped" { slips[row.text("reason") ?? "unspecified", default: 0] += 1 }

        // Entries: every accepted entry in range.
        let entryRows = try rows(
            "SELECT kind, family, origin, source, ticket_class, attrs FROM entries WHERE status = 'accepted' AND day >= ? AND day <= ?",
            [low, high])
        // No entry in range means no record, which is not a count of zero.
        let entriesKnown = ledgerStart.map { to >= $0 } == true && !entryRows.isEmpty
        let githubSeen = try !rows("SELECT 1 AS n FROM entries WHERE source = 'github' AND status = 'accepted' LIMIT 1").isEmpty
        let merged = entryRows.filter {
            $0.text("kind") == EntryKind.prMerged.rawValue && $0.text("origin") == Origin.collected.rawValue
                && $0.text("source") == "github"
        }
        var byFamily = Dictionary(uniqueKeysWithValues: Family.allCases.map { ($0.rawValue, 0) })
        for row in entryRows { byFamily[row.text("family") ?? "", default: 0] += 1 }
        byFamily[""] = nil
        let prsKnown = githubSeen && entriesKnown

        // Presence.
        func spread(_ column: String) -> ClockSpread? {
            var minutes: [(Int, String)] = []
            for (key, row) in dayRows {
                guard let at = row.text(column).flatMap({ Timestamp.parse($0) }) else { continue }
                let clockText = Timestamp.clockTime(at, in: dayZone(key))
                let parts = clockText.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { minutes.append((parts[0] * 60 + parts[1], clockText)) }
            }
            guard !minutes.isEmpty else { return nil }
            minutes.sort { $0.0 < $1.0 }
            let mid = minutes.count / 2
            let median = minutes.count % 2 == 1 ? minutes[mid].0 : (minutes[mid - 1].0 + minutes[mid].0) / 2
            func text(_ m: Int) -> String { LocalDate.pad(m / 60, 2) + ":" + LocalDate.pad(m % 60, 2) }
            return ClockSpread(median: text(median), earliest: minutes[0].1, latest: minutes[minutes.count - 1].1, days: minutes.count)
        }

        // GenAI.
        var aiDays = Set<String>()
        for row in try rows(Self.aiDaysSQL) {
            if let day = row.text("day") { aiDays.insert(day) }
        }
        let firstAIDay = aiDays.min()
        let aiCountable = countable.filter { day in firstAIDay.map { day >= $0 } ?? false }
        let firstSessionDay = try rows("SELECT MIN(day) AS d FROM genai_sessions").first?.text("d")
        let sessionsKnown = firstSessionDay.map { $0 <= to.description } ?? false
        let sessionRows = try rows("SELECT started_at, ended_at FROM genai_sessions WHERE day >= ? AND day <= ?", [low, high])
        let sessionCount = sessionRows.count
        let sessionLength = sessionsKnown
            ? GenAIMetrics.sessionLength(sessionRows.map { (started: $0.text("started_at"), ended: $0.text("ended_at")) }) : nil
        // One source per day and tool (the daily pick), never summed across sources.
        var tokens: Int?
        var tokenDays: [String: Set<LocalDate>] = [:]
        let picks = try genaiDays(from: from, to: to)
        for pick in picks {
            // Unknown is not zero: a pick whose output tokens are unknown adds nothing.
            guard let out = pick.tokens.output else { continue }
            tokens = (tokens ?? 0) + Int(out)
            tokenDays[pick.source, default: []].insert(pick.day)
        }
        let tokenSources = tokenDays.mapValues(\.count)

        let streak = try self.streak(asOf: min(to, today()))
        return Summary(
            label: label ?? "\(from)..\(to)", from: from, to: to, zone: zone.identifier, workdays: workdays,
            sealedWorkdays: countable.isEmpty ? nil : sealedInGrace, countedWorkdays: countable.count,
            beforeLedger: beforeLedger,
            planDone: counted.isEmpty ? nil : done.count, planTotal: counted.isEmpty ? nil : counted.count,
            slipsByReason: counted.isEmpty ? nil : slips,
            mergedPRs: prsKnown ? merged.count : nil,
            assignedPRs: prsKnown ? merged.filter { $0.text("ticket_class") == TicketClass.assigned.rawValue }.count : nil,
            selfInitiatedPRs: prsKnown ? merged.filter { $0.text("ticket_class") == TicketClass.selfInitiated.rawValue }.count : nil,
            reviews: entriesKnown ? entryRows.filter { $0.text("kind") == EntryKind.reviewGiven.rawValue }.count : nil,
            entries: entriesKnown ? entryRows.count : nil, entriesByFamily: entriesKnown ? byFamily : nil,
            firstActivity: spread("first_activity"), lastActivity: spread("last_activity"),
            aiDays: aiCountable.isEmpty ? nil : aiCountable.filter(aiDays.contains).count, aiCountedDays: aiCountable.count,
            aiSessions: sessionsKnown ? sessionCount : nil, outputTokens: tokens, tokenSources: tokenSources,
            assistedMerges: prsKnown ? GenAIMetrics.assistedMerges(merged.map { GenAIMetrics.marker(inAttrs: $0.text("attrs")) }) : nil,
            agentEntries: entriesKnown ? entryRows.filter { $0.text("origin") == Origin.agent.rawValue }.count : nil,
            sessionLength: sessionLength, cacheReuse: GenAIMetrics.cacheReuse(picks), modelMix: GenAIMetrics.modelMix(picks),
            streak: streak)
    }
}

extension Journal {
    /// Days with AI use: a session, or a usage row with sessions, or with tokens when the source does not
    /// count sessions. The summary and the proof both read this, so they agree.
    static let aiDaysSQL = """
        SELECT DISTINCT day FROM genai_sessions UNION SELECT DISTINCT day FROM genai_usage
        WHERE sessions > 0 OR (sessions IS NULL AND (COALESCE(tokens_in, 0) > 0 OR COALESCE(tokens_out, 0) > 0
          OR COALESCE(tokens_cache_read, 0) > 0 OR COALESCE(tokens_cache_write, 0) > 0))
        """
}
