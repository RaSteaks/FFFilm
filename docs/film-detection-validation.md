# Film detection validation / 胶片框选验证

Generated fixtures establish regression coverage, not real-negative accuracy or human time savings. Real scans and final acceptance remain the user's follow-up.

生成夹具用于功能回归，不代表真实负片准确率或人工节时收益。真实扫描由用户后续验收。

## Round 1 / 第一轮

- Implemented session-local import-analysis reuse, separate gap-center transport intervals and four-sided image crops, single-frame detection, provenance-based repeat detection, and grouped undo.
- 已实现导入分析缓存、分隔位置与有效画面框分离、单帧四边检测、重复识别保护与整批撤销。
- Targeted `FilmFrameDetectionTests`, `FilmFormatTests`, `FilmTests` passed with Xcode 26.3 on macOS. The cache test checks that repeated detection adds neither a pixel read nor a coarse-analysis measurement.
- 针对性测试通过；缓存测试直接检查重复检测没有新增像素读取或粗检测记录。
- Review: traced import → layout → detection → store application → export, checked full diff and whitespace. Confirmed format pitch still uses gap centers, names/manual geometry survive repeat detection, and undo/redo retains candidate provenance. No outstanding round-1 correctness finding.
- Review 已检查上述调用链与 diff，确认步距仍取间隙中心、名称和人工几何受到保护、撤销恢复不重复添加；无未解决的第一轮正确性问题。
- Environment: the first sandboxed baseline could not access signing/resource-compilation services. Successful verification used a local ad-hoc signature (`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`), without changing project signing settings, outside the tool sandbox.
- 环境限制：受限运行无法完成签名和资源编译；正式验证采用本地 ad-hoc 签名与沙箱外 Xcode，未改项目签名设置。
- Local evidence: `/Users/rasteaks/Desktop/FFFilm/1027/film-detection-three-rounds/round1-tests.log`, `round1-tests.xcresult`, `round1.diff`; initial environment failures are retained in `baseline.log` and `round1-initial.log`.

## Review gates / Review 门槛

Each implementation round must pass focused checks, a separate diff/caller review, and correction/retest before the next round. The final pass covers the cumulative changes and the full macOS unit suite. Timing reports use monotonic clocks and omit source paths and pixel content.

每轮先完成针对性检查，再独立检查 diff 和调用方，修正、复测后进入下一轮。最终检查累计修改及完整 macOS 单元测试。耗时使用单调时钟，不记录原图路径与内容。

## Round 2 / 第二轮

- Added robust linear-light local base samples, interpolation, source-precision edge bands, overlapping long-strip gap recovery, and conservative line envelopes for slanted frames. Manual base sampling and current-frame calibration use the existing native inspector/canvas, with cancellation, progress and stale-result rejection.
- 新增局部片基稳健估计与插值、源图窄带精修、长条重叠分段检测、倾斜边缘保守包络；加入片基点选、当前帧校准、进度、取消和过期结果保护。
- Focused `FilmFrameDetectionTests`, `FilmFormatTests`, `FilmTests`, `FilmZoomTests`, and `FilmRefinementTests` passed (`round2-review.log` / `.xcresult`). Source sampling is checked against the original 16-bit linear fixture; thin-gap and slanted-corner tests exercise the real renderer.
- 上述五组针对性测试通过；源精度测试对照 16 位线性原图，窄间隙与倾斜角落测试使用真实渲染器。
- Review corrected frame matching when gap coordinates shift, retirement/capacity accounting for replaced automatic candidates, and finite-value validation at the source readback boundary. The complete related test set passed after corrections. Compilation issues (orientation Int32 and CGFloat conversion) were fixed before this run.
- Review 修正间隙移动后的候选匹配、替换自动帧时的数量计算及源图读回的有限值检查，修正后相关测试全部通过；期间编译类型问题已解决。
- Static UI audit: strict mode, zero findings (`ui-audit.json`). Native launch and empty-state controls were inspected. The Mac locked during import interaction; the user explicitly deferred native interaction/visual acceptance until after code completion and unlock. Loaded-image workflow screenshots remain pending, not passed.
- UI 静态审计无问题；已检查原生启动和空态控件。导入交互时 Mac 锁定，用户明确要求先完成代码、最后解锁再检查界面；加载图像后的交互截图待补，不视为已通过。
- Existing test artifacts were moved from the original temporary root to the user-requested Desktop/FFFilm/1027 directory; historical logs retain their original execution paths.

## Round 3 / 第三轮

- Measured the actual renderer/detector in an optimized standalone build with four deterministic 16-bit TIFF workloads (horizontal/vertical six-frame strips, a twelve-frame strip and a 24 MP scan). Source snapshots, first/repeated timings, raw logs and process peak RSS are retained with the local validation artifacts.
- 用四组生成的 16 位 TIFF（横竖六帧、十二帧长条、24 MP 扫描）测量真实渲染/检测代码的优化构建；保留源码快照、首次/重复耗时、原始日志和进程峰值 RSS。
- Added a budgeted decoded provider (at most 256 MiB and one eighth of physical memory), direct 8-bit segment readback, and scoped autorelease pools. Linear-float source edge sampling remains unchanged in precision. Fresh refinement P50 across these fixtures decreased from 1.21–8.01 s to 0.31–0.57 s relative to round 2, not relative to the original gap-only detector.
- 新增受预算约束的解码缓存、分段直接 8 位读回和局部 autorelease pool，源图边缘仍使用线性浮点精度。上述夹具的首次精修中位数相对第二轮从 1.21–8.01 秒降至 0.31–0.57 秒；不是与原始仅检测间隙功能比较。
- Compared serial and two independent export workers over TIFF/JPEG, alternating unrotated/rotated frames. All 336 batches (2,520 outputs) passed readability, dimensions, bit-depth and ICC checks; first/last pixel hashes matched across worker counts. Two workers exceeded the extra 256 MiB RSS gate on the 24 MP case. Production remains serial; no experimental parallel path was added to the app.
- 对两种格式比较串行/双工作单元，包含旋转。336 批、2520 个输出通过可读性、尺寸、位深、ICC 检查，首末批像素校验和一致；24 MP 案例双任务额外峰值内存超门槛，生产保留串行。
- Final review fixed tile-local scene stripes being promoted to gaps, automatic-crop transport pitch when adding a frame, stale edge labels after manual rotation, and source-cache preparation after cancellation. Tests cover partial-work cancellation, source replacement, export retry snapshots, filename collisions and cancellation cleanup.
- 最终 review 修正分段场景条纹误判、自动框去片基后的追加步距、手动旋转后的过期边缘提示和取消后的源缓存状态；覆盖部分完成后取消、换源、导出重试快照、文件名碰撞与清理。
- Final macOS unit run: **146 passed, 1 opt-in stress test skipped (147 tests in 16 suites)**, `final-acceptance-tests.xcresult`. Native loaded-image UI verification was deferred during this run and completed after unlock; see the follow-up below.
- 最终 macOS 单元测试 **146 项通过、1 项按原有 opt-in 条件跳过（共 147 项 / 16 组）**。该轮运行时原生界面验证按用户要求等待解锁；解锁后已补验，见下方记录。

## Real-scan acceptance / 真实扫描人工验收

1. Import color negative, B&W, underexposed, narrow-gap, slanted and holder-containing scans. Compare frame count and all four edges with the original at inspection zoom.
2. Check image preservation before judging residual base. Record missed/extra frames, lost image pixels and edges requiring manual changes.
3. Sample a clean unexposed film edge, clear the sample, and calibrate from an edited frame. Check that other manual frames and names survive repeated detection.
4. Cancel detection, undo/redo an accepted batch, save/reopen the project and export TIFF/JPEG. Check rotation, ICC, bit depth, collisions and retry behavior.
5. Compare active operator time and total completion time on the same material. A 30% operator-time improvement remains an acceptance target, not a measured claim.

依次检查真实素材四边与数量、有效画面保全、取样/清除/校准、取消与撤销、项目恢复及导出。记录误裁、残留片基、手工调整次数与用时；人工节时 30% 仍为待验证目标。

## Artifact placement / 产物目录

Kept runtime artifacts are under `/Users/rasteaks/Desktop/FFFilm/1027/film-detection-three-rounds`, including `validation.md`, benchmark data, logs and result bundles. Repository regression sources and this developer record remain in their normal project locations. `FFFILM_TEST_ARTIFACT_ROOT` redirects film fixtures; the local test signature grants only that artifact directory additional write access. The production signing configuration is unchanged. macOS-managed Xcode/Metal caches remain system-managed.

保留的运行产物均位于上述用户指定目录；回归测试源码和开发说明留在项目正常位置。胶片夹具使用显式目录，临时测试签名仅增加该目录写权限，发布配置不变；系统缓存遵循 macOS 管理。

The skipped test is the existing `NegativeTests.largeTIFFRoundTrip`, enabled only with `NEGATIVE_LARGE_TEST=1` (an 85 MP negative-preview round trip). It is outside the normal unit-test run and was not relabeled as passed. All added and affected film tests ran successfully.

跳过项为已有 `NegativeTests.largeTIFFRoundTrip`，需显式设置 `NEGATIVE_LARGE_TEST=1`（85 MP 负片预览往返）；未将其计为通过。本次新增及受影响的胶片测试均实际通过。

## Native UI follow-up / 解锁后原生界面复核

- Imported the generated 6000 × 1000, 16-bit TIFF through the native file picker; automatic selection produced six frames and repeat detection did not duplicate them.
- Changed a frame name and width in native fields; calibration preserved both. Film-base clicking, the center-sample button, and clearing the sample completed successfully.
- On a separate 48000 × 600 generated strip, cancelled while the progress showed segment 27/36. The original placeholder frame remained and the cancellation notice was visible.
- Tested the narrow window and found the bottom export button/notice could be clipped by the inherited copyright safe-area inset. Replaced the macOS root inset with a real VStack footer sibling. The corrected 820pt-wide window shows the cancellation row and the entire export button after scrolling; switching to Recording and back preserves all six film frames.
- Captures and the final accessibility tree are retained in `native-ui/` below the artifact root. `04-occluded-capture.png` is a capture/occlusion artifact, not a passed visual check; raising the window restored a clear capture. No browser or Chrome automation was used.

已通过原生选择器导入、六帧识别与重复保护，验证手工名称/宽度在校准后保留、片基点击/中心取样/清除成功。48,000 × 600 夹具在分段 27/36 时取消，原框与提示保留。窄窗口检查发现页脚 safe-area 造成底部截断，已改为实际布局兄弟视图；修正后取消行和滚动到末尾的导出按钮完整可见，切换录制/胶片也保留六帧。截图和辅助功能树保存在指定目录，白色遮挡截图单独标注为采集异常，不计作通过证据。

## Underexposure follow-up / 欠曝真实样本跟进

A real 5195 × 37403, 8-bit negative scan exposed a gap in the generated-fixture coverage: two boundaries had only four/three contrasting lanes, and faint image areas merged into broad base-colored bands. Fixed-width anisotropic source tiles also invalidated the detector's geometric thresholds.

Strong evidence still follows the original path. Weak bands now require three compatible, regularly spaced observations. Extrapolated boundaries additionally require endpoint alignment, base compatibility and image information in both neighboring frames; narrow subjects may be visible in individual robust lanes even when the row median matches the base. Pure leaders/trailers and irregular layouts do not force extra frames. Estimated bands are retained on both neighboring crops and are never tightened by edge refinement. Source tiles preserve pixel aspect ratio and enough frame-width context.

原图复现从两帧恢复为六个候选框，其中四处分界为推测，保留重叠区域并提示人工核对；这不代表四边都已精确识别。左右黑色扫描边缘仍可能保留。新增彩负/黑白、小主体、空白片尾、不规则间距和交替短帧回归；四组既有夹具仍为 6/6/12/6。原片不入库、不修改；本地证据在指定产物目录的 `real-scan-005` 中。

## Scanner-background follow-up / 扫描黑边跟进

Automatic selection now detects stable, paired near-black SOURCE margins separately from film base. Sparse global rays establish the aperture's supported range; source-precision local steps then fit each frame. Low-level scanner halos do not define the aperture, and the shared range prevents an edge-touching dark subject from pulling the crop inward. Uncertain exposure boundaries retain their overlapping bands.

001.tif and 005.tif retained six frames in read-only validation. The first 001 frame was exported through the production renderer and visually inspected; its broad scanner border is removed, while a thin conservative rim may remain. The first 005 frame's left edge remains marked for review. Tests cover both orientations, a narrow dark edge subject, interior black content, halos and sharp transitions. Runtime evidence is in the user-selected artifact root under `black-border-001`.

本轮原生界面工具的路径输入未能提交，未将新截图验收计为通过；实际原片检测及生产渲染器裁切导出已验证。原图未修改，不把“去黑边”解释为删除画面内所有深色像素。保守细边和欠曝分隔仍可人工微调。
