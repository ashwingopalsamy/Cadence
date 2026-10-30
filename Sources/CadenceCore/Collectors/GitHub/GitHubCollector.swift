import Foundation

/// The built-in GitHub collector (docs/SPEC.md section 10.3). It asks `gh api graphql` for the viewer's pull
/// request contributions, review contributions and merged pull requests, and renders one `envelope/1`.
///
/// Nothing is written until every page has arrived, so any failure leaves stdout empty. Pull request bodies are
/// read in memory for the AI marker check and dropped; the author login of a reviewed pull request is used to skip
/// your own pull requests and is never emitted.
public struct GitHubCollector: Sendable {
    public let name: String
    private let graphql: GitHubGraphQL
    private let config: Config
    private let clock: any Clock
    private let random: any RandomSource

    /// Pages fetched per query before giving up (100 items each).
    static let maxPages = 100

    public init(
        name: String = "github", gh: String, runner: any ProcessRunner, environment: [String: String],
        workingDirectory: URL, config: Config, clock: any Clock, random: any RandomSource = SystemRandomSource()
    ) {
        self.name = name
        self.graphql = GitHubGraphQL(runner: runner, gh: gh, environment: environment, workingDirectory: workingDirectory)
        self.config = config
        self.clock = clock
        self.random = random
    }

    /// The envelope for `since`..`until`, each a day (`YYYY-MM-DD`, in the profile zone) or an RFC 3339 time.
    /// A day as `until` includes that whole day.
    public func envelope(since: String, until: String) throws(CadenceError) -> [UInt8] {
        guard Actor.isValidName(name) else { throw .validation("--name: '\(name)' is not a valid collector name") }
        guard let zone = TimeZone(identifier: config.profile.timezone) else {
            throw .validation("config: profile.timezone '\(config.profile.timezone)' is not a time zone")
        }
        let boundary = config.dayBoundary
        let from = try Self.instant(since, edge: "--since", start: true, boundary: boundary, zone: zone)
        let to = try Self.instant(until, edge: "--until", start: false, boundary: boundary, zone: zone)
        guard from < to else { throw .validation("--since must be before --until") }

        let mine = try fetchContributions(from: from, to: to)
        let merged = try fetchMerged(login: mine.login, from: from, to: to)

        var items: [(Date, String, JSONValue)] = []
        var opened: Set<String> = []
        for pr in mine.opened where opened.insert(pr.id).inserted {
            guard let at = pr.time else { continue }
            var attrs = pr.baseAttrs(ai: hasAIMarker(pr.body))
            attrs["draft"] = .bool(pr.isDraft)
            items.append((at, "github:\(pr.id):opened", item(
                ref: "github:\(pr.id):opened", kind: "pr.opened", at: at, pr: pr, attrs: attrs, zone: zone)))
        }
        var mergedSeen: Set<String> = []
        for pr in merged where mergedSeen.insert(pr.id).inserted {
            guard let at = pr.time, at >= from, at < to else { continue }
            items.append((at, "github:\(pr.id):merged", item(
                ref: "github:\(pr.id):merged", kind: "pr.merged", at: at, pr: pr,
                attrs: pr.baseAttrs(ai: hasAIMarker(pr.body)), zone: zone)))
        }
        for group in groupReviews(mine.reviews, login: mine.login, zone: zone, boundary: boundary) {
            let ref = "github:review:\(group.pr.id):\(group.day)"
            var attrs = group.pr.baseAttrs(ai: nil)
            attrs["additions"] = nil
            attrs["deletions"] = nil
            attrs["reviews"] = .int(Int64(group.count))
            attrs["comments"] = .int(group.comments)
            if let state = group.lastState { attrs["state"] = .string(state) }
            items.append((group.first, ref, item(ref: ref, kind: "review.given", at: group.first, pr: group.pr, attrs: attrs, zone: zone)))
        }
        items.sort { ($0.0, $0.1) < ($1.0, $1.1) }

        let now = clock.now()
        let header: JSONValue = [
            "cadence": "envelope/1", "collector": .string(name),
            "run": .string(ULIDGenerator(clock: clock, random: random).next()),
            "generated_at": .string(Timestamp.local(now, in: zone)),
            "window": ["since": .string(since), "until": .string(until)],
        ]
        var lines = [header]
        lines.append(contentsOf: items.map(\.2))
        var out: [UInt8] = []
        do {
            for line in lines {
                out.append(contentsOf: try CanonicalJSON.bytes(line))
                out.append(0x0A)
            }
        } catch {
            throw .io("cannot encode the envelope")
        }
        return out
    }

    // MARK: - Window

    private static func instant(
        _ text: String, edge: String, start: Bool, boundary: DayBoundary, zone: TimeZone
    ) throws(CadenceError) -> Date {
        if let day = LocalDate(text) {
            let interval = boundary.interval(of: day, in: zone)
            return start ? interval.start : interval.end
        }
        if let date = Timestamp.parse(text) { return date }
        throw .validation("\(edge): '\(text)' is not a day (YYYY-MM-DD) or an RFC 3339 time")
    }

    // MARK: - Fetching

    private struct PR {
        var id: String
        var number: Int64?
        var title: String
        var url: String?
        var repo: String?
        var isDraft = false
        var time: Date?
        var additions: Int64?
        var deletions: Int64?
        var body = ""

        func baseAttrs(ai: Bool?) -> [String: JSONValue] {
            var attrs: [String: JSONValue] = [:]
            if let repo { attrs["repo"] = .string(repo) }
            if let number { attrs["number"] = .int(number) }
            if let additions { attrs["additions"] = .int(additions) }
            if let deletions { attrs["deletions"] = .int(deletions) }
            if let ai { attrs["ai_assisted"] = .bool(ai) }
            return attrs
        }
    }

    private struct Review {
        var id: String
        var state: String?
        var submitted: Date
        var comments: Int64
        var pr: PR
        var authorLogin: String?
    }

    private struct Contributions {
        var login = ""
        var opened: [PR] = []
        var reviews: [Review] = []
    }

    private static func pr(_ node: JSONValue?, timeKey: String) -> PR? {
        guard let node, let id = node["id"]?.stringValue, !id.isEmpty, let title = node["title"]?.stringValue else { return nil }
        var pr = PR(id: id, number: node["number"]?.intValue, title: title, url: node["url"]?.stringValue,
                    repo: node["repository"]?["nameWithOwner"]?.stringValue)
        pr.isDraft = node["isDraft"]?.boolValue ?? false
        pr.time = node[timeKey]?.stringValue.flatMap { Timestamp.parse($0) }
        pr.additions = node["additions"]?.intValue
        pr.deletions = node["deletions"]?.intValue
        pr.body = node["bodyText"]?.stringValue ?? ""
        return pr
    }

    private func fetchContributions(from: Date, to: Date) throws(CadenceError) -> Contributions {
        var result = Contributions()
        var prsCursor: String?
        var reviewsCursor: String?
        var prsDone = false
        var reviewsDone = false
        var seenReviews: Set<String> = []
        var pages = 0
        while !(prsDone && reviewsDone) {
            pages += 1
            guard pages <= Self.maxPages else { throw .io("GitHub returned more than \(Self.maxPages) pages; narrow the window") }
            var variables = [("from", Timestamp.utc(from)), ("to", Timestamp.utc(to))]
            if let prsCursor { variables.append(("prs", prsCursor)) }
            if let reviewsCursor { variables.append(("reviews", reviewsCursor)) }
            let root = try graphql.call(GitHubQueries.contributions, variables: variables)
            guard let viewer = root["data"]?["viewer"], let login = viewer["login"]?.stringValue else {
                throw .io("gh output has no viewer login")
            }
            guard login.range(of: #"^[A-Za-z0-9_\[\]-]+$"#, options: .regularExpression) != nil else {
                throw .io("gh returned a login Cadence cannot use in a search")
            }
            result.login = login
            guard let collection = viewer["contributionsCollection"] else { throw .io("gh output has no contributions") }

            if !prsDone {
                let page = collection["pullRequestContributions"]
                for node in page?["nodes"]?.arrayValue ?? [] {
                    if let pr = Self.pr(node["pullRequest"], timeKey: "createdAt") { result.opened.append(pr) }
                }
                (prsDone, prsCursor) = try Self.next(page)
            }
            if !reviewsDone {
                let page = collection["pullRequestReviewContributions"]
                for node in page?["nodes"]?.arrayValue ?? [] {
                    guard let review = node["pullRequestReview"], let reviewID = review["id"]?.stringValue,
                        let submitted = review["submittedAt"]?.stringValue.flatMap({ Timestamp.parse($0) }),
                        let pr = Self.pr(node["pullRequest"], timeKey: "")
                    else { continue }
                    guard seenReviews.insert(reviewID).inserted else { continue }
                    result.reviews.append(Review(
                        id: reviewID, state: review["state"]?.stringValue, submitted: submitted,
                        comments: review["comments"]?["totalCount"]?.intValue ?? 0, pr: pr,
                        authorLogin: node["pullRequest"]?["author"]?["login"]?.stringValue))
                }
                (reviewsDone, reviewsCursor) = try Self.next(page)
            }
        }
        return result
    }

    private func fetchMerged(login: String, from: Date, to: Date) throws(CadenceError) -> [PR] {
        // GitHub's merged: qualifier works on UTC days, so the range is padded by a day each side and the
        // exact window is applied to mergedAt afterwards.
        let first = Timestamp.utc(from.addingTimeInterval(-86_400)).prefix(10)
        let last = Timestamp.utc(to.addingTimeInterval(86_400)).prefix(10)
        let query = "is:pr author:\(login) merged:\(first)..\(last)"
        var found: [PR] = []
        var cursor: String?
        var pages = 0
        while true {
            pages += 1
            guard pages <= Self.maxPages else { throw .io("GitHub returned more than \(Self.maxPages) pages; narrow the window") }
            var variables = [("q", query)]
            if let cursor { variables.append(("cursor", cursor)) }
            let root = try graphql.call(GitHubQueries.mergedSearch, variables: variables)
            guard let search = root["data"]?["search"] else { throw .io("gh output has no search result") }
            for node in search["nodes"]?.arrayValue ?? [] {
                if let pr = Self.pr(node, timeKey: "mergedAt") { found.append(pr) }
            }
            let (done, next) = try Self.next(search)
            if done { return found }
            cursor = next
        }
    }

    /// Whether a connection has no further page, and the cursor to ask for the next one.
    private static func next(_ page: JSONValue?) throws(CadenceError) -> (done: Bool, cursor: String?) {
        let info = page?["pageInfo"]
        guard info?["hasNextPage"]?.boolValue == true else { return (true, nil) }
        guard let cursor = info?["endCursor"]?.stringValue, !cursor.isEmpty else {
            throw .io("GitHub said there was another page but gave no cursor")
        }
        return (false, cursor)
    }

    // MARK: - Mapping

    private func hasAIMarker(_ body: String) -> Bool {
        let text = body.lowercased()
        return config.aiMarkers.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }

    private func item(ref: String, kind: String, at: Date, pr: PR, attrs: [String: JSONValue], zone: TimeZone) -> JSONValue {
        var record: [String: JSONValue] = [
            "type": "item", "source_ref": .string(ref), "kind": .string(kind),
            "occurred_at": .string(Timestamp.local(at, in: zone)), "title": .string(pr.title),
            "attrs": .object(attrs),
        ]
        if let url = pr.url { record["links"] = [["kind": "pr", "url": .string(url)]] }
        return .object(record)
    }

    private struct ReviewGroup {
        var pr: PR
        var day: LocalDate
        var first: Date
        var last: Date
        var lastState: String?
        var count = 0
        var comments: Int64 = 0
    }

    /// One group per pull request per local day. Reviews on your own pull requests are dropped here.
    private func groupReviews(_ reviews: [Review], login: String, zone: TimeZone, boundary: DayBoundary) -> [ReviewGroup] {
        var groups: [String: ReviewGroup] = [:]
        for review in reviews.sorted(by: { ($0.submitted, $0.id) < ($1.submitted, $1.id) }) {
            if let author = review.authorLogin, author.lowercased() == login.lowercased() { continue }
            let day = boundary.day(of: review.submitted, in: zone)
            let key = "\(review.pr.id)|\(day)"
            var group = groups[key] ?? ReviewGroup(pr: review.pr, day: day, first: review.submitted, last: review.submitted)
            group.count += 1
            group.comments += review.comments
            group.last = review.submitted
            group.lastState = review.state
            groups[key] = group
        }
        return Array(groups.values)
    }
}
