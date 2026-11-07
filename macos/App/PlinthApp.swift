import AppKit
import Darwin
import Foundation

@MainActor
final class ProviderRowController: NSObject {
    let provider: DriveProvider
    let view = NSStackView()

    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "正在检查后端…")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let remove = NSButton(title: "从访达移除", target: nil, action: nil)
    private let refresh = NSButton(title: "刷新", target: nil, action: nil)

    private var backend: ProviderBackendStatus?
    private var registered = false

    init(provider: DriveProvider) {
        self.provider = provider
        super.init()

        title.stringValue = provider.displayName
        title.font = .boldSystemFont(ofSize: 16)

        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)

        refresh.target = self
        refresh.action = #selector(refreshPressed)
        header.addArrangedSubview(refresh)

        primary.target = self
        primary.action = #selector(primaryPressed)
        remove.target = self
        remove.action = #selector(removePressed)

        let actions = NSStackView(views: [primary, remove])
        actions.orientation = .horizontal
        actions.spacing = 8

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 9
        view.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view.addArrangedSubview(header)
        view.addArrangedSubview(actions)
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -28).isActive = true

        render()
    }

    func reload() async {
        do {
            backend = try await ProviderStatusService.shared.status(for: provider)
        } catch {
            backend = nil
        }
        registered = await DriveDomain.isRegistered(provider)
        title.stringValue = backend?.displayName ?? provider.displayName
        render()
    }

    private func render() {
        guard let backend else {
            view.isHidden = true
            return
        }

        guard backend.configured else {
            view.isHidden = true
            return
        }

        view.isHidden = false
        guard backend.healthy else {
            status.stringValue = "后端初始化中"
            primary.isHidden = true
            remove.isHidden = true
            return
        }

        if registered {
            status.stringValue = "已就绪 · 访达已挂载"
            primary.title = "在访达中显示"
            primary.isHidden = false
            remove.isHidden = false
        } else {
            status.stringValue = "已就绪 · 正在自动挂载"
            primary.isHidden = true
            remove.isHidden = true
        }
    }

    @objc private func refreshPressed() {
        Task { await reload() }
    }

    @objc private func primaryPressed() {
        Task {
            guard backend?.healthy == true, registered else { return }
            await DriveDomain.revealInFinder(provider)
        }
    }

    @objc private func removePressed() {
        Task {
            guard registered else { return }
            await DriveDomain.unregister(provider)
            await reload()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var rows: [ProviderRowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        let heading = NSTextField(labelWithString: "Cloud drives")
        heading.font = .boldSystemFont(ofSize: 22)
        stack.addArrangedSubview(heading)

        rows = ProviderCatalog.all.map { ProviderRowController(provider: $0) }
        for row in rows {
            stack.addArrangedSubview(row.view)
            row.view.widthAnchor.constraint(equalToConstant: 520).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 576, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CloudWeft"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            await DriveDomain.registerEnabled()
            for row in rows {
                do {
                    let backend = try await ProviderStatusService.shared.status(for: row.provider)
                    let registered = await DriveDomain.isRegistered(row.provider)
                    if backend.configured && backend.healthy {
                        _ = await DriveDomain.register(row.provider, displayName: backend.displayName)
                    } else if !backend.configured && registered {
                        await DriveDomain.unregister(row.provider)
                    }
                } catch {
                    // Keep existing domains when the backend is temporarily unavailable.
                }
                await row.reload()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PlinthMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--refresh-cloud" {
            guard args.count >= 3,
                  let provider = ProviderCatalog.provider(id: args[2]) else {
                fputs("Usage: Plinth --refresh-cloud <provider-id> [relative-folder ...]\n", stderr)
                Darwin.exit(2)
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                let succeeded = await DriveDomain.refresh(
                    provider, folders: Array(args.dropFirst(3)))
                Darwin.exit(succeeded ? 0 : 1)
            }
            app.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
