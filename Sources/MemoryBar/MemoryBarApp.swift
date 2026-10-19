import AppKit
import Combine
import SwiftUI

@main
struct MemoryBarApp: App {
    @NSApplicationDelegateAdaptor(MemoryBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class MemoryBarAppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: MemoryMonitor!
    private var loginItems: LoginItemManager!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var snapshotObserver: AnyCancellable?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        monitor = MemoryMonitor()
        loginItems = LoginItemManager()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        configurePopover()
        installOutsideClickMonitor()

        snapshotObserver = monitor.$snapshot
            .sink { [weak self] _ in self?.updateStatusButton() }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "内存栏")
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        button.image = image
        button.imagePosition = .imageLeading
        button.font = NSFont.menuBarFont(ofSize: 0)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "内存栏"
        updateStatusButton()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: MemoryPopover(monitor: monitor, loginItems: loginItems)
        )
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let title = monitor?.statusBarMemory ?? ""
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .baselineOffset: -0.75
            ]
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
