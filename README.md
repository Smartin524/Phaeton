<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Phaeton"></p>

# Phaeton · 轻與

[English](README.en.md)

**轻與**（Phaeton）是轻量的 macOS 菜单栏文件转换工具：**按住 Shift 拖动文件，光标处出现轮盘，拖到目标格式上松手**，结果保存在原文件旁，原文件不动。

- **灵感：** 来自《GTA V》的武器轮盘和《Apex Legends》的标点系统：按住、朝想要的方向一划、松手。
- **原生、轻量：** 主要用 macOS 自带框架（AppKit、SwiftUI、ImageIO、AVFoundation、PDFKit、Vision），没有常驻后台服务，不上传任何文件。
- **触发不需要权限：** 只监听鼠标事件和拖拽剪贴板，不用辅助功能 / 输入监控权限。
- **不止格式转换：** 图片裁切与压缩、视频剪切 / 取帧 / 压缩、音频剪切与淡入淡出，都有带预览的小窗口。

## 界面

<p align="center"><img src="docs/screenshots/wheel.png" width="260" alt="拖动图片时出现的轮盘：JPEG、WebP、HEIC、PDF、TXT 和扳手"></p>

按住 Shift 拖动文件，轮盘出现在光标处；拖到格式上松手即转换。扳手格固定在正左方（9 点钟方向），合并 / 拼接紧挨着它（左上）。不同文件的轮盘里它们总在同一个位置，用熟了不用看。

拖到扳手上松手，打开带预览的编辑窗口：

<p align="center"><img src="docs/screenshots/image-editor.png" width="620" alt="图片编辑窗口：裁切框、比例、宽高、画质"></p>

## 安装

**一行命令**（需要 Apple 芯片的 Mac 和 macOS 13+）：

```bash
curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
```

它从 [Releases](https://github.com/Smartin524/Phaeton/releases) 下载最新的 zip，校验 SHA-256，装到 `/Applications`（没有权限就装到 `~/Applications`）并打开。运行前请先读一下[脚本](scripts/install.sh)，它很短。更新就是再运行一遍。

**手动安装：** 从 Releases 下载 zip，解压后把 `Phaeton.app` 拖进“应用程序”。因为没有开发者签名和公证，浏览器下载的版本第一次打开会被系统拦下（提示“无法验证开发者”之类）。常见的解决办法有两种：

1. **系统设置里放行：** 先双击打开一次让它被拦下，然后打开“系统设置 → 隐私与安全性”，滚到底部找到 “Phaeton 已被阻止”，点**“仍要打开”**，输入密码。只需要这一次。（macOS 15 起，以前的“右键 → 打开”已经不管用了。）
2. **终端去掉隔离标记：** `xattr -dr com.apple.quarantine /Applications/Phaeton.app`

用上面的一行命令安装则不会遇到这个提示，因为命令行下载的文件不带隔离标记。

**卸载：** `rm -rf /Applications/Phaeton.app ~/Library/Application\ Support/Phaeton`（后者是可选组件）。

**从源码构建：** 见[构建与运行](#构建与运行)。

## 能转什么

| 拖的文件 | 轮盘上的格式 |
|---|---|
| 图片（含 SVG） | PNG / JPEG / WebP\* / HEIC / PDF / TXT（识别图中文字） |
| 视频 | M4A / WAV / AIFF（提取音频）、MP3\*、MP4 / MOV |
| 音频 | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG（多页生成同名文件夹）、TXT（无文字层时自动 OCR）、DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

带 \* 的需要[可选组件](#可选组件)，第一次用到时会询问是否安装。每种文件里和它自己相同的格式会自动隐藏。

**一次拖多个文件**时轮盘多一格：多张图片 → **合并 PDF**，多个 PDF → **合并 PDF**，多个视频或音频 → **拼接**。

图片、视频、音频和 PDF 的轮盘最后一格是**扳手**：拖到扳手上松手，打开编辑窗口。

| | 窗口里能做的 |
|---|---|
| 图片 | “裁切”页：拖动裁切框、固定比例、直接填宽高像素；JPEG / HEIC 三档画质，显示预估大小。“更多”页：**去背景**（透明 PNG，需 macOS 14+）、移除位置等元数据、**压缩到指定大小**、复制图中文字、识别二维码 |
| 视频 | “剪辑”页：缩略图时间轴选起止，**快速剪切**（不重新编码、无损，起点落在关键帧）；保存当前画面为 PNG。“更多”页：压缩到 1080p / 720p / 480p、**压缩到指定大小**、静音、变速（0.5× – 2×） |
| 音频 | 波形上选起止；可选淡入 / 淡出各 1 秒；无淡入淡出时无损复制，有则重新编码为 M4A |
| PDF | 预览；提取指定页（如 `1-3,5`）存为新 PDF；每页拆成单独的 PDF |

## 其他入口与细节

- **Finder 右键：** 选中文件 → 右键 → 快速操作 / 服务 → “用轻與转换…”（英文系统里叫 “Convert with Phaeton…”）。没看到的话到“系统设置 → 键盘 → 键盘快捷键 → 服务”里勾选。
- **菜单栏：** 只有一个设置开关和“退出”，其余都靠拖拽、右键和通知。
- **进度与通知：** 松手后轮盘变成原位置的进度圆环，**点击圆环取消**；结束发系统通知（首次会询问授权），点通知在访达里显示结果。
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

- `swift test`：22 个单元测试（图片转换的安全与像素细节、轮盘几何、文件类型与格式规则），需要完整 Xcode。
- `bash scripts/validate.sh`：现场生成样本文件，对转换引擎做端到端检查（图片、音视频、文档、合并拼接、OCR、剪切、取消……）。需要可选组件的检查在没装时自动跳过。

两者测的是引擎，不是界面；界面和拖拽手感没有自动化测试。

## 已知限制

- 拖拽监听依赖 macOS 向后台应用传递全局鼠标事件；收不到时轮盘不会出现，可用右键或菜单栏入口。
- 不支持：MKV / WebM / AVI 输入、FLAC / OGG 输出、Word 以外的 Office 转 PDF。
- PDF→DOCX 对复杂排版不保证还原，扫描件不做文字识别。
- 没有开发者签名和公证（见上面的安装说明）；界面、拖拽手感没有自动化测试。

## 结构

```text
Sources/FormatWheel/      菜单栏、拖拽监听、轮盘、编辑窗口、进度圆环
Sources/FormatWheelCore/  文件类型与格式、轮盘几何、图片 / 音视频 / 文档转换引擎
scripts/                  构建、图标、可选组件安装、验证
validation/               引擎的独立检查
```

代码里的内部目标名仍是 `FormatWheel`。

## 许可证

MIT，见 [LICENSE](LICENSE)。
