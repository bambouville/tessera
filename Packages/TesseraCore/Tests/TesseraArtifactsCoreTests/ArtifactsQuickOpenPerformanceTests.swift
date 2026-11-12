import XCTest
import TesseraDomainCore
@testable import TesseraArtifactsCore

final class ArtifactsQuickOpenPerformanceTests: XCTestCase {
    func testOneQueryFoldAndOnlyCompetitivePathsAreSearchedAfterEightMatches() {
        let tabs = (0..<64).reversed().map { index in
            ArtifactTab(id: "tab-\(index)", hostID: "h", hostLabel: "dev",
                target: .file(path: "/" + String(repeating: "x", count: 1_024) + "/\(index).md"),
                title: "needle \(index)", openedAt: Int64(index), viewedAt: Int64(index))
        }
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h", label: "dev")], currentHostID: "h", cwd: "/")
        for query in ["needle", "?needle"] {
            let work = ArtifactsQuickOpen.measure {
                ArtifactsQuickOpen.suggestions(query, state: .init(tabs: tabs), context: context, recents: [])
            }
            XCTAssertEqual(work.value.map(\.tabID), tabs.prefix(8).map { Optional($0.id) })
            XCTAssertEqual(work.folds, 9)
            let expectedBytes = "needle".utf8.count + tabs.prefix(8).reduce(0) { bytes, tab in
                bytes + "\(tab.title) \(tab.target.path) \(tab.hostLabel) \(tab.hostLabel):\(tab.target.path)".utf8.count
            }
            XCTAssertEqual(work.bytes, expectedBytes)
        }
    }

    func testBoundedSelectionMatchesStableFullSortWithoutRetainingAllCandidates() {
        var random = Generator()
        struct Candidate: Equatable { let id: Int; let rank: Int }
        let candidates = (0..<1_024).map { _ in Candidate(id: random.next(96), rank: random.next(32)) }
        for limit in [0, 1, 2, 8, 64] {
            var best = ArtifactsQuickOpenTopK<Candidate>(limit: limit)
            var comparisons = 0
            for value in candidates {
                best.insert(value, precedes: { comparisons += 1; return $0.rank > $1.rank },
                            duplicates: { $0.id == $1.id })
                XCTAssertLessThanOrEqual(best.values.count, limit)
            }
            var reference: [Candidate] = []
            for value in candidates.sorted(by: { $0.rank > $1.rank }) where !reference.contains(where: { $0.id == value.id }) {
                if reference.count < limit { reference.append(value) }
            }
            XCTAssertEqual(best.values, reference)
            XCTAssertLessThanOrEqual(comparisons, candidates.count * limit)
        }
    }

    func testSuggestionsEqualReferenceFullSortForRandomizedInputsAndLimits() {
        var random = Generator()
        let hosts: [ArtifactsQuickOpenHost] = [
            .init(id: "h0", label: "dev", home: "/work"),
            .init(id: "h1", label: "Résumé", home: "/home/user"),
            .init(id: "h2", label: "duplicate"), .init(id: "h3", label: "DUPLICATE"),
        ]
        let queries = ["", "  ", "?resume", "? café", "dev:/work/café.md", ":", ":5", ":5173/new?q=1#part",
                       "localhost", "localhost:8080/path", "https://localhost:8443/a%20b?q=é#frag",
                       "127.0.0.1:8080", "[::1]:3000", "résumé", "?dev", "?missing", "dev:", "duplicate:/x"]
        let paths = ["/work/café.md", "/work/cafe\u{301}.md", "/work/same.md", "/Résumé.md",
                     "/a%20b?q=1#part", "/work/dev:notes.txt", "/notes.md"]
        let titles = ["Résumé", "café", "same", "web", "notes", "DEV"]
        var forwardSuggestions = 0
        for iteration in 0..<100 {
            var tabs: [ArtifactTab] = []
            for _ in 0..<random.next(96) {
                let host = hosts[random.next(hosts.count)]
                let path = paths[random.next(paths.count)]
                let target: ArtifactsTarget
                switch random.next(3) {
                case 0: target = .file(path: path)
                case 1: target = .page(scheme: random.next(2) == 0 ? "http" : "https",
                                      port: [3_000, 5_173, 8_080, 8_443][random.next(4)], path: path)
                default: target = .change(path: path, diff: "+\(random.next(3))", summary: "edit")
                }
                tabs.append(.init(id: "tab-\(random.next(24))", hostID: host.id, hostLabel: host.label,
                                  target: target, title: titles[random.next(titles.count)],
                                  openedAt: Int64(random.next(6)), viewedAt: Int64(random.next(6))))
            }
            let ports = (0..<random.next(24)).map { _ in
                ArtifactsListeningPort(port: [3_000, 5_173, 5_174, 8_080, 8_443][random.next(5)],
                                       bindAddress: "127.0.0.1", process: titles[random.next(titles.count)])
            }
            var recents: [ArtifactsRecent] = []
            for _ in 0..<random.next(24) {
                let host = hosts[random.next(hosts.count)]
                let path = paths[random.next(paths.count)]
                let intent: ArtifactsQuickOpenIntent
                switch random.next(5) {
                case 0: intent = .file(hostID: host.id, path: path)
                case 1: intent = .directory(hostID: host.id, path: path)
                case 2: intent = .page(hostID: host.id, scheme: "http", port: 5_173, path: path)
                case 3: intent = .search(text: path)
                default: intent = .invalid(reason: .missingHost)
                }
                recents.append(.init(title: titles[random.next(titles.count)], subtitle: titles[random.next(titles.count)],
                                     intent: intent, viewedAt: Int64(random.next(4))))
            }
            let rules = (0..<8).map { index in
                PortForwardRule.localForward(
                    id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!, enabled: random.next(4) != 0,
                    localPort: UInt16(20_000 + random.next(6)), remoteHost: ["localhost", "127.0.0.1", "db.internal"][random.next(3)],
                    remotePort: [3_000, 5_173, 5_432, 8_080, 8_443][random.next(5)], label: random.next(2) == 0 ? "" : titles[random.next(titles.count)])
            }
            let forwards = (0..<random.next(12)).map { _ in
                ArtifactsActiveForward(hostID: ["h0", "h1", "h2", "missing"][random.next(4)], rule: rules[random.next(rules.count)])
            }
            let state = ArtifactsState(tabs: tabs)
            let context = ArtifactsQuickOpenContext(hosts: hosts, currentHostID: iteration % 4 == 0 ? nil : "h0",
                cwd: iteration % 3 == 0 ? nil : "/work", listeningPorts: ports, activeForwards: forwards)
            let inputs = ["", queries[iteration % queries.count], queries[random.next(queries.count)]]
            for input in inputs {
                for limit in [-1, 0, 1, 2, 5, 8, 16, 128] {
                    let suggestions = ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: recents, limit: limit)
                    XCTAssertEqual(suggestions, referenceSuggestions(input, state: state, context: context, recents: recents, limit: limit),
                        "iteration=\(iteration), query=\(input), limit=\(limit)")
                    forwardSuggestions += suggestions.filter { $0.kind == .activeForward }.count
                }
            }
        }
        XCTAssertGreaterThan(forwardSuggestions, 0, "the oracle must cover running forwards")
    }

    func testDuplicateTabsPortsAndRecentsCannotCrowdOutLaterUniqueResults() {
        let first = ArtifactTab(id: "same", hostID: "h", hostLabel: "dev", target: .file(path: "/a"),
                                title: "a", openedAt: 1, viewedAt: 1)
        let second = ArtifactTab(id: "other", hostID: "h", hostLabel: "dev", target: .change(path: "/a", diff: "+x", summary: "edit"),
                                 title: "edit", openedAt: 2, viewedAt: 2)
        let state = ArtifactsState(tabs: Array(repeating: first, count: 64) + [second])
        let context = ArtifactsQuickOpenContext(hosts: [.init(id: "h", label: "dev", home: "/")], currentHostID: "h", cwd: "/",
            listeningPorts: Array(repeating: .init(port: 5_173, bindAddress: "127.0.0.1", process: "first"), count: 64)
                + [.init(port: 5_174, bindAddress: "127.0.0.1", process: "second")])
        let recents: [ArtifactsRecent] = [
            .init(title: "a", subtitle: "dev", intent: .file(hostID: "h", path: "/a"), viewedAt: 5),
            .init(title: "b", subtitle: "dev", intent: .file(hostID: "h", path: "/b"), viewedAt: 4),
        ]
        for input in ["", "dev:/a", ":5"] {
            for limit in 1...8 {
                XCTAssertEqual(ArtifactsQuickOpen.suggestions(input, state: state, context: context, recents: recents, limit: limit),
                               referenceSuggestions(input, state: state, context: context, recents: recents, limit: limit))
            }
        }
    }

    // Keep the previous implementation as the ordering and deduplication oracle.
    private func referenceSuggestions(
        _ input: String, state: ArtifactsState, context: ArtifactsQuickOpenContext,
        recents: [ArtifactsRecent], limit: Int = 8
    ) -> [ArtifactsSuggestion] {
        guard limit > 0 else { return [] }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [ArtifactsSuggestion] = []
        let parsed = ArtifactsQuickOpen.parse(text, context: context)
        let needle: String
        if case let .search(query) = parsed { needle = ArtifactsPaths.folded(query) }
        else { needle = ArtifactsPaths.folded(text) }
        let prefix = text.firstIndex(of: ":").map { String(text[..<$0]) }
        if let prefix, context.hosts.contains(where: { $0.label.lowercased() == prefix.lowercased() }),
           isDestination(parsed) {
            result.append(.init(kind: .hostPrefix, title: text, subtitle: prefix, intent: parsed))
        }
        // Each running forward's page is the one the planner would reuse.
        var forwardPages: [(rank: Int, port: UInt16, scheme: String, suggestion: ArtifactsSuggestion)] = []
        for (hostID, forwards) in Dictionary(grouping: context.activeForwards, by: \.hostID) {
            guard let index = context.hosts.firstIndex(where: { $0.id == hostID }) else { continue }
            let label = context.hosts[index].label
            let rules = forwards.map(\.rule)
            for port in Set(rules.compactMap { $0.target?.port }) {
                guard case let .reuse(ruleID, target) = ArtifactsForwardPlanner.plan(remotePort: port, hostRules: rules),
                      let rule = rules.first(where: { $0.id == ruleID }),
                      !state.tabs.contains(where: { tab in
                          guard tab.hostID == hostID, case let .page(scheme, tabPort, _) = tab.target else { return false }
                          return scheme == target.scheme && tabPort == port
                      })
                else { continue }
                let subtitle = rule.label.isEmpty ? label : "\(label) · \(rule.label)"
                var intent = ArtifactsQuickOpenIntent.page(hostID: hostID, scheme: target.scheme, port: port, path: "/")
                var matchesPagePort = false
                if case let .page(host, scheme, parsedPort, _) = parsed, host == hostID, scheme == target.scheme, parsedPort == port {
                    matchesPagePort = true
                    intent = parsed
                }
                let searchable = "localhost:\(port) \(subtitle) \(target.scheme)://localhost:\(port)/"
                guard needle.isEmpty || matchesPagePort || ArtifactsPaths.folded(searchable).contains(needle) else { continue }
                forwardPages.append((hostID == context.currentHostID ? -1 : index, port, target.scheme,
                                     .init(kind: .activeForward, title: "localhost:\(port)", subtitle: subtitle, intent: intent)))
            }
        }
        result += forwardPages.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.scheme < $1.scheme
        }.map(\.suggestion)
        // Bare "localhost" lists them all; a file named "localhost.conf"
        // or a host labelled "localhost-dev" is not a port.
        let lowered = text.lowercased()
        let spellsPort = text.hasPrefix(":") || lowered == "localhost" || lowered.hasPrefix("localhost:")
        if spellsPort, let host = context.currentHostID, context.hosts.contains(where: { $0.id == host }) {
            let portInput = text.hasPrefix(":") ? String(text.dropFirst())
                : String(lowered.dropFirst("localhost:".count))
            let portPrefix = String(portInput.prefix { !"/?#".contains($0) })
            for port in context.listeningPorts.sorted(by: { $0.port < $1.port }) {
                guard !state.tabs.contains(where: { tab in
                    guard tab.hostID == host, case let .page(_, tabPort, _) = tab.target else { return false }
                    return tabPort == port.port
                }), portPrefix.isEmpty || String(port.port).hasPrefix(portPrefix) else { continue }
                let intent: ArtifactsQuickOpenIntent
                if case let .page(_, _, parsedPort, _) = parsed, parsedPort == port.port { intent = parsed }
                else { intent = .page(hostID: host, scheme: "http", port: port.port, path: "/") }
                result.append(.init(kind: .listeningPort, title: "localhost:\(port.port)",
                                    subtitle: port.process ?? port.bindAddress,
                                    intent: intent))
            }
        }
        for tab in state.tabs.sorted(by: ArtifactsOverview.recentFirst) {
            if spellsPort { guard case .page = tab.target else { continue } }
            var searchable = "\(tab.title) \(tab.target.path) \(tab.hostLabel) \(tab.hostLabel):\(tab.target.path)"
            var matchesPagePort = false
            if case let .page(scheme, port, path) = tab.target {
                searchable += " \(scheme)://localhost:\(port)\(path)"
                if case let .page(host, parsedScheme, parsedPort, _) = parsed {
                    matchesPagePort = host == tab.hostID && scheme == parsedScheme && port == parsedPort
                }
            }
            guard needle.isEmpty || matchesPagePort || ArtifactsPaths.folded(searchable).contains(needle) else { continue }
            let intent: ArtifactsQuickOpenIntent
            switch tab.target {
            case let .page(scheme, port, path):
                if case let .page(host, newScheme, newPort, _) = parsed,
                   host == tab.hostID, scheme == newScheme, port == newPort { intent = parsed }
                else { intent = .page(hostID: tab.hostID, scheme: scheme, port: port, path: path) }
            case let .file(path), let .change(path, _, _): intent = .file(hostID: tab.hostID, path: path)
            }
            result.append(.init(kind: .openTab, title: tab.title, subtitle: "\(tab.hostLabel) · \(tab.target.path)",
                                intent: intent, tabID: tab.id))
        }
        for recent in recents.sorted(by: {
            if $0.viewedAt != $1.viewedAt { return $0.viewedAt > $1.viewedAt }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.subtitle < $1.subtitle
        }) where needle.isEmpty || ArtifactsPaths.folded(recent.title + " " + recent.subtitle).contains(needle) {
            guard isDestination(recent.intent) else { continue }
            result.append(.init(kind: .recent, title: recent.title, subtitle: recent.subtitle, intent: recent.intent))
        }
        var unique: [ArtifactsSuggestion] = []
        for suggestion in result where !unique.contains(where: {
            $0.intent == suggestion.intent && ($0.tabID == suggestion.tabID || $0.tabID == nil || suggestion.tabID == nil)
        }) {
            unique.append(suggestion)
            if unique.count == limit { break }
        }
        return unique
    }


    private func isDestination(_ intent: ArtifactsQuickOpenIntent) -> Bool {
        switch intent {
        case .file, .directory, .page: return true
        case .invalid, .search: return false
        }
    }

    private struct Generator {
        private var value: UInt64 = 0x92b5_18c7_4ad3_602f
        mutating func next(_ upperBound: Int) -> Int {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((value >> 32) % UInt64(upperBound))
        }
    }
}

