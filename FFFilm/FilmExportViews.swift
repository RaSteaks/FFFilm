#if os(macOS)
import SwiftUI
import AppKit

/// Motion shared by the export flow: short, ease-out and never springy. Native sheet
/// presentation keeps its system timing; these cover what the app draws itself.
private enum FilmMotion {
    static let panelIn = Animation.smooth(duration: 0.22)
    static let panelOut = Animation.easeIn(duration: 0.16)
    static let quick = Animation.easeOut(duration: 0.15)
    static let text = Animation.easeOut(duration: 0.12)
    static let expand = Animation.easeOut(duration: 0.2)
    static let progress = Animation.linear(duration: 0.2)

    /// Reduce Motion keeps a brief fade and drops movement, rolling digits and symbol effects.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? quick : animation }
    static func digits(reduceMotion: Bool) -> ContentTransition { reduceMotion ? .identity : .numericText() }
}

/// Presentation only. Naming, filesystem access and job transitions stay in
/// FilmExportController; every control binds to its draft or calls its actions.
///
/// Layout: settings on the left, the resulting files on the right, destination and
/// actions pinned below so they stay reachable when the sheet is short.
struct FilmExportSheet: View {
    @Bindable var controller: FilmExportController
    let parentWindow: NSWindow?
    /// Total frames in the strip, for the "All frames" option. Display only.
    var frameCount: Int?
    /// Disclosure state is view-local; the setting it reveals lives in the controller.
    @State private var numberingExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func motion(_ animation: Animation) -> Animation { FilmMotion.resolve(animation, reduceMotion: reduceMotion) }

    init(controller: FilmExportController, parentWindow: NSWindow?, frameCount: Int? = nil) {
        self.controller = controller
        self.parentWindow = parentWindow
        self.frameCount = frameCount
        _numberingExpanded = State(initialValue: controller.settings.digits != FilmExportSettings().digits)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                settingsForm.frame(minWidth: 290, idealWidth: 310, maxWidth: 350)
                Divider()
                previewPane.frame(minWidth: 290, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 740, minHeight: 400, idealHeight: 560)
        .disabled(controller.isChoosingDirectory)
        // The folder panel sits above this sheet; dim what it is covering.
        .opacity(controller.isChoosingDirectory ? 0.8 : 1)
        .animation(motion(FilmMotion.quick), value: controller.isChoosingDirectory)
        .interactiveDismissDisabled(controller.isChoosingDirectory)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(filmText("导出胶片", "Export film")).font(.headline)
            Spacer(minLength: 12)
            Text(controller.sourceName)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(controller.sourceName)
                .accessibilityLabel(filmText("来源扫描：", "Source scan: ") + controller.sourceName)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Settings

    private var settingsForm: some View {
        Form {
            Section(filmText("范围", "Range")) {
                Picker(filmText("范围", "Range"), selection: $controller.settings.scope) {
                    scopeLabel(filmText("当前帧", "Current frame"), controller.currentName)
                        .tag(Optional(FilmExportScope.current))
                    scopeLabel(filmText("已勾选", "Checked"),
                               String(format: filmText("%d 帧", "%d"), controller.checkedCount))
                        .tag(Optional(FilmExportScope.checked)).disabled(controller.checkedCount == 0)
                    scopeLabel(filmText("全部帧", "All frames"), frameCount.map(String.init))
                        .tag(Optional(FilmExportScope.all))
                    scopeLabel(filmText("整条", "Whole strip"), filmText("单个文件", "one file"))
                        .tag(Optional(FilmExportScope.strip))
                }.pickerStyle(.radioGroup).labelsHidden()
                    .accessibilityIdentifier("film-export-scope")
            }
            Section(filmText("格式", "Format")) {
                Picker(filmText("格式", "Format"), selection: $controller.settings.format) {
                    Text("TIFF").tag(FilmExportFormat.tiff)
                    Text("JPEG").tag(FilmExportFormat.jpeg)
                }.pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("film-export-format")
                if controller.settings.format == .jpeg {
                    // LabeledContent merges this compound value into static text on
                    // macOS 15. Keep both native controls independently accessible.
                    HStack {
                        Text(filmText("质量", "Quality")).accessibilityHidden(true)
                        Spacer()
                        HStack(spacing: 4) {
                            TextField(filmText("JPEG 质量（%）", "JPEG quality (%)"),
                                      value: $controller.settings.qualityPercent, format: .number.grouping(.never))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 48)
                                .font(.body.monospacedDigit())
                                .accessibilityLabel(filmText("JPEG 质量（%）", "JPEG quality (%)"))
                                .accessibilityIdentifier("film-export-quality")
                            Text("%").foregroundStyle(.secondary).accessibilityHidden(true)
                            Stepper(filmText("JPEG 质量（%）", "JPEG quality (%)"),
                                    value: $controller.settings.qualityPercent, in: 10...100, step: 5)
                                .labelsHidden()
                                .accessibilityLabel(filmText("调整 JPEG 质量（%）", "Adjust JPEG quality (%)"))
                                .accessibilityIdentifier("film-export-quality-stepper")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .transition(.opacity)
                }
                Text(controller.settings.format == .tiff
                     ? filmText("16-bit · Adobe RGB · 保留原始裁剪像素，透明边角保持透明。",
                                "16-bit · Adobe RGB · original crop pixels; transparent corners stay transparent.")
                     : filmText("8-bit · sRGB · 保留原始裁剪像素，透明边角填充白色。",
                                "8-bit · sRGB · original crop pixels; transparent corners fill white."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(filmText("命名", "Naming")) {
                TextField(filmText("前缀", "Prefix"), text: $controller.settings.prefix)
                    .accessibilityIdentifier("film-export-prefix")
                if controller.settings.scope != .strip {
                    Picker(filmText("帧编号", "Frames"), selection: $controller.settings.naming) {
                        Text(filmText("帧名称", "Frame name")).tag(FilmExportNaming.frameName)
                        Text(filmText("连续序号", "Sequence")).tag(FilmExportNaming.sequence)
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("film-export-naming")
                    if controller.settings.naming == .sequence {
                        TextField(filmText("起始序号", "Start at"),
                                  value: $controller.settings.startNumber, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .transition(.opacity)
                            .accessibilityIdentifier("film-export-start-number")
                    }
                }
                Picker(filmText("同名文件", "If file exists"), selection: $controller.settings.collision) {
                    Text(filmText("保留两份", "Keep both")).tag(FilmExportCollision.keepBoth)
                    Text(filmText("跳过", "Skip")).tag(FilmExportCollision.skip)
                }.accessibilityIdentifier("film-export-collision")
                if controller.settings.scope != .strip {
                    DisclosureGroup(isExpanded: $numberingExpanded) {
                        Picker(filmText("最少位数", "Minimum digits"), selection: $controller.settings.digits) {
                            ForEach(2...4, id: \.self) { Text("\($0)").tag($0) }
                        }.accessibilityIdentifier("film-export-digits")
                        Text(filmText("仅补足纯数字编号，例如 1 → 001；文字名称保持原样。",
                                      "Pads numeric numbers only, such as 1 → 001. Text names stay as written."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        HStack {
                            Text(filmText("编号位数", "Number padding"))
                            Spacer()
                            if !numberingExpanded {
                                Text("\(controller.settings.digits)")
                                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.contentShape(Rectangle())
                    }
                }
            }
        }.formStyle(.grouped)
            .animation(motion(FilmMotion.quick), value: controller.settings.format)
            .animation(motion(FilmMotion.quick), value: controller.settings.naming)
            .animation(motion(FilmMotion.quick), value: controller.settings.scope)
    }

    private func scopeLabel(_ title: String, _ detail: String?) -> Text {
        guard let detail, !detail.isEmpty else { return Text(title) }
        return Text(title) + Text("  ") + Text(detail).foregroundStyle(.secondary)
    }

    // MARK: File preview

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(filmText("文件预览", "File preview")).font(.headline)
                Spacer()
                if let preview = controller.preview {
                    Text(previewSummary(preview))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(FilmMotion.digits(reduceMotion: reduceMotion))
                        .animation(motion(FilmMotion.text), value: preview.outputCount)
                        .accessibilityIdentifier("film-export-preview-summary")
                }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let preview = controller.preview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(preview.items) { item in
                            VStack(spacing: 0) {
                                previewRow(item)
                                Divider().padding(.leading, 16)
                            }.transition(.opacity)
                        }
                        Text(filmText("像素尺寸为预计值，最终以编码结果为准。",
                                      "Pixel sizes are estimates; the encoder determines the final bounds."))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }.animation(motion(FilmMotion.text), value: preview.items.map(\.id))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.ellipsis").font(.title2).foregroundStyle(.tertiary)
                    Text(filmText("暂无可导出的文件", "No files to export")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
            }
        }.background(Palette.background)
    }

    private func previewSummary(_ preview: FilmExportPlan) -> String {
        let skipped = preview.items.count - preview.outputCount
        let base = String(format: filmText("%d 个文件", "%d files"), preview.outputCount)
        guard skipped > 0 else { return base }
        return base + " · " + String(format: filmText("跳过 %d", "skip %d"), skipped)
    }

    private func previewRow(_ item: FilmExportItem) -> some View {
        let size = "\(Int(item.pixelSize.width.rounded())) × \(Int(item.pixelSize.height.rounded()))"
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.fileName)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(item.skipped ? .secondary : .primary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if item.skipped {
                Label(filmText("已有同名文件 · 将跳过", "Already exists · will skip"), systemImage: "arrow.uturn.right")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("≈ \(size) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .help(item.fileName)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.fileName + ", " + (item.skipped
            ? filmText("已有同名文件，将跳过", "already exists, will be skipped")
            : String(format: filmText("预计 %@ 像素", "estimated %@ pixels"), size)))
        .accessibilityIdentifier("film-export-preview-item")
    }

    // MARK: Destination and actions

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = controller.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("film-export-validation")
            } else if let preview = controller.preview, preview.outputCount == 0 {
                Label(filmText("所选文件在该文件夹中均已存在，将全部跳过。",
                               "Every selected file already exists in this folder and would be skipped."),
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("film-export-nothing")
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                if let directory = controller.directory {
                    let path = (directory.path as NSString).abbreviatingWithTildeInPath
                    Text(path).font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(directory.path)
                        .accessibilityLabel(filmText("导出文件夹：", "Export folder: ") + directory.path)
                        .accessibilityIdentifier("film-export-directory")
                } else {
                    Text(filmText("尚未选择导出文件夹", "No export folder chosen"))
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("film-export-directory")
                }
                Spacer(minLength: 8)
                Button(filmText("选择文件夹…", "Choose folder…")) { controller.chooseDirectory(parent: parentWindow) }
                    .accessibilityIdentifier("film-export-folder")
            }
            HStack {
                Button(filmText("返回切片", "Back to slicing")) { controller.dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("film-export-back")
                Spacer()
                Button {
                    // A field being edited commits on focus loss; a click on a button
                    // does not move focus, so end editing before the plan is fixed.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    controller.confirm()
                } label: {
                    Text(exportTitle)
                        .contentTransition(FilmMotion.digits(reduceMotion: reduceMotion))
                        .animation(motion(FilmMotion.text), value: controller.preview?.outputCount)
                }
                .keyboardShortcut(.defaultAction).disabled(!controller.canStart)
                .accessibilityIdentifier("film-export-start")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .animation(motion(FilmMotion.quick), value: controller.validationMessage)
            .animation(motion(FilmMotion.quick), value: controller.preview?.outputCount == 0)
    }

    private var exportTitle: String {
        switch controller.preview?.outputCount ?? 0 {
        case 0: filmText("导出", "Export")
        case 1: filmText("导出 1 个文件", "Export 1 file")
        case let count: String(format: filmText("导出 %d 个文件", "Export %d files"), count)
        }
    }
}

/// Workbench-bottom job state. Reads the controller's job and calls its actions only;
/// the job and its flags are never written from here.
struct FilmExportStatusView: View {
    let controller: FilmExportController
    @State private var detailsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func motion(_ animation: Animation) -> Animation { FilmMotion.resolve(animation, reduceMotion: reduceMotion) }

    /// Rises from the window's bottom edge once the sheet has gone; fades out faster than it arrives.
    private var panelTransition: AnyTransition {
        .asymmetric(
            insertion: (reduceMotion ? AnyTransition.opacity : .move(edge: .bottom).combined(with: .opacity))
                .animation(motion(FilmMotion.panelIn)),
            removal: AnyTransition.opacity.animation(motion(FilmMotion.panelOut)))
    }

    var body: some View {
        // The container stays mounted so the insertion and removal below can animate.
        Group {
            if let job = controller.job { panel(job).transition(panelTransition) }
        }.animation(motion(FilmMotion.panelIn), value: controller.job != nil)
    }

    private func panel(_ job: FilmExportJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        summary(job)
                        Spacer(minLength: 8)
                        actions(job)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        summary(job)
                        actions(job)
                    }
                }
                if controller.isRunning {
                    ProgressView(value: Double(job.processedCount), total: Double(max(1, job.results.count)))
                        .accessibilityLabel(title(job))
                        .animation(motion(FilmMotion.progress), value: job.processedCount)
                    Text(job.activeFileName ?? " ")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if !issues(job).isEmpty { details(job) }
            }
            .animation(motion(FilmMotion.expand), value: detailsExpanded)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("film-export-status")
            .onChange(of: job.id, initial: true) { detailsExpanded = job.failedCount > 0 }
            .onChange(of: controller.isRunning) { _, running in
                guard !running, let job = controller.job else { return }
                if job.failedCount > 0 { detailsExpanded = true }
                AccessibilityNotification.Announcement(title(job) + ". " + counts(job)).post()
            }
    }

    // MARK: Pieces

    private func summary(_ job: FilmExportJob) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(job)).imageScale(.large)
                .foregroundStyle(controller.isRunning ? .secondary : .primary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .animation(motion(FilmMotion.text), value: symbol(job))
                .frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(job)).font(.callout.weight(.semibold))
                    .contentTransition(FilmMotion.digits(reduceMotion: reduceMotion))
                    .animation(motion(FilmMotion.text), value: title(job))
                    .accessibilityIdentifier("film-export-status-title")
                Text(counts(job)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .contentTransition(FilmMotion.digits(reduceMotion: reduceMotion))
                    .animation(motion(FilmMotion.text), value: counts(job))
                    .accessibilityIdentifier("film-export-status-counts")
            }
        }
    }

    @ViewBuilder private func actions(_ job: FilmExportJob) -> some View {
        HStack(spacing: 8) {
            if controller.isRunning {
                Button(controller.cancellationRequested ? filmText("正在取消…", "Cancelling…") : filmText("取消导出", "Cancel export")) {
                    controller.cancel()
                }.disabled(controller.cancellationRequested)
                    .accessibilityIdentifier("film-export-cancel")
            } else {
                // The most useful recovery step leads; Close stays last and quiet.
                if controller.canResume {
                    Button(filmText("继续剩余", "Resume remaining")) { controller.resume() }
                        .buttonStyle(primary: !controller.canRetry || job.phase == .cancelled)
                        .accessibilityIdentifier("film-export-resume")
                }
                if controller.canRetry {
                    Button(filmText("重试失败项", "Retry failed files")) { controller.retryFailed() }
                        .buttonStyle(primary: !(controller.canResume && job.phase == .cancelled))
                        .accessibilityIdentifier("film-export-retry")
                }
                if job.completedCount > 0 {
                    Button(filmText("在 Finder 中显示", "Show in Finder")) { controller.revealFiles() }
                        .accessibilityIdentifier("film-export-reveal")
                }
                Button(filmText("关闭", "Close")) { controller.clearJob() }
                    .accessibilityIdentifier("film-export-dismiss-status")
            }
        }.controlSize(.small)
    }

    private func details(_ job: FilmExportJob) -> some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(issues(job)) { result in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: result.status == .skipped ? "arrow.uturn.right" : "xmark.octagon")
                                .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.item.fileName).font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                Text(reason(result)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(result.item.fileName + ": " + reason(result))
                        .accessibilityIdentifier("film-export-issue")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.frame(maxHeight: 112)
        } label: {
            Text(job.failedCount > 0 ? filmText("失败详情", "Failure details") : filmText("跳过的文件", "Skipped files"))
                .font(.caption).accessibilityIdentifier("film-export-details-label")
        }
    }

    // MARK: Text

    private func title(_ job: FilmExportJob) -> String {
        if controller.isRunning {
            return controller.cancellationRequested
                ? filmText("正在取消…", "Cancelling…")
                : String(format: filmText("正在导出 %d / %d", "Exporting %d of %d"), job.processedCount, job.results.count)
        }
        if job.pendingCount > 0 { return filmText("导出已取消", "Export cancelled") }
        if job.failedCount > 0 {
            return job.completedCount > 0 ? filmText("部分文件导出失败", "Some files failed")
                                          : filmText("导出失败", "Export failed")
        }
        return filmText("导出完成", "Export complete")
    }

    private func counts(_ job: FilmExportJob) -> String {
        var text = String(format: filmText("已导出 %d · 跳过 %d · 失败 %d", "Exported %d · skipped %d · failed %d"),
                          job.completedCount, job.skippedCount, job.failedCount)
        if !controller.isRunning, job.pendingCount > 0 {
            text += " · " + String(format: filmText("未导出 %d", "remaining %d"), job.pendingCount)
        }
        return text
    }

    private func symbol(_ job: FilmExportJob) -> String {
        if controller.isRunning { return "arrow.down.circle" }
        if job.pendingCount > 0 { return "stop.circle" }
        return job.failedCount > 0 ? "exclamationmark.triangle" : "checkmark.circle"
    }

    private func issues(_ job: FilmExportJob) -> [FilmExportResult] {
        let failed = job.results.filter { if case .failed = $0.status { true } else { false } }
        return failed + job.results.filter { $0.status == .skipped }
    }

    private func reason(_ result: FilmExportResult) -> String {
        if case .failed(let message) = result.status { return message }
        return filmText("目标文件夹中已有同名文件，已跳过。", "A file with this name already existed, so it was skipped.")
    }
}

private extension View {
    /// Emphasizes one recovery action per state; the rest stay standard bordered.
    @ViewBuilder func buttonStyle(primary: Bool) -> some View {
        if primary { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}
#endif
