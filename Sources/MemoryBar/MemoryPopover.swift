import AppKit
import SwiftUI

struct MemoryPopover: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var loginItems: LoginItemManager
    @State private var showsBackgroundProcesses = false
    @State private var selectedItemID: String?
    @State private var itemPendingTermination: MemoryItem?
    @State private var showingTerminationConfirmation = false

    private var snapshot: MemorySnapshot { monitor.snapshot }
    private var selectedItem: MemoryItem? {
        snapshot.items.first { $0.id == selectedItemID }
    }
    private var usageFraction: Double {
        guard snapshot.totalBytes > 0 else { return 0 }
        return min(1, Double(snapshot.usedBytes) / Double(snapshot.totalBytes))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listHeader
            processList
            Divider()
            footer
        }
        .frame(width: 380, height: 500)
        .background(.background)
        .onAppear {
            loginItems.refreshStatus()
        }
        .alert("无法更改登录项", isPresented: Binding(
            get: { loginItems.errorMessage != nil },
            set: { if !$0 { loginItems.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { loginItems.errorMessage = nil }
        } message: {
            Text(loginItems.errorMessage ?? "请稍后重试。")
        }
        .confirmationDialog(
            itemPendingTermination.map {
                $0.appURL == nil ? "结束进程“\($0.name)”？" : "强制退出应用“\($0.name)”？"
            } ?? "结束所选项目？",
            isPresented: $showingTerminationConfirmation,
            titleVisibility: .visible
        ) {
            Button(itemPendingTermination?.appURL == nil ? "结束进程" : "强制退出应用", role: .destructive) {
                if let itemPendingTermination {
                    monitor.terminate(itemPendingTermination)
                }
                selectedItemID = nil
                self.itemPendingTermination = nil
            }
            Button("取消", role: .cancel) {
                itemPendingTermination = nil
            }
        } message: {
            Text("结束应用或进程可能导致未保存的数据丢失。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "memorychip.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text("内存使用情况")
                        .font(.headline)
                    Text("系统当前活跃内存占用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(usageFraction * 100))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(usageFraction > 0.85 ? Color.orange : Color.accentColor)
                            .frame(width: proxy.size.width * usageFraction)
                    }
                }
                .frame(height: 7)

                HStack {
                    Text(MemoryMonitor.formattedMemory(snapshot.usedBytes) + " 已使用")
                    Spacer()
                    Text(MemoryMonitor.formattedMemory(snapshot.totalBytes) + " 总内存")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    private var listHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("正在运行的应用")
                    .font(.subheadline.weight(.semibold))
                Text("按物理内存足迹统计，包含辅助进程")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("内存")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if snapshot.applications.isEmpty && snapshot.backgroundProcesses.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "memorychip")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("正在读取应用")
                            .font(.subheadline)
                        Text("应用列表会自动更新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(snapshot.applications) { item in
                        Button {
                            selectedItemID = item.id
                        } label: {
                            memoryRow(item, isSelected: selectedItemID == item.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("强制退出应用", role: .destructive) {
                                requestTermination(item)
                            }
                        }
                    }

                    if !snapshot.backgroundProcesses.isEmpty {
                        DisclosureGroup(isExpanded: $showsBackgroundProcesses) {
                            ForEach(snapshot.backgroundProcesses) { item in
                                Button {
                                    selectedItemID = item.id
                                } label: {
                                    memoryRow(item, isSelected: selectedItemID == item.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("结束进程", role: .destructive) {
                                        requestTermination(item)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text("其他应用进程")
                                Spacer()
                                Text("\(snapshot.backgroundProcesses.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func memoryRow(_ item: MemoryItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 25, height: 25)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if item.appURL == nil {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(MemoryMonitor.formattedMemory(item.bytes))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8)
    }

    private func requestTermination(_ item: MemoryItem) {
        selectedItemID = item.id
        itemPendingTermination = item
        showingTerminationConfirmation = true
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录时启动")
                        .font(.caption)
                    Text(loginItems.statusDescription)
                        .font(.caption2)
                        .foregroundStyle(loginItems.status == .requiresApproval ? .orange : .secondary)
                }
                Spacer()
                if loginItems.status == .requiresApproval {
                    Button("打开设置") {
                        loginItems.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
                Toggle("登录时启动", isOn: Binding(
                    get: { loginItems.isEnabled },
                    set: { loginItems.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 8) {
                Text("更新于 \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(selectedItem?.appURL == nil && selectedItem != nil ? "结束进程" : "强制退出") {
                    guard let selectedItem else { return }
                    requestTermination(selectedItem)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .disabled(selectedItem == nil)
                .help(selectedItem == nil ? "请先选择一行" : "结束选中的项目")
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(monitor.isRefreshing)
                .help("立即刷新")

                Button("活动监视器") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .controlSize(.small)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("退出内存栏")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
