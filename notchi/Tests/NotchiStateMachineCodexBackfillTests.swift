import Foundation
import XCTest
@testable import notchi

final class NotchiStateMachineCodexBackfillTests: XCTestCase {
    func testDiscoverCodexBackfillSeedsExtractsSessionMetadata() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }

        let sessionId = "019d1111-2222-3333-4444-555566667777"
        let filename = "rollout-2026-03-26T10-00-00-\(sessionId).jsonl"
        let transcript = try writeTranscript(
            root: root,
            relativePath: "2026/03/26/\(filename)",
            records: [
                [
                    "type": "turn_context",
                    "payload": [
                        "cwd": "/tmp/project-a",
                    ],
                ],
                [
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": "Fix the flaky test",
                            ],
                        ],
                    ],
                ],
            ],
            modifiedAt: Date().addingTimeInterval(-20)
        )

        let seeds = NotchiStateMachine.discoverCodexBackfillSeeds(
            rootURL: root,
            since: Date().addingTimeInterval(-120),
            maxCount: 5
        )

        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.sessionId, sessionId)
        XCTAssertEqual(seeds.first?.cwd, "/tmp/project-a")
        XCTAssertEqual(seeds.first?.userPrompt, "Fix the flaky test")
        let actualPath = seeds.first.map { URL(fileURLWithPath: $0.transcriptPath).resolvingSymlinksInPath().path }
        let expectedPath = transcript.resolvingSymlinksInPath().path
        XCTAssertEqual(actualPath, expectedPath)
    }

    func testDiscoverCodexBackfillSeedsUsesUserMessageEventFallback() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }

        let sessionId = "019d8888-9999-aaaa-bbbb-ccccddddeeee"
        _ = try writeTranscript(
            root: root,
            relativePath: "2026/03/26/rollout-2026-03-26T10-01-00-\(sessionId).jsonl",
            records: [
                [
                    "type": "turn_context",
                    "payload": [
                        "cwd": "/tmp/project-b",
                    ],
                ],
                [
                    "type": "event_msg",
                    "payload": [
                        "type": "user_message",
                        "message": "Prompt from event payload",
                    ],
                ],
            ],
            modifiedAt: Date().addingTimeInterval(-15)
        )

        let seeds = NotchiStateMachine.discoverCodexBackfillSeeds(
            rootURL: root,
            since: Date().addingTimeInterval(-120),
            maxCount: 5
        )

        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.userPrompt, "Prompt from event payload")
    }

    func testDiscoverCodexBackfillSeedsRespectsCutoffAndMaxCount() throws {
        let root = try makeSessionsRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }

        let oldId = "019d0000-0000-0000-0000-000000000000"
        let midId = "019d0000-0000-0000-0000-000000000001"
        let newestId = "019d0000-0000-0000-0000-000000000002"
        let now = Date()

        _ = try writeTranscript(
            root: root,
            relativePath: "2026/03/26/rollout-2026-03-26T09-00-00-\(oldId).jsonl",
            records: [[
                "type": "turn_context",
                "payload": [
                    "cwd": "/tmp/old",
                ],
            ]],
            modifiedAt: now.addingTimeInterval(-600)
        )
        _ = try writeTranscript(
            root: root,
            relativePath: "2026/03/26/rollout-2026-03-26T10-00-00-\(midId).jsonl",
            records: [[
                "type": "turn_context",
                "payload": [
                    "cwd": "/tmp/mid",
                ],
            ]],
            modifiedAt: now.addingTimeInterval(-60)
        )
        _ = try writeTranscript(
            root: root,
            relativePath: "2026/03/26/rollout-2026-03-26T10-02-00-\(newestId).jsonl",
            records: [[
                "type": "turn_context",
                "payload": [
                    "cwd": "/tmp/newest",
                ],
            ]],
            modifiedAt: now.addingTimeInterval(-30)
        )

        let seeds = NotchiStateMachine.discoverCodexBackfillSeeds(
            rootURL: root,
            since: now.addingTimeInterval(-180),
            maxCount: 1
        )

        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.sessionId, newestId)
        XCTAssertEqual(seeds.first?.cwd, "/tmp/newest")
    }

    private func makeSessionsRoot() throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-codex-backfill-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return sessionsRoot
    }

    private func writeTranscript(
        root: URL,
        relativePath: String,
        records: [[String: Any]],
        modifiedAt: Date
    ) throws -> URL {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let lines = try records.map { record -> String in
            let data = try JSONSerialization.data(withJSONObject: record)
            guard let line = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "NotchiStateMachineCodexBackfillTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON line"]
                )
            }
            return line
        }

        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: fileURL.path
        )

        return fileURL
    }
}
