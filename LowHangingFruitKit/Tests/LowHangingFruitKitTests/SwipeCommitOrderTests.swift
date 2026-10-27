import Testing
import Foundation

/// The swipe saves first and animates after (hardening plan 2026-10-25, B10:
/// UCR-14).
///
/// `AssignmentCardView.triggerComplete` used to call `onComplete()` only from a
/// delayed block, 0.38 seconds after the gesture (0.18 with reduced motion),
/// and `onComplete` is where the completion is written. A process that ended
/// inside that window lost a tick the student had just been shown. The card now
/// calls `onCommit()` first, ahead of both animation branches.
///
/// SwiftUI cannot run under the package test runner, so this scans source text,
/// the same seam `LoudAlertActionTests` and `VisualStructureTests` use:
/// substrings, not positions or indentation, and a file that cannot be found
/// is a failure, not a pass, because a scan that silently returns guards
/// nothing.
struct SwipeCommitOrderTests {

    private func triggerCompleteBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath)   // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/LowHangingFruitUI/AssignmentCardView.swift")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "\(url.path) is not there, so nothing could be checked")
        let source = try String(contentsOf: url, encoding: .utf8)

        let start = try #require(source.range(of: "private func triggerComplete(state: DueState) {"),
                                 "triggerComplete is gone or was renamed; this scan guards nothing until it is pointed at the new swipe handler")
        let rest = source[start.upperBound...]
        // The method ends where the next declaration begins.
        let end = rest.range(of: "    /// Six small, geometric paper pieces")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("the swipe commits before it animates, on both the reduced-motion path and the full one")
    func commitPrecedesEveryAnimation() throws {
        let body = try triggerCompleteBody()
        let commit = try #require(body.range(of: "onCommit()"), "the swipe no longer calls onCommit, so it saves only after the animation")

        for animation in ["if reduceMotion", "withAnimation(", "DispatchQueue.main.async"] {
            let found = try #require(body.range(of: animation), "\(animation) is gone from triggerComplete; update this scan")
            #expect(commit.lowerBound < found.lowerBound, "onCommit() must come before \(animation)")
        }
    }

    @Test("the commit is behind the one-swipe guard and is made once")
    func commitIsGuardedAndSingle() throws {
        let body = try triggerCompleteBody()
        #expect(body.components(separatedBy: "onCommit()").count - 1 == 1)

        let guardRange = try #require(body.range(of: "guard !isCompleting else { return }"))
        let commit = try #require(body.range(of: "onCommit()"))
        #expect(guardRange.lowerBound < commit.lowerBound,
                "a second swipe on a card that is already leaving must not commit twice")
    }

    @Test("removing the card is still the animation's last step, and never earlier")
    func onCompleteStillFollowsTheAnimation() throws {
        let body = try triggerCompleteBody()
        // `onComplete` takes the card off the list; called early it would take
        // the exit animation with it. Both calls sit inside a delayed block.
        let lines = body.split(separator: "\n").filter { $0.contains("onComplete()") }
        #expect(lines.count == 2)
        for line in lines {
            #expect(line.contains("asyncAfter"), "onComplete() must stay behind its delay: \(line)")
        }
    }
}
