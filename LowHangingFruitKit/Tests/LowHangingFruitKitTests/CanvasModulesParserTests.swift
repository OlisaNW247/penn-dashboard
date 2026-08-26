import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Canvas modules parser")
struct CanvasModulesParserTests {
    // Synthetic fixture only — fake course id, no real Canvas content.
    private let modulesHTML = """
    <div id="context_module_content_1">
      <ul class="context_module_items">
        <li id="module_item_101" class="context_module_item indent_0 assignment">
          <div class="ig-row">
            <span class="item_name">
              <a href="/courses/9001/assignments/501" class="ig-title title item_link" tabindex="0">Reading: Chapter 1</a>
            </span>
            <div class="due_date_display">
              <time datetime="2026-09-01T23:59:00Z">Sep 1 by 11:59pm</time>
            </div>
          </div>
        </li>
        <li id="module_item_102" class="context_module_item indent_0 page">
          <div class="ig-row">
            <span class="item_name">
              <a href="/courses/9001/pages/reading-2">Reading: Chapter 2</a>
            </span>
          </div>
        </li>
      </ul>
    </div>
    """

    @Test("parses titles and, when present, machine-readable due dates")
    func parsesModuleItems() throws {
        let items = CanvasModulesParser.items(from: modulesHTML)

        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.title == "Reading: Chapter 1")
        let dueAt = try #require(first.dueAt)
        #expect(dueAt.timeIntervalSince1970 == 1_788_307_140) // 2026-09-01T23:59:00Z

        let second = items[1]
        #expect(second.title == "Reading: Chapter 2")
        #expect(second.dueAt == nil)
    }

    @Test("unrecognized HTML yields no items, never a crash")
    func garbageHTMLYieldsEmpty() {
        #expect(CanvasModulesParser.items(from: "<div>no modules here</div>").isEmpty)
        #expect(CanvasModulesParser.items(from: "").isEmpty)
    }
}
