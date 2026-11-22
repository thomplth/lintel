import Foundation
import JavaScriptCore
import Testing
@testable import LintelCore

private let worktreeRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func loadModuleSource(_ name: String) -> String? {
    try? String(contentsOf: worktreeRoot.appending(path: "Sources/Lintel/Resources/Library/\(name).js"), encoding: .utf8)
}

private final class MockModuleHarness {
    let context: JSContext
    var execCalls: [(tool: String, args: [String])] = []
    var fetchCalls: [(url: String, method: String, auth: String?)] = []
    var attentionLog: [Bool] = []
    var notifications: [(title: String, body: String)] = []
    var storageWrites: [(key: String, value: Any)] = []
    var execHandler: (_ tool: String, _ args: [String]) -> Result<String, Error>
    var fetchHandler: (_ url: String, _ options: [String: Any]) -> Result<String, Error>

    init(
        source: String,
        storage: [String: Any] = [:],
        fixedNowMs: Double = 1_795_200_000_000, // 2026-11-21T16:00:00Z
        execHandler: @escaping (_ tool: String, _ args: [String]) -> Result<String, Error>,
        fetchHandler: @escaping (_ url: String, _ options: [String: Any]) -> Result<String, Error>
    ) {
        self.execHandler = execHandler
        self.fetchHandler = fetchHandler
        context = JSContext()!
        context.exceptionHandler = { _, exc in
            Issue.record("JS exception: \(exc?.toString() ?? "unknown")")
        }

        let callBlock: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] name, argsJSON, resolve, reject in
            guard let self else { return }
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [Any]) ?? []
            switch name {
            case "exec":
                let tool = args.first as? String ?? ""
                let toolArgs = (args.count > 1 ? args[1] as? [String] : nil) ?? []
                self.execCalls.append((tool, toolArgs))
                switch self.execHandler(tool, toolArgs) {
                case .success(let stdout):
                    let payload: [String: Any] = ["status": 0, "stdout": stdout, "stderr": ""]
                    let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                    resolve.call(withArguments: [encoded])
                case .failure(let error):
                    reject.call(withArguments: [error.localizedDescription])
                }
            case "fetch":
                let url = args.first as? String ?? ""
                let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
                let headers = options["headers"] as? [String: String] ?? [:]
                self.fetchCalls.append((url, options["method"] as? String ?? "GET", headers["Authorization"]))
                switch self.fetchHandler(url, options) {
                case .success(let body):
                    let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]), as: UTF8.self)
                    resolve.call(withArguments: [encoded])
                case .failure(let error):
                    reject.call(withArguments: [error.localizedDescription])
                }
            default:
                reject.call(withArguments: ["unsupported call: \(name)"])
            }
        }
        context.setObject(callBlock, forKeyedSubscript: "__call" as NSString)

        let postBlock: @convention(block) (String, String) -> Void = { [weak self] name, argsJSON in
            guard let self else { return }
            let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [Any]) ?? []
            switch name {
            case "attention":
                self.attentionLog.append(args.first as? Bool ?? false)
            case "notify":
                self.notifications.append((args.first as? String ?? "", args.count > 1 ? args[1] as? String ?? "" : ""))
            case "storage.set":
                self.storageWrites.append((args.first as? String ?? "", args.count > 1 ? args[1] : NSNull()))
            default:
                break
            }
        }
        context.setObject(postBlock, forKeyedSubscript: "__post" as NSString)

        context.evaluateScript(ModulePrelude.source)
        context.evaluateScript("""
        var __fixedNow = \(fixedNowMs);
        Date = class extends Date {
          constructor(...a) { a.length ? super(...a) : super(__fixedNow); }
          static now() { return __fixedNow; }
        };
        """)
        let storageData = try! JSONSerialization.data(withJSONObject: storage)
        let storageText = String(decoding: storageData, as: UTF8.self)
        context.objectForKeyedSubscript("__setStorage").call(withArguments: [storageText])
        context.evaluateScript(source)
    }

    func advanceTime(seconds: Double) {
        context.evaluateScript("__fixedNow += \(seconds * 1000);")
    }

    func description() throws -> (manifest: ModuleManifest, hasConfigure: Bool, actions: [String]) {
        let json = context.evaluateScript("__describe()").toString() ?? "null"
        let value = try JSONValue.parse(json)
        let manifest = try ModuleManifest(value["meta"])
        let hasConfigure = value["hasConfigure"].bool ?? false
        let actions = (value["actions"].array ?? []).compactMap(\.string)
        return (manifest, hasConfigure, actions)
    }

    func render(_ surface: String) throws -> ViewNode {
        var outputJSON: String?
        var outputError: String?
        let done: @convention(block) (JSValue, JSValue) -> Void = { result, error in
            if error.isNull || error.isUndefined {
                outputJSON = result.toString()
            } else {
                outputError = error.toString()
            }
        }
        context.objectForKeyedSubscript("__render").call(withArguments: [surface, unsafeBitCast(done, to: AnyObject.self)])
        if let outputError { throw TestError(outputError) }
        guard let outputJSON else { throw TestError("render \(surface) did not finish") }
        let parsed = ViewNode.parse(try JSONValue.parse(outputJSON))
        guard parsed.errors.isEmpty, let node = parsed.node else {
            throw TestError("parse failed: \(parsed.errors.joined(separator: "; "))")
        }
        return node
    }

    @discardableResult
    func act(_ name: String, payload: Any = NSNull()) throws -> JSONValue {
        var outputJSON: String?
        var outputError: String?
        let done: @convention(block) (JSValue, JSValue) -> Void = { result, error in
            if error.isNull || error.isUndefined {
                outputJSON = result.toString()
            } else {
                outputError = error.toString()
            }
        }
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let payloadText = String(decoding: payloadData, as: UTF8.self)
        context.objectForKeyedSubscript("__act").call(withArguments: [name, payloadText, unsafeBitCast(done, to: AnyObject.self)])
        if let outputError { throw TestError(outputError) }
        return try JSONValue.parse(outputJSON ?? "null")
    }
}

private struct TestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func jsonString(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func lists(in node: ViewNode) -> [ViewNode] {
    node.descendants.filter { $0.component == .list }
}

private func items(in list: ViewNode) -> [ViewNode] {
    list.descendants.filter { $0.component == .item }
}

private func allItems(in node: ViewNode) -> [ViewNode] {
    node.descendants.filter { $0.component == .item }
}

private func slots(of item: ViewNode) -> [JSONValue] {
    item.props["slots"]?.array ?? []
}

private func sampleReviewsGraphQLResponse() -> String {
    let payload: [String: Any] = [
        "data": [
            "viewer": ["login": "alice"],
            "reviewRequested": [
                "nodes": [
                    // 1. Direct request, unreviewed, GoodNotes/app
                    [
                        "number": 101,
                        "title": "Fix offline sync race condition",
                        "url": "https://github.com/GoodNotes/app/pull/101",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:30:00Z",
                        "createdAt": "2026-11-21T14:00:00Z",
                        "additions": 120,
                        "deletions": 35,
                        "changedFiles": 5,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "BLOCKED",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app"],
                        "author": ["__typename": "User", "login": "bob"],
                        "assignees": ["nodes": []],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "alice"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": []],
                        "reviews": ["nodes": []],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
                    ],
                    // 2. Team request, unreviewed except bot approval -> still unreviewed when ignoreBots=true
                    [
                        "number": 202,
                        "title": "Add Terraform module for cache",
                        "url": "https://github.com/GoodNotes/infra/pull/202",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:00:00Z",
                        "createdAt": "2026-11-21T12:00:00Z",
                        "additions": 40,
                        "deletions": 10,
                        "changedFiles": 2,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "mergeable": "CONFLICTING",
                        "mergeStateStatus": "DIRTY",
                        "repository": ["nameWithOwner": "GoodNotes/infra", "name": "infra"],
                        "author": ["__typename": "User", "login": "carol"],
                        "assignees": ["nodes": []],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "Team", "slug": "platform", "combinedSlug": "GoodNotes/platform"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": [
                            ["state": "APPROVED", "submittedAt": "2026-11-21T14:30:00Z", "author": ["__typename": "Bot", "login": "github-actions"]],
                        ]],
                        "reviews": ["nodes": [
                            ["state": "COMMENTED", "submittedAt": "2026-11-21T14:20:00Z", "author": ["__typename": "User", "login": "carol"]],
                        ]],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "FAILURE"]]]]],
                    ],
                    // 3. Already approved by another human -> hidden in default 'Unreviewed' filter
                    [
                        "number": 103,
                        "title": "Update onboarding copy",
                        "url": "https://github.com/GoodNotes/app/pull/103",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:10:00Z",
                        "createdAt": "2026-11-21T10:00:00Z",
                        "additions": 8,
                        "deletions": 8,
                        "changedFiles": 1,
                        "reviewDecision": "APPROVED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "CLEAN",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app"],
                        "author": ["__typename": "User", "login": "dave"],
                        "assignees": ["nodes": []],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "alice"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": [
                            ["state": "APPROVED", "submittedAt": "2026-11-21T15:05:00Z", "author": ["__typename": "User", "login": "eve"]],
                        ]],
                        "reviews": ["nodes": [
                            ["state": "APPROVED", "submittedAt": "2026-11-21T15:05:00Z", "author": ["__typename": "User", "login": "eve"]],
                        ]],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
                    ],
                    // 4. Another human requested changes -> hidden in 'Unreviewed', shown in 'Needs approval'
                    [
                        "number": 104,
                        "title": "Refactor PDF exporter",
                        "url": "https://github.com/GoodNotes/app/pull/104",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T14:50:00Z",
                        "createdAt": "2026-11-21T09:00:00Z",
                        "additions": 300,
                        "deletions": 150,
                        "changedFiles": 12,
                        "reviewDecision": "CHANGES_REQUESTED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "BLOCKED",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app"],
                        "author": ["__typename": "User", "login": "frank"],
                        "assignees": ["nodes": []],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "alice"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": [
                            ["state": "CHANGES_REQUESTED", "submittedAt": "2026-11-21T14:40:00Z", "author": ["__typename": "User", "login": "grace"]],
                        ]],
                        "reviews": ["nodes": [
                            ["state": "CHANGES_REQUESTED", "submittedAt": "2026-11-21T14:40:00Z", "author": ["__typename": "User", "login": "grace"]],
                        ]],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
                    ],
                    // 5. Draft PR -> hidden unless includeDrafts is on
                    [
                        "number": 105,
                        "title": "WIP dark mode tokens",
                        "url": "https://github.com/GoodNotes/app/pull/105",
                        "isDraft": true,
                        "updatedAt": "2026-11-21T13:00:00Z",
                        "createdAt": "2026-11-21T08:00:00Z",
                        "additions": 50,
                        "deletions": 5,
                        "changedFiles": 3,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "DRAFT",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app"],
                        "author": ["__typename": "User", "login": "bob"],
                        "assignees": ["nodes": []],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "alice"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": []],
                        "reviews": ["nodes": []],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "PENDING"]]]]],
                    ],
                ],
            ],
            "assigned": ["nodes": []],
        ],
    ]
    return jsonString(payload)
}

private func sampleMyPRsGraphQLResponse() -> String {
    let payload: [String: Any] = [
        "data": [
            "viewer": ["login": "alice"],
            "authored": [
                "nodes": [
                    // Stack of 3 in GoodNotes/app: #301 (base->develop) <- #302 <- #303
                    [
                        "number": 301,
                        "title": "Add FreeText writer core",
                        "url": "https://github.com/GoodNotes/app/pull/301",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:40:00Z",
                        "additions": 210,
                        "deletions": 15,
                        "baseRefName": "develop",
                        "headRefName": "alice/freetext-1",
                        "reviewDecision": "APPROVED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "CLEAN",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app", "defaultBranchRef": ["name": "develop"]],
                        "reviewRequests": ["nodes": []],
                        "latestOpinionatedReviews": ["nodes": [
                            ["state": "APPROVED", "author": ["__typename": "User", "login": "bob"]],
                            ["state": "APPROVED", "author": ["__typename": "User", "login": "carol"]],
                        ]],
                        "reviews": ["nodes": [
                            ["state": "APPROVED", "author": ["__typename": "User", "login": "bob"]],
                        ]],
                        "reviewThreads": ["totalCount": 2, "nodes": [["isResolved": true, "isOutdated": false], ["isResolved": true, "isOutdated": false]]],
                        "comments": ["totalCount": 1],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": [
                            "state": "SUCCESS",
                            "contexts": [
                                "totalCount": 15,
                                "checkRunCountsByState": [["state": "SUCCESS", "count": 12], ["state": "SKIPPED", "count": 3]],
                                "statusContextCountsByState": [],
                            ],
                        ]]]]],
                    ],
                    [
                        "number": 302,
                        "title": "Wire FreeText export pipeline",
                        "url": "https://github.com/GoodNotes/app/pull/302",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:35:00Z",
                        "additions": 140,
                        "deletions": 20,
                        "baseRefName": "alice/freetext-1",
                        "headRefName": "alice/freetext-2",
                        "reviewDecision": "REVIEW_REQUIRED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "BLOCKED",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app", "defaultBranchRef": ["name": "develop"]],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "dave"]],
                            ["requestedReviewer": ["__typename": "Team", "slug": "xp", "combinedSlug": "GoodNotes/xp"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": []],
                        "reviews": ["nodes": [
                            ["state": "COMMENTED", "author": ["__typename": "User", "login": "eve"]],
                        ]],
                        "reviewThreads": ["totalCount": 3, "nodes": [
                            ["isResolved": false, "isOutdated": false],
                            ["isResolved": false, "isOutdated": false],
                            ["isResolved": true, "isOutdated": false],
                        ]],
                        "comments": ["totalCount": 4],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": [
                            "state": "PENDING",
                            "contexts": [
                                "totalCount": 12,
                                "checkRunCountsByState": [["state": "SUCCESS", "count": 9], ["state": "IN_PROGRESS", "count": 3]],
                                "statusContextCountsByState": [],
                            ],
                        ]]]]],
                    ],
                    [
                        "number": 303,
                        "title": "Add E2E test for FreeText export",
                        "url": "https://github.com/GoodNotes/app/pull/303",
                        "isDraft": false,
                        "updatedAt": "2026-11-21T15:30:00Z",
                        "additions": 85,
                        "deletions": 4,
                        "baseRefName": "alice/freetext-2",
                        "headRefName": "alice/freetext-3",
                        "reviewDecision": "REVIEW_REQUIRED",
                        "mergeable": "CONFLICTING",
                        "mergeStateStatus": "DIRTY",
                        "repository": ["nameWithOwner": "GoodNotes/app", "name": "app", "defaultBranchRef": ["name": "develop"]],
                        "reviewRequests": ["nodes": [
                            ["requestedReviewer": ["__typename": "User", "login": "bob"]],
                        ]],
                        "latestOpinionatedReviews": ["nodes": []],
                        "reviews": ["nodes": []],
                        "reviewThreads": ["totalCount": 0, "nodes": []],
                        "comments": ["totalCount": 0],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": [
                            "state": "FAILURE",
                            "contexts": [
                                "totalCount": 218,
                                "checkRunCountsByState": [["state": "SUCCESS", "count": 138], ["state": "FAILURE", "count": 2], ["state": "SKIPPED", "count": 74]],
                                "statusContextCountsByState": [["state": "SUCCESS", "count": 4]],
                            ],
                        ]]]]],
                    ],
                    // Standalone draft PR in GoodNotes/infra with changes requested
                    [
                        "number": 549,
                        "title": "Loosen Firehouse guardrails",
                        "url": "https://github.com/GoodNotes/infra/pull/549",
                        "isDraft": true,
                        "updatedAt": "2026-11-21T12:00:00Z",
                        "additions": 649,
                        "deletions": 299,
                        "baseRefName": "master",
                        "headRefName": "firehouse/loosen",
                        "reviewDecision": "CHANGES_REQUESTED",
                        "mergeable": "MERGEABLE",
                        "mergeStateStatus": "DRAFT",
                        "repository": ["nameWithOwner": "GoodNotes/infra", "name": "infra", "defaultBranchRef": ["name": "master"]],
                        "reviewRequests": ["nodes": []],
                        "latestOpinionatedReviews": ["nodes": [
                            ["state": "CHANGES_REQUESTED", "author": ["__typename": "User", "login": "frank"]],
                        ]],
                        "reviews": ["nodes": [
                            ["state": "CHANGES_REQUESTED", "author": ["__typename": "User", "login": "frank"]],
                        ]],
                        "reviewThreads": ["totalCount": 1, "nodes": [["isResolved": false, "isOutdated": false]]],
                        "comments": ["totalCount": 2],
                        "commits": ["nodes": [["commit": ["statusCheckRollup": [
                            "state": "SUCCESS",
                            "contexts": [
                                "totalCount": 5,
                                "checkRunCountsByState": [["state": "SUCCESS", "count": 5]],
                                "statusContextCountsByState": [],
                            ],
                        ]]]]],
                    ],
                ],
            ],
        ],
    ]
    return jsonString(payload)
}

@Suite struct GitHubPRModules {
    @Test func legacyMonolithicModuleIsReplacedByTwoFocusedLibraryModules() {
        #expect(loadModuleSource("github-prs") == nil)
        #expect(loadModuleSource("github-reviews") != nil)
        #expect(loadModuleSource("github-my-prs") != nil)
    }

    @Test func reviewsModuleDefaultsToUnreviewedAndGroupsByRepo() throws {
        let source = try #require(loadModuleSource("github-reviews"))
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(sampleReviewsGraphQLResponse()) }
        )
        let desc = try harness.description()
        #expect(desc.manifest.id == "github-reviews")
        #expect(desc.manifest.refreshSeconds <= 30)
        #expect(desc.hasConfigure)

        let chip = try harness.render("chip")
        // PR #101 (direct, unreviewed) and #202 (team, only bot approved) pass; #103 (approved), #104 (changes), #105 (draft) are hidden.
        #expect(chip.descendants.contains { $0.component == .badge && $0.string("value") == "2" })
        #expect(harness.attentionLog.last == true)

        let widget = try harness.render("widget")
        let repoCards = lists(in: widget)
        #expect(repoCards.map { $0.string("title") ?? "" } == ["app", "infra"])
        #expect(repoCards.allSatisfy { $0.string("trailing") == nil })
        #expect(widget.descendants.filter { $0.component == .note }.isEmpty)

        let allRows = allItems(in: widget)
        #expect(allRows.count == 2)
        #expect(allRows.allSatisfy { ($0.string("url") ?? "").hasPrefix("https://github.com/") })
        #expect(allRows[0].string("title")?.contains("Fix offline sync") == true)
        #expect(allRows[0].string("value") == "#101")
        #expect(allRows[0].string("tag") == "Direct")
        #expect(allRows[0].string("tagTone") == "info")
        #expect(allRows[0].string("subtitle")?.contains("@bob") == true)
        let row0Slots = slots(of: allRows[0])
        #expect(row0Slots.count == 3)
        #expect(row0Slots[0]["icon"].string == "checkmark")
        #expect(row0Slots[0]["tone"].string == "good")
        #expect(row0Slots[1]["value"].string == "+120")

        #expect(allRows[1].string("value") == "#202")
        #expect(allRows[1].string("tag") == "Team")
        let row1Slots = slots(of: allRows[1])
        #expect(row1Slots.count == 3)
        #expect(row1Slots[0]["icon"].string == "exclamationmark.triangle.fill")
        #expect(row1Slots[0]["tone"].string == "bad")

        let configure = try harness.render("configure")
        let lintErrors = DesignLint.check(chip: chip, panel: nil, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
            + DesignLint.checkWidget(widget, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
            + DesignLint.checkConfigure(configure, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
        #expect(lintErrors.filter { $0.severity == .error }.isEmpty)
    }

    @Test func reviewsModuleFiltersByStatusScopeBotsDraftsAndRepos() throws {
        let source = try #require(loadModuleSource("github-reviews"))
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(sampleReviewsGraphQLResponse()) }
        )

        // Initial load
        _ = try harness.render("widget")

        // Switch status to 'Needs approval': #104 (changes requested) now appears too -> 3 PRs.
        try harness.act("setStatusFilter", payload: "Needs approval")
        #expect(allItems(in: try harness.render("widget")).count == 3)

        // Switch status to 'All': #103 (approved) also appears -> 4 PRs (draft #105 still hidden).
        try harness.act("setStatusFilter", payload: "All")
        #expect(allItems(in: try harness.render("widget")).count == 4)

        // Include drafts -> 5 PRs.
        try harness.act("setIncludeDrafts", payload: true)
        #expect(allItems(in: try harness.render("widget")).count == 5)

        // Direct only -> excludes team-only #202 -> 4 PRs.
        try harness.act("setScope", payload: "Direct only")
        let directWidget = try harness.render("widget")
        #expect(allItems(in: directWidget).count == 4)
        #expect(lists(in: directWidget).map { $0.string("title") ?? "" } == ["app"])

        // Back to Unreviewed + Direct + Team, turn off ignoreBots -> bot approval on #202 now hides #202.
        try harness.act("setStatusFilter", payload: "Unreviewed")
        try harness.act("setScope", payload: "Direct + Team")
        try harness.act("setIncludeDrafts", payload: false)
        try harness.act("setIgnoreBots", payload: false)
        #expect(allItems(in: try harness.render("widget")).count == 1)

        // Repo filter: Only selected -> pick GoodNotes/infra (with ignoreBots back on) -> only #202.
        try harness.act("setIgnoreBots", payload: true)
        try harness.act("setRepoMode", payload: "Only selected")
        try harness.act("toggleRepo", payload: "GoodNotes/infra")
        let repoFiltered = try harness.render("widget")
        #expect(lists(in: repoFiltered).map { $0.string("title") ?? "" } == ["infra"])
        #expect(allItems(in: repoFiltered).count == 1)
    }

    @Test func reviewsModuleCachesTokenAndRetriesOnceOn401() throws {
        let source = try #require(loadModuleSource("github-reviews"))
        var fetchAttempt = 0
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_token_\(fetchAttempt)\n") },
            fetchHandler: { _, _ in
                fetchAttempt += 1
                if fetchAttempt == 1 {
                    return .failure(TestError("HTTP 401 from api.github.com"))
                }
                return .success(sampleReviewsGraphQLResponse())
            }
        )

        let chip = try harness.render("chip")
        #expect(harness.execCalls.count == 2)
        #expect(harness.fetchCalls.count == 2)
        #expect(chip.descendants.contains { $0.component == .badge && $0.string("value") == "2" })

        // Subsequent render within refresh window uses cache without refetching.
        harness.advanceTime(seconds: 5)
        _ = try harness.render("chip")
        #expect(harness.fetchCalls.count == 2)

        // After refresh window expires, fetches directly via GraphQL without re-running `gh auth token`.
        harness.advanceTime(seconds: 20)
        _ = try harness.render("chip")
        #expect(harness.execCalls.count == 2)
        #expect(harness.fetchCalls.count == 3)
    }

    @Test func myPRsModuleRepresentsStacksAndAllStatusSignals() throws {
        let source = try #require(loadModuleSource("github-my-prs"))
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(sampleMyPRsGraphQLResponse()) }
        )
        let desc = try harness.description()
        #expect(desc.manifest.id == "github-my-prs")
        #expect(desc.manifest.refreshSeconds <= 30)
        #expect(desc.hasConfigure)

        let chip = try harness.render("chip")
        // 4 open PRs total, and #303 has conflict + CI failure -> bad tone badge showing 4
        #expect(chip.descendants.contains { $0.component == .badge && $0.string("value") == "4" && $0.string("tone") == "bad" })

        let widget = try harness.render("widget")
        let cards = lists(in: widget)
        // First card is the 3-PR stack in GoodNotes/app (repo-only header, no left rail); second is standalone GoodNotes/infra
        #expect(cards.count == 2)
        #expect(cards[0].string("title") == "app")
        #expect(cards[0].string("trailing") == nil)
        #expect(cards[0].bool("rail") == false)
        #expect(cards[1].string("title") == "infra")
        #expect(cards[1].string("trailing") == nil)
        #expect(cards[1].bool("rail") == false)
        #expect(widget.descendants.filter { $0.component == .note }.isEmpty)

        let stackRows = items(in: cards[0])
        #expect(stackRows.count == 3)
        #expect(stackRows.allSatisfy { ($0.string("url") ?? "").hasPrefix("https://github.com/") })

        // Layer 1 (#301): base of stack, inline step 1/3, approved by 2, CI 12 passed, Ready (3 slots: CI, Review, Merge)
        #expect(stackRows[0].string("title") == "Add FreeText writer core")
        #expect(stackRows[0].string("compactTitle") == "freetext-1")
        #expect(stackRows[0].string("value") == "#301")
        #expect(stackRows[0].string("tag") == "1/3")
        #expect(stackRows[0].string("tone") == "good")
        #expect(stackRows[0].string("caption") == "Approved @bob, @carol")
        let s0 = slots(of: stackRows[0])
        #expect(s0.count == 3)
        #expect(s0[0]["value"].string == "12" && s0[0]["tone"].string == "good")
        #expect(s0[1]["value"].string == "2" && s0[1]["tone"].string == "good")
        #expect(s0[2]["icon"].string == "checkmark" && s0[2]["tone"].string == "good")

        // Layer 2 (#302): stacked on #301, inline step 2/3, 2 unresolved threads + Req @dave, @xp, 3 CI pending
        #expect(stackRows[1].string("compactTitle") == "freetext-2")
        #expect(stackRows[1].string("value") == "#302")
        #expect(stackRows[1].string("tag") == "2/3")
        #expect(stackRows[1].string("caption") == "2 unresolved · Req @dave, @xp")
        let s1 = slots(of: stackRows[1])
        #expect(s1.count == 3)
        #expect(s1[0]["icon"].string == "clock" && s1[0]["value"].string == "3" && s1[0]["tone"].string == "warn")
        #expect(s1[1]["value"].string == "2" && s1[1]["tone"].string == "info")

        // Layer 3 (#303): stacked on #302, inline step 3/3, conflicting + 2 CI failures across 218 checks
        #expect(stackRows[2].string("compactTitle") == "freetext-3")
        #expect(stackRows[2].string("value") == "#303")
        #expect(stackRows[2].string("tag") == "3/3")
        #expect(stackRows[2].string("tone") == "bad")
        #expect(stackRows[2].string("caption") == "Req @bob")
        let s2 = slots(of: stackRows[2])
        #expect(s2.count == 3)
        #expect(s2[0]["icon"].string == "xmark" && s2[0]["value"].string == "2" && s2[0]["tone"].string == "bad")
        #expect(s2[2]["icon"].string == "exclamationmark.triangle.fill" && s2[2]["tone"].string == "bad")

        // Standalone PR #549 in infra: Draft tag on meta line + 1 unresolved + Changes @frank
        let standaloneRows = items(in: cards[1])
        #expect(standaloneRows.count == 1)
        #expect(standaloneRows[0].string("compactTitle") == "loosen")
        #expect(standaloneRows[0].string("tag") == "Draft")
        #expect(standaloneRows[0].string("caption") == "1 unresolved · Changes @frank")
        let sStandalone = slots(of: standaloneRows[0])
        #expect(sStandalone.count == 3)
        #expect(sStandalone[1]["icon"].string == "xmark" && sStandalone[1]["tone"].string == "bad")

        // Hiding drafts removes #549
        try harness.act("setIncludeDrafts", payload: false)
        #expect(allItems(in: try harness.render("widget")).count == 3)

        let configure = try harness.render("configure")
        let lintErrors = DesignLint.check(chip: chip, panel: nil, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
            + DesignLint.checkWidget(widget, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
            + DesignLint.checkConfigure(configure, manifest: desc.manifest, actions: desc.actions, symbolExists: { _ in true })
        #expect(lintErrors.filter { $0.severity == .error }.isEmpty)
    }

    @Test func myPRsHandlesBranchingStacksExternalBasesCyclesAndFlatMode() throws {
        let source = try #require(loadModuleSource("github-my-prs"))
        let branchingPayload = jsonString([
            "data": [
                "viewer": ["login": "alice"],
                "authored": [
                    "nodes": [
                        [
                            "number": 10, "title": "Base feature", "url": "https://github.com/org/repo/pull/10",
                            "isDraft": false, "updatedAt": "2026-11-21T15:00:00Z", "additions": 10, "deletions": 2,
                            "baseRefName": "main", "headRefName": "feat/base", "reviewDecision": "REVIEW_REQUIRED",
                            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
                            "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviews": ["nodes": []],
                            "reviewThreads": ["totalCount": 0, "nodes": []], "comments": ["totalCount": 0], "commits": ["nodes": []],
                        ],
                        [
                            "number": 11, "title": "Branch A", "url": "https://github.com/org/repo/pull/11",
                            "isDraft": false, "updatedAt": "2026-11-21T15:05:00Z", "additions": 20, "deletions": 4,
                            "baseRefName": "feat/base", "headRefName": "feat/a", "reviewDecision": "REVIEW_REQUIRED",
                            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
                            "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviews": ["nodes": []],
                            "reviewThreads": ["totalCount": 0, "nodes": []], "comments": ["totalCount": 0], "commits": ["nodes": []],
                        ],
                        [
                            "number": 12, "title": "Branch B", "url": "https://github.com/org/repo/pull/12",
                            "isDraft": false, "updatedAt": "2026-11-21T15:10:00Z", "additions": 30, "deletions": 6,
                            "baseRefName": "feat/base", "headRefName": "feat/b", "reviewDecision": "REVIEW_REQUIRED",
                            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
                            "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviews": ["nodes": []],
                            "reviewThreads": ["totalCount": 0, "nodes": []], "comments": ["totalCount": 0], "commits": ["nodes": []],
                        ],
                        [
                            "number": 20, "title": "On teammate branch", "url": "https://github.com/org/repo/pull/20",
                            "isDraft": false, "updatedAt": "2026-11-21T14:00:00Z", "additions": 5, "deletions": 1,
                            "baseRefName": "teammate/shared", "headRefName": "alice/on-shared", "reviewDecision": "REVIEW_REQUIRED",
                            "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
                            "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviews": ["nodes": []],
                            "reviewThreads": ["totalCount": 0, "nodes": []], "comments": ["totalCount": 0], "commits": ["nodes": []],
                        ],
                    ],
                ],
            ],
        ])

        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(branchingPayload) }
        )

        let widget = try harness.render("widget")
        let cards = lists(in: widget)
        #expect(cards.count == 2)
        let stackItems = items(in: cards[0])
        #expect(stackItems.count == 3)
        #expect(stackItems.map { $0.string("value") ?? "" } == ["#10", "#11", "#12"])
        #expect(stackItems.map { $0.string("tag") ?? "" } == ["1/3", "2/3", "3/3"])

        let externalItem = items(in: cards[1]).first
        #expect(externalItem?.string("caption")?.contains("← teammate/shared") == true)

        // Flat mode collapses stacks into a single repo card without stack step tags.
        try harness.act("setGroupByStack", payload: false)
        let flatCards = lists(in: try harness.render("widget"))
        #expect(flatCards.count == 1)
        #expect(items(in: flatCards[0]).count == 4)
        #expect(items(in: flatCards[0]).allSatisfy { $0.string("tag") == nil })
    }

    @Test func reviewsModuleSuggestsAndAddsReposAndShowAllResetsFilters() throws {
        let source = try #require(loadModuleSource("github-reviews"))
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(sampleReviewsGraphQLResponse()) }
        )
        _ = try harness.render("widget")

        let suggestions = try harness.act("suggestRepos", payload: "inf")
        #expect(suggestions.array?.first?["value"].string == "GoodNotes/infra")

        try harness.act("addRepo", payload: "GoodNotes/other")
        // Repo mode switches to Only selected -> 0 visible PRs -> empty state offers Show all open.
        let filteredWidget = try harness.render("widget")
        #expect(filteredWidget.descendants.contains { $0.component == .empty && $0.string("action") == "showAll" })

        try harness.act("showAll")
        #expect(allItems(in: try harness.render("widget")).count == 5)
    }

    @Test func modulesStripLeadingBracketAndTicketPrefixesForScannableTitlesAndBranchSlugs() throws {
        let mySource = try #require(loadModuleSource("github-my-prs"))
        let ticketed = jsonString([
            "data": [
                "viewer": ["login": "alice"],
                "authored": [
                    "nodes": [
                        [
                            "number": 1, "title": "[XP DX] XPLATFORM-22095: write text boxes as FreeText",
                            "url": "https://github.com/org/repo/pull/1", "isDraft": false, "updatedAt": "2026-11-21T15:00:00Z",
                            "additions": 10, "deletions": 2, "baseRefName": "main", "headRefName": "thomplth/XPLATFORM-22095-freetext-pdfium-writer",
                            "reviewDecision": "REVIEW_REQUIRED", "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED",
                            "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                            "reviewRequests": ["nodes": []], "latestOpinionatedReviews": ["nodes": []], "reviews": ["nodes": []],
                            "reviewThreads": ["totalCount": 0, "nodes": []], "comments": ["totalCount": 0], "commits": ["nodes": []],
                        ],
                    ],
                ],
            ],
        ])
        let harness = MockModuleHarness(
            source: mySource,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(ticketed) }
        )
        let row = try #require(allItems(in: try harness.render("widget")).first)
        #expect(row.string("title") == "Write text boxes as FreeText")
        #expect(row.string("compactTitle") == "freetext-pdfium-writer")
    }

    @Test func myPRsAttentionDismissesOnViewIgnoresDraftsAndRealertsOnNewState() throws {
        let source = try #require(loadModuleSource("github-my-prs"))

        func payload(nodes: [[String: Any]]) -> String {
            jsonString(["data": ["viewer": ["login": "alice"], "authored": ["nodes": nodes]]])
        }

        func prNode(
            number: Int,
            isDraft: Bool = false,
            mergeable: String = "MERGEABLE",
            mergeStateStatus: String = "BLOCKED",
            ciState: String = "SUCCESS",
            oid: String = "aaa111",
            reviewState: String? = nil
        ) -> [String: Any] {
            let reviews: [[String: Any]] = reviewState.map {
                [["state": $0, "author": ["__typename": "User", "login": "bob"]]]
            } ?? []
            return [
                "number": number,
                "title": "PR #\(number)",
                "url": "https://github.com/org/repo/pull/\(number)",
                "isDraft": isDraft,
                "updatedAt": "2026-11-21T15:00:00Z",
                "additions": 10,
                "deletions": 2,
                "baseRefName": "main",
                "headRefName": "feat/pr-\(number)",
                "reviewDecision": reviewState == "APPROVED" ? "APPROVED" : "REVIEW_REQUIRED",
                "mergeable": mergeable,
                "mergeStateStatus": mergeStateStatus,
                "repository": ["nameWithOwner": "org/repo", "name": "repo", "defaultBranchRef": ["name": "main"]],
                "reviewRequests": ["nodes": []],
                "latestOpinionatedReviews": ["nodes": reviews],
                "reviews": ["nodes": reviews],
                "reviewThreads": ["totalCount": 0, "nodes": []],
                "comments": ["totalCount": 0],
                "commits": ["nodes": [["commit": [
                    "oid": oid,
                    "statusCheckRollup": [
                        "state": ciState,
                        "contexts": [
                            "totalCount": 1,
                            "checkRunCountsByState": [["state": ciState, "count": 1]],
                            "statusContextCountsByState": [],
                        ],
                    ],
                ]]]],
            ]
        }

        // 1. Draft PR with conflict & failing CI must NOT raise attention or tint chip red.
        var currentPayload = payload(nodes: [
            prNode(number: 549, isDraft: true, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", ciState: "FAILURE"),
        ])
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(currentPayload) }
        )

        let draftChip = try harness.render("chip")
        #expect(harness.attentionLog.last == false)
        #expect(!draftChip.descendants.contains { $0.component == .badge && $0.string("tone") == "bad" })

        // 2. Non-draft PR with failing CI raises attention until widget is opened.
        harness.advanceTime(seconds: 20)
        currentPayload = payload(nodes: [
            prNode(number: 66594, isDraft: false, ciState: "FAILURE", oid: "aaa111"),
        ])
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == true)

        // Opening the widget immediately clears attention and records seen state.
        _ = try harness.render("widget")
        #expect(harness.attentionLog.last == false)

        // Subsequent poll with the same commit failure stays dismissed and does not spam storage writes.
        let writesAfterView = harness.storageWrites.count
        harness.advanceTime(seconds: 20)
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == false)
        _ = try harness.render("widget")
        #expect(harness.storageWrites.count == writesAfterView)

        // 3. Pushing a new commit (bbb222) that also fails CI re-raises attention.
        harness.advanceTime(seconds: 20)
        currentPayload = payload(nodes: [
            prNode(number: 66594, isDraft: false, ciState: "FAILURE", oid: "bbb222"),
        ])
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == true)
        _ = try harness.render("widget")
        #expect(harness.attentionLog.last == false)

        // 4. Becoming ready raises attention only in 'Blocked + Ready' mode, not default 'Blocked'.
        harness.advanceTime(seconds: 20)
        currentPayload = payload(nodes: [
            prNode(number: 66594, isDraft: false, mergeStateStatus: "CLEAN", ciState: "SUCCESS", oid: "ccc333", reviewState: "APPROVED"),
        ])
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == false)

        try harness.act("setAttentionMode", payload: "Blocked + Ready")
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == true)
        _ = try harness.render("widget")
        #expect(harness.attentionLog.last == false)

        // 5. 'Off' mode suppresses attention even on brand-new conflicts.
        try harness.act("setAttentionMode", payload: "Off")
        harness.advanceTime(seconds: 20)
        currentPayload = payload(nodes: [
            prNode(number: 66594, isDraft: false, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", ciState: "FAILURE", oid: "ddd444"),
        ])
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == false)
    }

    @Test func reviewsAttentionDismissesImmediatelyOnViewAndRespectsMode() throws {
        let source = try #require(loadModuleSource("github-reviews"))

        func teamOnlyPayload() -> String {
            jsonString([
                "data": [
                    "viewer": ["login": "alice"],
                    "reviewRequested": [
                        "nodes": [
                            [
                                "number": 202,
                                "title": "Team review PR",
                                "url": "https://github.com/GoodNotes/infra/pull/202",
                                "isDraft": false,
                                "updatedAt": "2026-11-21T15:00:00Z",
                                "createdAt": "2026-11-21T12:00:00Z",
                                "additions": 40,
                                "deletions": 10,
                                "changedFiles": 2,
                                "reviewDecision": "REVIEW_REQUIRED",
                                "mergeable": "MERGEABLE",
                                "mergeStateStatus": "BLOCKED",
                                "repository": ["nameWithOwner": "GoodNotes/infra", "name": "infra"],
                                "author": ["__typename": "User", "login": "carol"],
                                "assignees": ["nodes": []],
                                "reviewRequests": ["nodes": [
                                    ["requestedReviewer": ["__typename": "Team", "slug": "platform", "combinedSlug": "GoodNotes/platform"]],
                                ]],
                                "latestOpinionatedReviews": ["nodes": []],
                                "reviews": ["nodes": []],
                                "commits": ["nodes": [["commit": ["statusCheckRollup": ["state": "SUCCESS"]]]]],
                            ],
                        ],
                    ],
                    "assigned": ["nodes": []],
                ],
            ])
        }

        // Default mode ('Direct only') stays quiet for team-only requests.
        var currentPayload = teamOnlyPayload()
        let harness = MockModuleHarness(
            source: source,
            execHandler: { _, _ in .success("gho_test_token\n") },
            fetchHandler: { _, _ in .success(currentPayload) }
        )
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == false)

        // Switching to 'All new' raises attention for unseen team PR.
        try harness.act("setAttentionMode", payload: "All new")
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == true)

        // Opening the widget immediately clears attention (without waiting for next chip poll) and avoids redundant writes.
        _ = try harness.render("widget")
        #expect(harness.attentionLog.last == false)
        let writesAfterView = harness.storageWrites.count
        _ = try harness.render("widget")
        #expect(harness.storageWrites.count == writesAfterView)

        // Switching to 'Off' suppresses attention even when a direct request arrives.
        try harness.act("setAttentionMode", payload: "Off")
        harness.advanceTime(seconds: 20)
        currentPayload = sampleReviewsGraphQLResponse()
        _ = try harness.render("chip")
        #expect(harness.attentionLog.last == false)
    }
}
