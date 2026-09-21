import SwiftUI

/// AppStorage shares the preference across windows and retains it after relaunch.
struct SettingsView: View {
    @AppStorage(StorageUnit.preferenceKey) private var unit: StorageUnit = .decimal

    var body: some View {
        Form {
            Section {
                Picker("默认容量单位", selection: $unit) {
                    ForEach(StorageUnit.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("storage-unit-picker")
                Text("选择后立即生效，并在下次启动时保留。")
                    .foregroundStyle(.secondary)
                // Keep collapsed explanations in the same section as the capacity preference.
                DisclosureGroup("详情") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1000 与 1024 的区别").font(.headline)
                        Text("1000 进制（十进制）\n1 GB = 1000 MB = 1,000,000,000 字节。macOS、iOS 的存储容量显示和硬盘、存储卡厂商通常采用这种方式。")
                        Text("1024 进制（二进制）\n严格写法是 1 GiB = 1024 MiB = 1,073,741,824 字节。Windows 文件资源管理器常用二进制计算，但仍标为 GB、MB。本软件使用 GiB、MiB 避免混淆。")
                        Text("这两种方式并非某个系统专属。MB 表示兆字节，Mb 表示兆比特；1 字节 = 8 比特。")
                        Divider()
                        Text("对计算结果的影响").font(.headline)
                        Text("每小时数据量、每日总量和固定对比会使用所选单位。存储卡选项保留厂商标称容量（十进制）；码率 Mb/s、实际可录时长和容量占用百分比不变。")
                        Link("Apple：存储容量的计算方式", destination: URL(string: "https://support.apple.com/en-us/102119")!)
                        Link("Microsoft：Windows 的二进制单位标注", destination: URL(string: "https://devblogs.microsoft.com/oldnewthing/20090611-00/?p=17933")!)
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("storage-unit-details")
            } header: { Text("容量换算") }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(width: 560, height: 580)
        #endif
    }
}

/// Native settings window on Mac; a dismissible navigation sheet on touch platforms.
struct SettingsButton: View {
    #if !os(macOS)
    @State private var isPresented = false
    #endif
    var body: some View {
        #if os(macOS)
        SettingsLink { Label("设置", systemImage: "gearshape") }
            .help("设置 (⌘,)")
            .accessibilityIdentifier("settings-action")
        #else
        Button { isPresented = true } label: {
            Label("设置", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("settings-action")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { isPresented = false }
                        }
                    }
            }
        }
        #endif
    }
}
