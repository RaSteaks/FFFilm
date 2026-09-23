<img src="design/icon/exports/iOS-Default.png" alt="FFFilm" width="96">

# FFFilm

[English](README.en.md) | **简体中文**

为你在片场实际使用的相机做数据率、存储时长与快门规划。原生 SwiftUI，支持 iPhone、iPad 与 Mac，无任何第三方依赖。

## 功能

**录制** —— 输入相机、格式与帧率，得出码率与存储需求。

- 数据率以 GB/小时 或 GiB/小时 显示，并给出对应的 Mb/s 码率。
- 存储计划：按计划时长计算所需容量、存储卡的实际可录时长，计划超出卡容量时给出警告。
- 直接输入时长（0.25–24 小时），带行内校验、原生步进器与 1/4/8/12 小时预设。未完成的草稿保留上一次有效结果。
- 快照对比：最多固定四个方案，重复方案会被拒绝。
- 各相机独立记忆格式设置；媒体与计划时长按窗口分别保留。
- 回放时长、有效成像区域与计算依据收在折叠的详情栏中。

**快门** —— 三种模式共享相机 FPS 与用户设置的最大快门角度。

- **换算** —— 角度 ⇄ 曝光时间，主读数跟随换算方向。
- **频闪参考** —— 针对市电（50/60 Hz）、自定义光学频率或 2–16 档显示器刷新率的无频闪角度。
- **升格 / 降格** —— 通过保持角度或保持时间来匹配曝光，含回放速度与可选的灯光检查。

预设帧率携带精确的有理数值；手动输入的小数按字面值使用。

**相机目录** —— 33 个机型档案，涵盖 ARRI、Sony、RED、DJI、Kinefinity 与独立 Apple ProRes，支持按厂商分组搜索、可拖动排序的收藏，以及每台相机的录制模式详情。

**设置** —— 十进制 GB/TB 或二进制 GiB/TiB，应用于码率与总量，不影响比特率与时长。简体中文与英文跟随系统语言，无对应语言时回退到英文；相机型号、编解码器名称与 FPS 保持原文。

## 胶片切片（仅 macOS）

在 Mac 工具栏打开**胶片**，或按 **⌘3**。导入 TIFF 或实验性的 Flextight FFF 条带，自动检测片框间隙或手动绘制片框，然后裁剪、旋转、排序并导出。自动边界仅为候选结果，请人工核对。保存 `.fffilm` 项目可随时继续切片，且不修改原始扫描件。

可将当前、已勾选或全部片框导出为 16 位 Adobe RGB TIFF 或 8 位 sRGB JPEG。整条导出时，旋转后的裁剪结果放回原始槽位并裁切至槽位边界；单帧导出保留完整的旋转边界。缩放、撤销/重做与批量选择均可使用。


**色彩管理**仅用于准确解释输入/输出：内嵌的输入色彩配置优先；未标记的扫描件需显式指定配置或提供匹配的 RGB ICC。浮点预览保留扩展 RGB 范围，导出时嵌入输出色彩配置。不进行自动负片转换。详见[色彩管理说明](docs/film-color-management.md)。

**FFF 兼容性为实验性：** ImageIO 的全分辨率 16 位 RGB 解码在已测试样本上可用，但这并不能覆盖所有专有变体或校准过的扫描仪色彩。不支持相机 RAW FFF 与 FlexColor 处理历史。

## 构建、运行与测试

需要 Xcode 26.3 或更高版本，以及 iOS/iPadOS 18.6+ 或 macOS 15.6+。打开 `FFFilm.xcodeproj`，或使用：

```sh
# macOS 应用
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=macOS' build

# iOS 模拟器
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

```sh
# 单元测试 —— 目录完整性、码率表、媒体规划、快门计算
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=macOS' -only-testing:FFFilmTests test

# UI 测试 —— 需在模拟器上运行；该标志可避免克隆启动的不稳定问题
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:FFFilmUITests test
```

UI 测试通过辅助功能标识符（而非可见文本）选取元素，因此可在任意系统语言下运行。

```sh
# macOS 应用生命周期
script/build_and_run.sh            # 构建并启动
script/build_and_run.sh --verify   # 确认进程正在运行
script/build_and_run.sh --debug    # 在 lldb 下启动
script/build_and_run.sh --logs     # 流式查看统一日志
```
