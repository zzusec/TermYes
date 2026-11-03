import AppKit

@main
struct MenuPresentationTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() {
        _ = NSApplication.shared
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        for input in ["pi · v1.5.0", "待实测", "  第一行\n第二行\t第三行  ",
                      String(repeating: "很长的版本信息", count: 100),
                      String(repeating: "W", count: 1000),
                      String(repeating: "👩🏽‍💻é", count: 100)] {
            let title = MenuPresentation.title(input)
            expect(!title.contains("\n") && !title.contains("\t"), "Native menu titles must remain single-line")
            expect((title as NSString).size(withAttributes: attributes).width <= MenuPresentation.maximumTitleWidth,
                   "Native menu title exceeds the pixel-width budget")
        }
        expect(MenuPresentation.title("pi · v1.5.0") == "pi · v1.5.0", "Short titles must not change")
        expect(MenuPresentation.title(String(repeating: "W", count: 100)).hasSuffix("…"), "Long titles must visibly truncate")

        for count in [0, 1, 6, 7, 13, 100] {
            let input = Array(0..<count)
            var remaining = input
            var collected: [Int] = []
            repeat {
                let page = MenuPresentation.page(remaining)
                expect(page.visible.count <= 6, "A page must not grow vertically with the Agent count")
                collected += page.visible
                remaining = page.remaining
            } while !remaining.isEmpty
            expect(collected == input, "Pagination must preserve every Agent in order")
        }

        // Native AppKit measurement catches padding/arrow/icon costs that a
        // SwiftUI .frame modifier on a menu Text does not constrain.
        let menu = NSMenu()
        for title in ["全部实测（模型请求）", "修复配置（13）", "刷新状态"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        for _ in 0..<MenuPresentation.agentsPerPage {
            let item = NSMenuItem(title: MenuPresentation.title(String(repeating: "Agent 很长版本", count: 20)), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)
            item.submenu = NSMenu()
            menu.addItem(item)
        }
        let more = NSMenuItem(title: "更多 Agent", action: nil, keyEquivalent: "")
        more.submenu = NSMenu()
        menu.addItem(more)
        menu.addItem(.separator())
        let nestedUpdates = NSMenuItem(title: "更新", action: nil, keyEquivalent: "")
        nestedUpdates.submenu = NSMenu()
        menu.addItem(nestedUpdates)
        expect(menu.size.width > 0 && menu.size.height > 0, "Native menu must actually lay out")
        expect(menu.size.width <= MenuPresentation.maximumMenuSize.width, "Native menu is too wide: \(menu.size)")
        expect(menu.size.height <= MenuPresentation.maximumMenuSize.height, "Native menu is too tall: \(menu.size)")
        expect(!menu.items.contains { $0.title.contains("状态详情") }, "状态详情 must not return as a menu entry")

        let liveNames = [
            "Claude Code · v2.1.317",
            "CodeBuddy · v2.179.3",
            "Codex · v0.166.0",
            "OpenCode · v1.19.5",
            "agy · v1.4.12",
            "pi · v1.5.0",
            "zcode · v3.14.3",
        ]
        let root = productionRootMenu(agentNames: liveNames)
        let guardMenu = root.items.first { $0.title == "命令守卫" }?.submenu
        let moreMenu = guardMenu?.items.first { $0.title == "更多 Agent" }?.submenu
        let updateMenu = guardMenu?.items.first { $0.title == "更新" }?.submenu
        let agentMenu = guardMenu?.items.first { $0.title.hasPrefix("Claude Code") }?.submenu
        expect(guardMenu != nil && moreMenu != nil && updateMenu != nil && agentMenu != nil, "Production menus must include nested Command Guard entries")
        expect(guardMenu?.items.contains { $0.title.contains("状态详情") } != true, "Command Guard must not expose 状态详情")
        expect(moreMenu?.items.contains { $0.title.contains("zcode") } == true, "The 7th Agent must move into 更多 Agent")
        expect(!(guardMenu?.items.contains { $0.title.contains("zcode") } ?? true), "Command Guard must not list more than six Agents")
        for named in [
            ("主菜单", root),
            ("命令守卫", guardMenu!),
            ("更多 Agent", moreMenu!),
            ("更新", updateMenu!),
            ("Agent", agentMenu!),
        ] {
            expect(named.1.size.width <= MenuPresentation.maximumMenuSize.width, "\(named.0) is too wide: \(named.1.size)")
            expect(named.1.size.height <= MenuPresentation.maximumMenuSize.height, "\(named.0) is too tall: \(named.1.size)")
        }

        for detail in ["short error", String(repeating: "\n", count: 1000), String(repeating: "https://example.invalid/long-path", count: 1000)] {
            let alert = MenuPresentation.detailsAlert(title: String(repeating: "更新失败", count: 100), detail: detail)
            alert.layout()
            expect(alert.window.frame.width <= MenuPresentation.maximumDetailSize.width,
                   "Detail window is too wide: \(alert.window.frame.size)")
            expect(alert.window.frame.height <= MenuPresentation.maximumDetailSize.height,
                   "Detail window is too tall: \(alert.window.frame.size)")
            let scroll = alert.accessoryView as? NSScrollView
            expect(scroll?.frame.size == MenuPresentation.detailViewportSize, "Detail viewport must have a fixed size")
            expect((scroll?.documentView as? NSTextView)?.string == detail, "Full details must remain available without enlarging the window")
        }
        print("Menu presentation tests passed (native size \(menu.size), production Command Guard \(guardMenu!.size), title truncation, bounded Agent pages, fixed scrolling details).")
    }

    @MainActor
    static func productionRootMenu(agentNames: [String]) -> NSMenu {
        let root = NSMenu()
        let arrange = NSMenuItem(title: "自动排列", action: nil, keyEquivalent: "")
        arrange.submenu = NSMenu()
        root.addItem(arrange)
        let guardItem = NSMenuItem(title: "命令守卫", action: nil, keyEquivalent: "")
        guardItem.submenu = productionCommandGuardMenu(agentNames: agentNames)
        root.addItem(guardItem)
        root.addItem(.separator())
        root.addItem(withTitle: "登录时自动启动", action: nil, keyEquivalent: "")
        root.addItem(withTitle: MenuPresentation.title("版本 v1.6.37"), action: nil, keyEquivalent: "")
        root.addItem(withTitle: "检查更新", action: nil, keyEquivalent: "")
        root.addItem(.separator())
        root.addItem(withTitle: "退出 TermYes", action: nil, keyEquivalent: "")
        return root
    }

    @MainActor
    static func productionCommandGuardMenu(agentNames: [String]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "全部实测（模型请求）", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "刷新状态", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        addAgentPages(to: menu, agentNames: agentNames)
        menu.addItem(.separator())
        let updates = NSMenuItem(title: "更新", action: nil, keyEquivalent: "")
        let updateMenu = NSMenu()
        updateMenu.addItem(withTitle: MenuPresentation.title("危险清单 v3"), action: nil, keyEquivalent: "")
        updateMenu.addItem(withTitle: "更新清单", action: nil, keyEquivalent: "")
        updateMenu.addItem(.separator())
        updateMenu.addItem(withTitle: "更新 Agent 与扩展", action: nil, keyEquivalent: "")
        updateMenu.addItem(withTitle: "更新详情…", action: nil, keyEquivalent: "")
        updates.submenu = updateMenu
        menu.addItem(updates)
        return menu
    }

    @MainActor
    static func addAgentPages(to menu: NSMenu, agentNames: [String]) {
        let page = MenuPresentation.page(agentNames)
        for name in page.visible {
            let item = NSMenuItem(title: MenuPresentation.title(name), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "checkmark.square.fill", accessibilityDescription: nil)
            let submenu = NSMenu()
            submenu.addItem(withTitle: MenuPresentation.title("\(name) · 本机最新"), action: nil, keyEquivalent: "")
            submenu.addItem(withTitle: "实测通过", action: nil, keyEquivalent: "")
            submenu.addItem(.separator())
            submenu.addItem(withTitle: "暂停 15 分钟", action: nil, keyEquivalent: "")
            submenu.addItem(withTitle: "暂停 1 小时", action: nil, keyEquivalent: "")
            submenu.addItem(.separator())
            submenu.addItem(withTitle: "实测（模型请求）", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if !page.remaining.isEmpty {
            let more = NSMenuItem(title: "更多 Agent", action: nil, keyEquivalent: "")
            let nested = NSMenu()
            addAgentPages(to: nested, agentNames: page.remaining)
            more.submenu = nested
            menu.addItem(more)
        }
    }
}
