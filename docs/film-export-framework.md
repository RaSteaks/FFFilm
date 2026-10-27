# macOS 胶片导出功能框架

本框架已接入 App。FilmExportViews.swift 暂用简单原生控件，供 Claude 调整布局、视觉和呈现层。命名、文件访问和任务状态保留在框架中。

## 文件职责

| 文件 | 职责 |
| --- | --- |
| FFFilm/FilmStore.swift | 文档、切片、当前帧、勾选、缩放和操作限制 |
| FFFilm/FilmExport.swift | 类型化配置、命名计划、帧快照及结果 |
| FFFilm/FilmExportController.swift | 草稿、校验、目录权限、面板生命周期和任务控制 |
| FFFilm/FilmExportViews.swift | 可替换的 Sheet 和工作台状态界面 |
| FFFilm/FilmRenderer.swift | 原尺寸 TIFF/JPEG 渲染；执行时核对源图身份 |

## 给 Claude 的 UI 接口

- 从 FilmStore.openExportSettings() 进入。Sheet 绑定 exportController.isPresented，关闭请求调用 dismiss()；onDismiss **必须调用 didDismiss()**。
- 控件绑定 controller.settings。预览和 validationMessage 自动刷新，不修改文档或裁切撤销记录。
- preview.items 提供稳定帧 ID、文件名、预计像素尺寸和 skipped 标记。preview.outputCount 是本次实际输出数量。
- chooseDirectory(parent:) 将文件夹选择器挂在导出 Sheet 上，传入 store.window。使用 directory、isChoosingDirectory、canStart 呈现目录和可用状态。
- 返回调用 dismiss()；导出调用 confirm()。确认时重新校验并固定计划，等 Sheet 完成关闭后才执行。
- 工作台读取 controller.job 和 isRunning。动作是 cancel()、resume()、retryFailed()、revealFiles()、clearJob()。
- job 提供 completedCount、skippedCount、failedCount、pendingCount、processedCount、activeFileName、completedURLs 和逐文件 results。失败原因在 result.status 的 failed 消息中。
- 保留 film-export-* 辅助功能标识。不要在 View 中设置任务标志、修改任务结果，或重新实现命名、冲突处理和文件访问。

## 状态与联动

1. 当前帧由 FilmStore.selected 管理，批量勾选由 selection 管理，二者独立。导出不使用 targets 的当前帧回退行为。
2. 首次打开有勾选则默认已勾选范围，否则默认当前帧。明确选择的范围再次打开时保留；已勾选范围变空时回退当前帧。
3. Sheet 阻止文档修改、导入/保存及竞争面板。返回保留草稿、选择和视口，再次打开刷新切片数据。
4. confirm() 固定源图身份、几何、格式、质量、目录、文件名和冲突决策。dismiss 到 didDismiss 之间仍阻止文档操作。
5. 执行时暂停勾选和几何修改，允许查看帧和缩放。状态显示在工作台。
6. 取消为协作式，可能需要等待当前编码结束；移除未发布的临时文件，保留完成文件，剩余项可继续。
7. 失败重试只处理失败项，保持原始命名与参数，不重复导出成功项，也不会顺带继续其他取消项。
8. 切换源图会清除旧任务恢复状态，即使新导入失败。渲染器另行拒绝源图身份不匹配。

## 命名与记忆边界

- 默认使用源文件名前缀和帧名称；ASCII 数字补足 2–4 位，文字保留；排序只改变导出顺序。
- 连续编号仅作用于本次选择；整条输出使用 _strip。
- 保留两份同时处理磁盘和批内重名，追加「 (2)」等后缀；可选择跳过。确认后新出现的同名文件不会被覆盖，对应项报告失败。
- 空名称、路径分隔符、冒号、控制字符和超过 255 个 UTF-8 字节的文件名直接提示，不静默改写。
- 草稿在当前源图/窗口会话中记忆。新源图重置命名，并读取旧项目的格式、质量字段作为初值；窗口保留上次目录。
- 新草稿**不写入 .fffilm，不跨 App 重启恢复**，保持现有项目格式兼容。
- 预览尺寸使用共享裁切/旋转几何，标为预计尺寸；最终像素边界和 ICC 由现有编码器负责。

## 验证

按 README 的 xcodebuild test 命令运行，先指定 -only-testing:FFFilmTests/FilmExportTests，再运行完整 macOS 单元测试。

测试使用真实 TIFF 与生产渲染器，覆盖命名、重排、Unicode、冲突、取消、快照恢复、源图变更、操作限制和重试时成功文件不变。原有 FilmRefinementTests 的导出回归也已迁移到新接口。
