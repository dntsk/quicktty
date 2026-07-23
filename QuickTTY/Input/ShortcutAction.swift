enum ShortcutActionScope: Equatable, Hashable, Sendable {
    case application
    case tabPane
    case workspace
    case terminal
}

enum ShortcutTargetPolicy: Equatable, Hashable, Sendable {
    case application
    case activeWindow
    case activeTab
    case focusedPane
}

enum ShortcutMenuPolicy: Equatable, Hashable, Sendable {
    case command
    case responderOnly
}

enum ShortcutPerformPolicy: Equatable, Hashable, Sendable {
    case consume
    case passThroughWhenUnperformed

    func consumes(performed: Bool) -> Bool {
        switch self {
        case .consume: true
        case .passThroughWhenUnperformed: performed
        }
    }
}

enum ShortcutExecutionRoute: Equatable, Hashable, Sendable {
    case application
    case tabPane
    case workspace
    case terminal(TerminalShortcutAction)
}

enum TerminalShortcutAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case copy
    case paste
    case pasteSelection = "paste-selection"
    case selectAll = "select-all"
    case copyURL = "copy-url"
    case clearScreen = "clear-screen"
    case resetTerminal = "reset-terminal"
    case fontIncrease = "font-increase"
    case fontDecrease = "font-decrease"
    case fontReset = "font-reset"
    case scrollTop = "scroll-top"
    case scrollBottom = "scroll-bottom"
    case scrollPageUp = "scroll-page-up"
    case scrollPageDown = "scroll-page-down"
    case scrollToSelection = "scroll-to-selection"
    case previousPrompt = "previous-prompt"
    case nextPrompt = "next-prompt"
    case selectionLeft = "selection-left"
    case selectionRight = "selection-right"
    case selectionUp = "selection-up"
    case selectionDown = "selection-down"
    case selectionPageUp = "selection-page-up"
    case selectionPageDown = "selection-page-down"
    case selectionHome = "selection-home"
    case selectionEnd = "selection-end"

    var coreAction: String {
        switch self {
        case .copy: "copy_to_clipboard"
        case .paste: "paste_from_clipboard"
        case .pasteSelection: "paste_from_selection"
        case .selectAll: "select_all"
        case .copyURL: "copy_url_to_clipboard"
        case .clearScreen: "clear_screen"
        case .resetTerminal: "reset"
        case .fontIncrease: "increase_font_size:1"
        case .fontDecrease: "decrease_font_size:1"
        case .fontReset: "reset_font_size"
        case .scrollTop: "scroll_to_top"
        case .scrollBottom: "scroll_to_bottom"
        case .scrollPageUp: "scroll_page_up"
        case .scrollPageDown: "scroll_page_down"
        case .scrollToSelection: "scroll_to_selection"
        case .previousPrompt: "jump_to_prompt:-1"
        case .nextPrompt: "jump_to_prompt:1"
        case .selectionLeft: "adjust_selection:left"
        case .selectionRight: "adjust_selection:right"
        case .selectionUp: "adjust_selection:up"
        case .selectionDown: "adjust_selection:down"
        case .selectionPageUp: "adjust_selection:page_up"
        case .selectionPageDown: "adjust_selection:page_down"
        case .selectionHome: "adjust_selection:home"
        case .selectionEnd: "adjust_selection:end"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case quit
    case openConfig = "open-config"
    case togglePresentation = "toggle-presentation"
    case newTab = "new-tab"
    case closePane = "close-pane"
    case closeTab = "close-tab"
    case splitRight = "split-right"
    case splitDown = "split-down"
    case previousPane = "previous-pane"
    case nextPane = "next-pane"
    case focusLeft = "focus-left"
    case focusRight = "focus-right"
    case focusUp = "focus-up"
    case focusDown = "focus-down"
    case selectTab1 = "select-tab-1"
    case selectTab2 = "select-tab-2"
    case selectTab3 = "select-tab-3"
    case selectTab4 = "select-tab-4"
    case selectTab5 = "select-tab-5"
    case selectTab6 = "select-tab-6"
    case selectTab7 = "select-tab-7"
    case selectTab8 = "select-tab-8"
    case selectTab9 = "select-tab-9"
    case toggleBroadcast = "toggle-broadcast"
    case newWorkspace = "new-workspace"
    case renameWorkspace = "rename-workspace"
    case deleteWorkspace = "delete-workspace"
    case selectWorkspace1 = "select-workspace-1"
    case selectWorkspace2 = "select-workspace-2"
    case selectWorkspace3 = "select-workspace-3"
    case selectWorkspace4 = "select-workspace-4"
    case selectWorkspace5 = "select-workspace-5"
    case selectWorkspace6 = "select-workspace-6"
    case selectWorkspace7 = "select-workspace-7"
    case selectWorkspace8 = "select-workspace-8"
    case selectWorkspace9 = "select-workspace-9"
    case copy
    case paste
    case pasteSelection = "paste-selection"
    case selectAll = "select-all"
    case copyURL = "copy-url"
    case clearScreen = "clear-screen"
    case resetTerminal = "reset-terminal"
    case fontIncrease = "font-increase"
    case fontDecrease = "font-decrease"
    case fontReset = "font-reset"
    case scrollTop = "scroll-top"
    case scrollBottom = "scroll-bottom"
    case scrollPageUp = "scroll-page-up"
    case scrollPageDown = "scroll-page-down"
    case scrollToSelection = "scroll-to-selection"
    case previousPrompt = "previous-prompt"
    case nextPrompt = "next-prompt"
    case selectionLeft = "selection-left"
    case selectionRight = "selection-right"
    case selectionUp = "selection-up"
    case selectionDown = "selection-down"
    case selectionPageUp = "selection-page-up"
    case selectionPageDown = "selection-page-down"
    case selectionHome = "selection-home"
    case selectionEnd = "selection-end"

    var defaultChord: ShortcutChord? {
        switch self {
        case .quit: chord(.q, .command)
        case .openConfig: chord(.comma, .command)
        case .togglePresentation: chord(.p, .command, .option)
        case .newTab: chord(.t, .command)
        case .closePane: chord(.w, .command)
        case .closeTab: chord(.w, .command, .option)
        case .splitRight: chord(.d, .command)
        case .splitDown: chord(.d, .command, .shift)
        case .previousPane: chord(.leftBracket, .command)
        case .nextPane: chord(.rightBracket, .command)
        case .focusLeft: chord(.left, .command, .option)
        case .focusRight: chord(.right, .command, .option)
        case .focusUp: chord(.up, .command, .option)
        case .focusDown: chord(.down, .command, .option)
        case .selectTab1: chord(.one, .command)
        case .selectTab2: chord(.two, .command)
        case .selectTab3: chord(.three, .command)
        case .selectTab4: chord(.four, .command)
        case .selectTab5: chord(.five, .command)
        case .selectTab6: chord(.six, .command)
        case .selectTab7: chord(.seven, .command)
        case .selectTab8: chord(.eight, .command)
        case .selectTab9: chord(.nine, .command)
        case .toggleBroadcast: chord(.b, .command)
        case .newWorkspace, .renameWorkspace, .deleteWorkspace, .copyURL, .resetTerminal:
            nil
        case .selectWorkspace1: chord(.one, .command, .option)
        case .selectWorkspace2: chord(.two, .command, .option)
        case .selectWorkspace3: chord(.three, .command, .option)
        case .selectWorkspace4: chord(.four, .command, .option)
        case .selectWorkspace5: chord(.five, .command, .option)
        case .selectWorkspace6: chord(.six, .command, .option)
        case .selectWorkspace7: chord(.seven, .command, .option)
        case .selectWorkspace8: chord(.eight, .command, .option)
        case .selectWorkspace9: chord(.nine, .command, .option)
        case .copy: chord(.c, .command)
        case .paste: chord(.v, .command)
        case .pasteSelection: chord(.v, .command, .shift)
        case .selectAll: chord(.a, .command)
        case .clearScreen: chord(.k, .command)
        case .fontIncrease: chord(.equal, .command)
        case .fontDecrease: chord(.minus, .command)
        case .fontReset: chord(.zero, .command)
        case .scrollTop: chord(.home, .command)
        case .scrollBottom: chord(.end, .command)
        case .scrollPageUp: chord(.pageUp, .command)
        case .scrollPageDown: chord(.pageDown, .command)
        case .scrollToSelection: chord(.j, .command)
        case .previousPrompt: chord(.up, .command, .shift)
        case .nextPrompt: chord(.down, .command, .shift)
        case .selectionLeft: chord(.left, .shift)
        case .selectionRight: chord(.right, .shift)
        case .selectionUp: chord(.up, .shift)
        case .selectionDown: chord(.down, .shift)
        case .selectionPageUp: chord(.pageUp, .shift)
        case .selectionPageDown: chord(.pageDown, .shift)
        case .selectionHome: chord(.home, .shift)
        case .selectionEnd: chord(.end, .shift)
        }
    }

    var scope: ShortcutActionScope {
        if TerminalShortcutAction(rawValue: rawValue) != nil {
            return .terminal
        }
        switch self {
        case .quit, .openConfig, .togglePresentation:
            return .application
        case .newWorkspace, .renameWorkspace, .deleteWorkspace,
            .selectWorkspace1, .selectWorkspace2, .selectWorkspace3, .selectWorkspace4,
            .selectWorkspace5, .selectWorkspace6, .selectWorkspace7, .selectWorkspace8,
            .selectWorkspace9:
            return .workspace
        default:
            return .tabPane
        }
    }

    var targetPolicy: ShortcutTargetPolicy {
        switch scope {
        case .application:
            .application
        case .tabPane, .workspace:
            .activeWindow
        case .terminal:
            switch self {
            case .paste, .pasteSelection: .activeTab
            default: .focusedPane
            }
        }
    }

    var executionRoute: ShortcutExecutionRoute {
        if let terminalAction = TerminalShortcutAction(rawValue: rawValue) {
            return .terminal(terminalAction)
        }
        switch scope {
        case .application: return .application
        case .tabPane: return .tabPane
        case .workspace: return .workspace
        case .terminal: preconditionFailure("Terminal actions have a typed route")
        }
    }

    var performPolicy: ShortcutPerformPolicy {
        switch self {
        case .copy, .copyURL, .clearScreen, .scrollToSelection,
            .selectionLeft, .selectionRight, .selectionUp, .selectionDown,
            .selectionPageUp, .selectionPageDown, .selectionHome, .selectionEnd:
            .passThroughWhenUnperformed
        default:
            .consume
        }
    }

    var menuPolicy: ShortcutMenuPolicy {
        performPolicy == .passThroughWhenUnperformed ? .responderOnly : .command
    }

    var index: Int? {
        switch self {
        case .selectTab1, .selectWorkspace1: 1
        case .selectTab2, .selectWorkspace2: 2
        case .selectTab3, .selectWorkspace3: 3
        case .selectTab4, .selectWorkspace4: 4
        case .selectTab5, .selectWorkspace5: 5
        case .selectTab6, .selectWorkspace6: 6
        case .selectTab7, .selectWorkspace7: 7
        case .selectTab8, .selectWorkspace8: 8
        case .selectTab9, .selectWorkspace9: 9
        default: nil
        }
    }

    private func chord(
        _ key: ShortcutKey,
        _ modifiers: ShortcutModifier...
    ) -> ShortcutChord {
        ShortcutChord(key: key, modifiers: Set(modifiers))
    }
}
