# iOS 胶片模拟的型号预设

这四个预设根据柯达公开的感光特性图计算影调。在「胶片模拟」中，可为负片预选型号。确认片基后先反转负片，再应用所选型号曲线。反转片和普通场景直接以原像为输入。「标准」档或 0% 强度显示基础画面，100% 强度应用完整曲线。「对照原图」可暂时查看处理前的输入，返回模拟后保留此前的风格与强度。片基采样读取原图，导出保留完整画幅的校准正片或反转片原像。

| 预设 | 特性图与取样条件 | 映射方式 |
| --- | --- | --- |
| PORTRA 400 | 第 4 页，日光，Status M，图示参考 log H 为 −1.44。[柯达 E-4050，2025 年版](https://kodakprofessional.com/sites/default/files/2025-07/e4050.pdf#page=4) | 分别读取 R、G、B 密度曲线，减去各通道的低曝光密度基线，模拟负片转为可观看的正像。 |
| EKTAR 100 | 第 4 页，日光，Status M，图示参考 log H 为 −0.84。[柯达 E-4046](https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4046_ektar_100.pdf#page=4) | 使用 EKTAR 自身的三层密度读数，沿用与 PORTRA 相同的虚拟印相条件，方便比较。 |
| EKTACHROME E100 | 第 3 页，日光 1/100 秒，E-6，Status A。[柯达 E-4000](https://kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf#page=3) | 各通道的密度换算为透射率，并对齐中灰。真实反转片在 0% 强度时直接显示原像。 |
| TRI-X 400 | 第 8 页左上图，400TX 35 mm，D-76 大罐、20 °C、8 分钟，每分钟搅动，漫射视觉密度。[柯达 F-4017，2016 年版](https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4017_TriX.pdf#page=8) | 先取线性 Rec. 709 亮度，再映射到这条单通道曲线。 |

## 从技术图到屏幕

脚本内置的密度数据取自上述 PDF 的矢量曲线。取样间隔为 0.25 log H，输入表保留两位小数。以线性 18% 灰作为参考曝光，其他输入按与中灰的亮度比换算到 log H。两个彩负型号使用其图中的参考曝光。E100 和 TRI-X 的中灰位置分别选 −0.84 和 −1.44，以便在同一取景画面切换时保持中灰稳定。

对负片，脚本以共同的虚拟印相反差 1.65 把密度差转换到正像亮度，扣除低曝光端基线并把参考灰标定到 0.18。反转片使用透射率换算。输出高于 0.75 的部分以平滑曲线渐近屏幕白点。这些中灰、虚拟印相和亮部压缩参数是 FFFilm 的显示选择。密度图来自指定冲洗条件；灯箱光谱、相机处理、真实相纸、颗粒和光晕都会影响实拍或冲印结果。预设适合比较影调，色彩表现属于 RGB 近似。

每款曲线离线生成 257 个等距 sRGB 码值的三通道 Float32 查找表，随程序编译。Core Image 在 sRGB 域进行表内插值，强度在工作空间的线性亮度中混合原图与变换结果。预览在本地运行。

在仓库根目录运行 `python3 script/generate_film_look_tables.py --check` 可校验内置 LUT 是否与源码中的数据一致。更新取样数据后运行 `python3 script/generate_film_look_tables.py` 重新生成。[取样数据与生成脚本](../script/generate_film_look_tables.py)
