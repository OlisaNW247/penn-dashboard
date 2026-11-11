import Foundation
import Testing
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// The review sheet's one status line (2026-11-11): what Canvas takes, or the
/// refusal or outcome in its place; never two at once, never a "checking"
/// caption.
@Suite("Draft review status line")
struct DraftReviewStatusTests {
    typealias S = DraftReviewStatus
    private let c = AgentConnectionCopy.self
    private let fileOnly = CanvasAcceptance.online(text: false, url: false, file: true, extensions: ["pdf"])

    @Test("a spinner, no words, while Canvas is asked")
    func checking() {
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: nil, block: nil, noRouteLeft: false) == .checking)
    }

    @Test("what Canvas takes, alone")
    func takes() {
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: .known(fileOnly), block: nil, noRouteLeft: false)
                == .line("canvas takes a pdf here", .plain))
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: .known(.locked), block: .locked, noRouteLeft: false)
                == .line(c.locked, .plain))
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: .known(.notOnline), block: .notOnline, noRouteLeft: false)
                == .line(c.notOnline, .plain))
    }

    @Test("a refusal for this draft takes the canvas line's place")
    func blockReplaces() {
        let s = S.resolve(outcome: nil, isFinished: false, lookup: .known(fileOnly),
                          block: .fileType(ext: "zip", allowed: ["pdf"]), noRouteLeft: false)
        #expect(s == .line(c.fileTypeRefused("zip", allowed: ["pdf"]), .problem))
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: .known(fileOnly), block: nil, noRouteLeft: true)
                == .line(c.pdfFailed, .problem))
    }

    @Test("an early read that failed says so in the same one line")
    func refusedRead() {
        #expect(S.resolve(outcome: nil, isFinished: false, lookup: .refused(.offline), block: nil, noRouteLeft: false)
                == .line(c.offline, .muted))
    }

    @Test("an outcome replaces whatever was there, in every state")
    func outcomeWins() {
        let lookups: [AgentAcceptanceLookup?] = [nil, .known(fileOnly), .known(.locked), .refused(.preflightFailed)]
        let blocks: [DraftSubmitPlan.Block?] = [nil, .locked, .kind(.url), .fileType(ext: "zip", allowed: [])]
        for lookup in lookups {
            for block in blocks {
                for finished in [false, true] {
                    for noRoute in [false, true] {
                        let s = S.resolve(outcome: c.couldntReach, isFinished: finished, lookup: lookup,
                                          block: block, noRouteLeft: noRoute)
                        #expect(s == .line(c.couldntReach, .problem))
                    }
                }
            }
        }
    }

    @Test("an unconfirmed submit keeps one plain line on the sheet, with open in canvas and done")
    func unconfirmedSubmit() throws {
        let s = S.resolve(outcome: c.submittedUnverified, outcomeTone: .plain, isFinished: true,
                          lookup: .known(fileOnly), block: nil, noRouteLeft: false)
        #expect(s == .line("submitted \u{00B7} check canvas to be sure", .plain))
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LowHangingFruitUI/AgentDraftReviewSheet.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        // Only a verified submit takes the whole sheet.
        #expect(src.contains("if case .result(.submitted(verified: true))? = outcome { submittedState }"))
        #expect(src.contains("case .result(.submitted(verified: false))?: return AgentConnectionCopy.submittedUnverified"))
        // Finished and not verified: open in canvas, then done.
        #expect(src.contains("if let url = canvasURL, outcome != .result(.submitted(verified: true)) {"))
    }

    @Test("once finished with nothing to say, nothing shows")
    func finished() {
        #expect(S.resolve(outcome: nil, isFinished: true, lookup: .known(fileOnly), block: nil, noRouteLeft: false) == .none)
        #expect(S.resolve(outcome: nil, isFinished: true, lookup: nil, block: nil, noRouteLeft: false) == .none)
    }

    @Test("the sheet draws one status view, with no second line beside it")
    func oneLineInTheSheet() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LowHangingFruitUI/AgentDraftReviewSheet.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        #expect(src.components(separatedBy: "statusLine\n").count - 1 == 1, "statusLine placed once")
        for gone in ["canvasLine", "outcomeLine", "AgentConnectionCopy.checking", "pdfCaption",
                     "submittedAt("] {
            #expect(!src.contains(gone), "\(gone)")
        }
        // The integrity line is the confirmation's message, not a sheet line.
        let dialog = try #require(src.range(of: ".confirmationDialog(confirmTitle"))
        let tail = String(src[dialog.upperBound...].prefix(400))
        #expect(tail.contains("message:") && tail.contains("Text(AgentConnectionCopy.integrity)"))
        #expect(src.components(separatedBy: "AgentConnectionCopy.integrity").count - 1 == 1)
    }
}
