<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Phaeton"></p>

# Phaeton

[English](README.en.md)

轻量的 macOS 菜单栏文件转换工具：**按住 Shift 拖动文件，光标处出现轮盘，拖到目标格式上松手**，结果保存在原文件旁，原文件不动。

- **原生、轻量：** 主要用 macOS 自带框架（AppKit、SwiftUI、ImageIO、AVFoundation、PDFKit、Vision），没有常驻后台服务，不上传任何文件。
- **触发不需要权限：** 只监听鼠标事件和拖拽剪贴板，不用辅助功能 / 输入监控权限。
- **不止格式转换：** 图片裁切与压缩、视频剪切 / 取帧 / 压缩、音频剪切与淡入淡出，都有带预览的小窗口。

## 能转什么

| 拖的文件 | 轮盘上的格式 |
|---|---|
| 图片（含 SVG） | PNG / JPEG / WebP\* / HEIC / PDF |
| 视频 | M4A / WAV / AIFF（提取音频）、MP3\*、MP4 / MOV |
| 音频 | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG（多页生成同名文件夹）、TXT（无文字层时自动 OCR）、DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

带 \* 的需要[可选组件](#可选组件)，第一次用到时会询问是否安装。每种文件里和它自己相同的格式会自动隐藏。

图片、视频、音频的轮盘最后一格是**扳手**：拖到扳手上松手，打开编辑窗口。

| | 窗口里能做的 |
|---|---|
| 图片 | 拖动裁切框、固定比例、直接填宽高像素；JPEG / HEIC 三档画质，显示预估大小 |
| 视频 | 缩略图时间轴选起止，**快速剪切**（不重新编码、无损，起点落在关键帧）；保存当前画面为 PNG；压缩到 1080p / 720p / 480p |
| 音频 | 波形上选起止；可选淡入 / 淡出各 1 秒；无淡入淡出时无损复制，有则重新编码为 M4A |

## 其他入口与细节

- **Finder 右键：** 选中文件 → 右键 → 快速操作 / 服务 → “用 Phaeton 转换…”。没看到的话到“系统设置 → 键盘 → 键盘快捷键 → 服务”里勾选。
- **菜单栏：** “选择文件转换…”、取消转换、显示最近结果。
- **进度与通知：** 松手后轮盘变成原位置的进度圆环；结束发系统通知（首次会询问授权）。
- **已选中文件按 Shift 会取消选中**（Finder 自己的行为）：先正常拖起文件，拖动中再按 Shift；或在菜单里打开“已选中文件时 Shift 不取消选中”（需要辅助功能权限，默认关闭）。
- **安全：** 输出先写隐藏临时文件再原子改名，从不覆盖已有文件，重名自动加数字；失败或取消不留残渣。

## 构建与运行

需要 macOS 13+ 和 Swift 工具链（Xcode 或 Command Line Tools）。无 Swift 包依赖。

```bash
bash scripts/build-app.sh        # 生成 dist/Phaeton.app（本地临时签名，未公证）
open dist/Phaeton.app
```

若系统 SDK 与工具链不匹配，可指定 `FORMATWHEEL_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。未公证的应用第一次打开需要右键 → 打开。

## 可选组件

WebP、MP3 和 PDF→DOCX 需要一次性安装（约 250 MB，需联网），装进私有目录 `~/Library/Application Support/Phaeton`，不改动系统。第一次用到时 Phaeton 会询问并代为安装；也可手动运行 `bash scripts/install-extras.sh`。卸载：删除该文件夹。
这些组件有各自的许可证（GPL / AGPL / LGPL），详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 验证

`bash scripts/validate.sh` 用 `samples/` 里的样本跑一遍转换引擎的独立检查（图片、音视频、文档、取消、剪切、OCR）。它们测的是引擎，不是界面；`swift test` 的单元测试需要完整 Xcode（Command Line Tools 缺 XCTest），作者尚未在本机运行过。

## 已知限制

- 拖拽监听依赖 macOS 向后台应用传递全局鼠标事件；收不到时轮盘不会出现，可用右键或菜单栏入口。
- 不支持：MKV / WebM / AVI 输入、FLAC / OGG 输出、Word 以外的 Office 转 PDF。
- PDF→DOCX 对复杂排版不保证还原，扫描件不做文字识别。
- 没有签名和公证；界面、拖拽手感没有自动化测试。

## 结构

```text
Sources/FormatWheel/      菜单栏、拖拽监听、轮盘、编辑窗口、进度圆环
Sources/FormatWheelCore/  文件类型与格式、轮盘几何、图片 / 音视频 / 文档转换引擎
scripts/                  构建、图标、可选组件安装、验证
validation/               引擎的独立检查
samples/                  自制的样本文件
```

代码里的内部目标名仍是 `FormatWheel`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
