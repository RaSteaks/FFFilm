#if os(macOS)
import SwiftUI

struct FilmBatchView: View {
    @Bindable var workspace: FilmBatchStore
    @State private var showsSidebar = true
    @State private var showsList = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                batchBar(wide: geometry.size.width >= 1100)
                if let item = workspace.activeItem, item.needsProfile || item.store.error != nil {
                    HStack {
                        Label(item.name + " · " + item.status, systemImage: "exclamationmark.triangle")
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(filmText("查看并处理", "Review issue")) {
                            if geometry.size.width >= 1100 { showsSidebar = true } else { showsList = true }
                        }.controlSize(.small)
                    }.padding(.horizontal, 10).padding(.bottom, 8)
                }
                Divider()
                HStack(spacing: 0) {
                    if geometry.size.width >= 1100 && showsSidebar {
                        scanList.frame(width: 240)
                        Divider()
                    }
                    FilmWorkbenchView(store: workspace.activeStore)
                        .id(workspace.activeID)
                }
                if workspace.queueRunning {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(workspace.completed), total: Double(max(1, workspace.total)))
                            .frame(width: 120)
                        Text(String(format: filmText("处理完成 %d / %d 条", "Processed %d of %d scans"), workspace.completed, workspace.total))
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button(workspace.cancellationRequested ? filmText("正在取消…", "Cancelling…") : filmText("取消剩余任务", "Cancel remaining")) {
                            workspace.cancelQueue()
                        }.disabled(workspace.cancellationRequested)
                    }.padding(10).accessibilityIdentifier("film-batch-progress")
                }
                if !workspace.notice.isEmpty {
                    HStack {
                        Text(workspace.notice).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button(filmText("关闭提示", "Dismiss notice")) { workspace.notice = "" }
                    }.padding(10)
                }
                FilmExportStatusView(controller: workspace.exportController)
            }
        }
        .background(Palette.background)
        .sheet(isPresented: Binding(get: { workspace.exportController.isPresented },
                                    set: { if !$0 { workspace.exportController.dismiss() } }),
               onDismiss: { workspace.exportController.didDismiss() }) {
            FilmExportSheet(controller: workspace.exportController, parentWindow: workspace.window)
        }
        .alert(filmText("操作未完成", "Operation failed"), isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button(filmText("好", "OK")) { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
    }

    private func batchBar(wide: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if wide { showsSidebar.toggle() } else { showsList.toggle() }
            } label: { Label(filmText("胶片列表", "Scans"), systemImage: "sidebar.left") }
                .popover(isPresented: $showsList) { scanList.frame(width: 300, height: 460) }
                .accessibilityIdentifier("film-batch-list")
            Button(filmText("添加扫描…", "Add scans…")) { workspace.openScans() }
                .disabled(!workspace.canAdd).accessibilityIdentifier("film-batch-add")
            Menu(filmText("批量操作", "Batch actions")) {
                Button(filmText("识别已选胶片", "Detect checked scans")) { workspace.detectChecked() }
                    .disabled(workspace.checkedItems.isEmpty || workspace.blocksDocuments || workspace.exportController.isRunning)
                Toggle(filmText("导入后自动框选", "Detect after import"), isOn: $workspace.autoDetect)
                Menu(filmText("已选胶片规格", "Format of checked scans")) {
                    Button(filmText("自动识别", "Automatic")) { workspace.applyFormat(nil) }
                    ForEach(FilmFormat.allCases, id: \.self) { format in
                        Button(format.title) { workspace.applyFormat(format) }
                    }
                }.disabled(workspace.blocksDocuments || workspace.queueRunning || workspace.exportController.isRunning || workspace.checkedItems.isEmpty)
                Divider()
                Button(filmText("保存批次", "Save batch")) { workspace.save() }.disabled(!workspace.canSave || (workspace.items.isEmpty && !workspace.dirty))
                Button(filmText("批次另存为…", "Save batch as…")) { workspace.save(asNew: true) }.disabled(!workspace.canSave || (workspace.items.isEmpty && !workspace.dirty))
                Button(filmText("打开批次或项目…", "Open batch or project…")) { workspace.openProject() }.disabled(!workspace.canSave || workspace.exportController.isRunning)
                Divider()
                Button(filmText("从批次移除当前胶片", "Remove current scan from batch")) { workspace.removeActive() }
                    .disabled(!workspace.canSave || workspace.exportController.isRunning || workspace.activeItem == nil)
                Button(filmText("撤销移除胶片", "Undo scan removal")) { workspace.undoRemoval() }
                    .disabled(!workspace.canSave || !workspace.canUndoRemoval)
            }
            Button { workspace.reviewAndNext() } label: {
                Label(filmText("标记已检查并下一条", "Mark reviewed and next"), systemImage: "checkmark.circle")
            }.labelStyle(.iconOnly).help(filmText("标记已检查并下一条", "Mark reviewed and next"))
                .disabled(workspace.activeItem?.initialized != true || !workspace.activeStore.canImportScan || workspace.activeStore.error != nil)
            Spacer(minLength: 4)
            Text(String(format: filmText("已选 %d / %d 条", "Checked %d / %d scans"), workspace.checkedItems.count, workspace.items.count))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(filmText("导出已选胶片…", "Export checked scans…")) { workspace.openExport() }
                .disabled(workspace.checkedItems.isEmpty || workspace.blocksDocuments || workspace.exportController.isRunning || workspace.queueRunning || workspace.switching || workspace.items.contains { $0.store.busy })
                .accessibilityIdentifier("film-batch-export")
        }.controlSize(.small).padding(10)
    }

    private var scanList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(filmText("胶片", "Scans")).font(.headline)
                Spacer()
                Menu {
                    Button(filmText("全选胶片", "Check all scans")) { workspace.items.forEach { $0.checked = true } }
                    Button(filmText("清除勾选", "Clear checks")) { workspace.items.forEach { $0.checked = false } }
                } label: { Image(systemName: "checklist") }
                    .accessibilityLabel(filmText("胶片勾选", "Scan selection"))
                    .disabled(workspace.blocksDocuments)
            }
            Toggle(filmText("仅显示待检查及异常", "Show unreviewed and issues"), isOn: $workspace.onlyNeedsAttention)
                .font(.caption)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.visibleItems) { item in
                        FilmBatchRow(item: item, workspace: workspace)
                    }
                    if workspace.visibleItems.isEmpty {
                        Text(workspace.items.isEmpty ? filmText("添加 TIFF / FFF 扫描开始处理。", "Add TIFF / FFF scans to begin.")
                             : filmText("没有待检查的胶片。", "No scans need review."))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            if workspace.checkedItems.contains(where: \.needsProfile) {
                Menu(filmText("为已选未标记文件指定配置", "Assign profile to checked untagged scans")) {
                    ForEach(["sRGB", "Adobe RGB", "Linear sRGB", "Display P3"], id: \.self) { name in
                        Button(name) { workspace.applyProfile(name) }
                    }
                    Button(filmText("选择 ICC…", "Choose ICC…")) { workspace.chooseProfile() }
                }.disabled(workspace.blocksDocuments)
                Text(filmText("请选择扫描软件实际输出的 RGB 配置。", "Choose the scanner software's actual RGB output profile."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(filmText("标记已检查并下一条", "Mark reviewed and next")) { workspace.reviewAndNext() }
                .disabled(workspace.activeItem?.initialized != true || !workspace.activeStore.canImportScan || workspace.activeStore.error != nil)
                .accessibilityIdentifier("film-batch-review-next")
            HStack {
                Button(filmText("上一条", "Previous")) { navigate(-1) }
                Button(filmText("下一条", "Next")) { navigate(1) }
            }.disabled(workspace.items.count < 2 || workspace.switching || workspace.blocksDocuments)
        }.padding(10).background(Palette.surface)
    }
    private func navigate(_ offset: Int) {
        guard let index = workspace.items.firstIndex(where: { $0.id == workspace.activeID }),
              workspace.items.indices.contains(index + offset) else { return }
        workspace.select(workspace.items[index + offset])
    }
}

private struct FilmBatchRow: View {
    @Bindable var item: FilmBatchItem
    let workspace: FilmBatchStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Toggle(isOn: $item.checked) { Text(item.name) }.labelsHidden()
                    .accessibilityLabel(filmText("勾选胶片：", "Check scan: ") + item.name)
                    .disabled(workspace.blocksDocuments)
                Button { workspace.select(item) } label: {
                    HStack(spacing: 8) {
                        if let overview = item.store.overview {
                            Image(decorative: overview, scale: 1).resizable().scaledToFit().frame(width: 30, height: 44)
                        } else { Image(systemName: "film").frame(width: 30, height: 44) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).lineLimit(1).truncationMode(.middle).help(item.store.project.sourcePath)
                            Text(item.status).font(.caption).foregroundStyle(.secondary)
                            if item.initialized {
                                Text(String(format: filmText("%d 帧", "%d frames"), item.store.project.frames.count))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(workspace.blocksDocuments || workspace.switching)
                    .accessibilityAddTraits(workspace.activeID == item.id ? .isSelected : [])
            }
            if let error = item.store.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(filmText("重试", "Retry")) { workspace.retry(item) }
                    Button(filmText("重新定位…", "Locate…")) { workspace.locate(item) }
                }.controlSize(.small).disabled(item.queued || item.store.busy || workspace.blocksDocuments)
                if item.initialized && !item.store.sourceSuspended {
                    Button(filmText("使用现有片框继续编辑", "Continue with existing frames")) { item.store.error = nil }
                        .controlSize(.small).disabled(item.queued || item.store.busy || workspace.blocksDocuments)
                }
            } else if !item.initialized && !item.queued && !item.needsProfile {
                Button(filmText("继续加载", "Resume loading")) { workspace.retry(item) }.controlSize(.small)
            }
        }.padding(8)
            .background(workspace.activeID == item.id ? Palette.controlSurface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("film-batch-scan")
    }
}
#endif
