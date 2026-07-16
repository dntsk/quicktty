import AppKit
import Foundation

struct WorkspaceNameValidator {
    enum ValidationError: Error, Equatable {
        case empty
        case duplicate
    }

    static func validate(_ name: String, existingNames: [String]) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError.empty }
        let foldedName = fold(trimmedName)
        guard !existingNames.contains(where: { fold($0) == foldedName }) else {
            throw ValidationError.duplicate
        }
        return trimmedName
    }

    private static func fold(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
final class CreateWorkspaceController: NSWindowController, NSTextFieldDelegate {
    typealias Submit = (String) -> Result<Void, WorkspaceError>

    var onDismiss: (() -> Void)?

    private let existingNames: () -> [String]
    private let submit: Submit
    private let nameField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private weak var parentWindow: NSWindow?

    init(existingNames: @escaping () -> [String], submit: @escaping Submit) {
        self.existingNames = existingNames
        self.submit = submit

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 176),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Workspace"
        super.init(window: panel)
        configureContent()
    }

    func presentSheet(for parentWindow: NSWindow) {
        self.parentWindow = parentWindow
        parentWindow.beginSheet(window!)
        window?.makeFirstResponder(nameField)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateValidation(showEmptyError: false)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        let prompt = NSTextField(labelWithString: "Workspace name")
        prompt.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        prompt.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "Backend"
        nameField.delegate = self
        nameField.identifier = NSUserInterfaceItemIdentifier("workspace-name")
        nameField.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.identifier = NSUserInterfaceItemIdentifier("workspace-name-error")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        createButton.target = self
        createButton.action = #selector(createWorkspace)
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false
        createButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(prompt)
        contentView.addSubview(nameField)
        contentView.addSubview(errorLabel)
        contentView.addSubview(cancelButton)
        contentView.addSubview(createButton)
        NSLayoutConstraint.activate([
            prompt.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            prompt.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            prompt.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            nameField.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: prompt.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: prompt.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: prompt.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: prompt.trailingAnchor),
            createButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -20),
            createButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(
                equalTo: createButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
        ])
    }

    private func updateValidation(showEmptyError: Bool) {
        do {
            _ = try WorkspaceNameValidator.validate(
                nameField.stringValue,
                existingNames: existingNames()
            )
            errorLabel.stringValue = ""
            createButton.isEnabled = true
        } catch WorkspaceNameValidator.ValidationError.empty {
            errorLabel.stringValue = showEmptyError ? "Workspace name is required." : ""
            createButton.isEnabled = false
        } catch WorkspaceNameValidator.ValidationError.duplicate {
            errorLabel.stringValue = "A workspace with this name already exists."
            createButton.isEnabled = false
        } catch {
            errorLabel.stringValue = "The workspace name is invalid."
            createButton.isEnabled = false
        }
    }

    @objc private func createWorkspace() {
        let name: String
        do {
            name = try WorkspaceNameValidator.validate(
                nameField.stringValue,
                existingNames: existingNames()
            )
        } catch {
            updateValidation(showEmptyError: true)
            return
        }

        switch submit(name) {
        case .success:
            dismiss()
        case .failure(.emptyWorkspaceName):
            errorLabel.stringValue = "Workspace name is required."
        case .failure(.duplicateWorkspaceName):
            errorLabel.stringValue = "A workspace with this name already exists."
        case .failure:
            errorLabel.stringValue = "The workspace could not be created."
        }
    }

    @objc private func cancel() {
        dismiss()
    }

    private func dismiss() {
        if let parentWindow, let window, window.sheetParent === parentWindow {
            parentWindow.endSheet(window)
        }
        onDismiss?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
