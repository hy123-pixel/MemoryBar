import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published var errorMessage: String?

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var statusDescription: String {
        switch status {
        case .enabled:
            return "已开启"
        case .requiresApproval:
            return "等待系统设置批准"
        case .notRegistered:
            return "已关闭"
        case .notFound:
            return "状态不可用"
        @unknown default:
            return "状态未知"
        }
    }

    func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                refreshStatus()
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
                refreshStatus()
            }
        } catch {
            refreshStatus()
            errorMessage = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
