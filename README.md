<p align="center"><img src="Resources/AppIcon-1024.png" width="112" alt="Phaeton"></p>

# Phaeton · 轻與

[English](README.en.md)

轻量的 macOS 菜单栏文件转换工具：**按住 Shift 拖动文件，光标处出现轮盘，拖到目标格式上松手**。结果存在原文件旁，原文件不动。灵感来自《GTA V》的武器轮盘和《Apex Legends》的标点系统。

<p align="center">
  <img src="docs/screenshots/wheel.png" width="230" alt="轮盘">
  &nbsp;&nbsp;
  <img src="docs/screenshots/image-editor.png" width="520" alt="图片编辑窗口">
</p>

- **原生：** 主要用 macOS 自带框架，没有后台服务，不上传文件。
- **触发不需要权限：** 只监听鼠标事件和拖拽剪贴板。
- **不止转换：** 拖到轮盘左边的**扳手**上，打开带预览的编辑窗口（图片裁切 / 去背景 / 压缩，视频和音频剪切，PDF 拆分）。

## 安装

需要 Apple 芯片的 Mac，macOS 13+。

```bash
curl -fsSL https://raw.githubusercontent.com/Smartin524/Phaeton/main/scripts/install.sh | bash
```

从 [Releases](https://github.com/Smartin524/Phaeton/releases) 下载最新版、校验 SHA-256、装到 `/Applications` 并打开（运行前可先读一下[脚本](scripts/install.sh)）。更新就是再运行一遍。卸载：`rm -rf /Applications/Phaeton.app ~/Library/Application\ Support/Phaeton`。

没有开发者签名和公证，所以**手动下载 zip** 的版本第一次会被系统拦下：先双击一次，再到“系统设置 → 隐私与安全性”点“仍要打开”（macOS 15 起右键打开已失效）；或运行 `xattr -dr com.apple.quarantine /Applications/Phaeton.app`。用上面的命令安装不会遇到。

## 能转什么

| 拖的文件 | 轮盘上的格式 |
|---|---|
| 图片（含 SVG） | PNG / JPEG / WebP\* / HEIC / PDF / TXT（识别文字） |
| 视频 | M4A / WAV / AIFF（提取音频）、MP3\*、MP4 / MOV |
| 音频 | M4A / WAV / AIFF / MP3\* |
| PDF | PNG / JPEG、TXT（无文字层时 OCR）、DOCX\* |
| TXT / RTF / DOC / DOCX / ODT | TXT / RTF / DOCX / PDF |

\* 需要[可选组件](#可选组件)。一次拖多个文件时多一格：**合并 PDF**（图片或 PDF）、**拼接**（视频或音频）。

**扳手窗口**

- **图片：** 裁切（比例或直接填像素）、画质、去背景、压缩到指定大小、去元数据、复制图中文字、识别二维码。
- **视频：** 快速剪切（无损）、取当前帧、压缩（清晰度或指定大小）、静音、变速。
- **音频：** 波形上选片段，可淡入淡出。
- **PDF：** 预览、提取指定页、每页拆成单独 PDF。

## 其他

- **Finder 右键：** 快速操作 / 服务 → “用轻與转换…”（没看到就到“系统设置 → 键盘 → 键盘快捷键 → 服务”勾选）。
- **进度：** 松手后轮盘变成进度圆环，点击圆环取消；结束发系统通知。
- **已选中的文件按 Shift 会被 Finder 取消选中：** 先拖起文件再按 Shift，或在菜单栏打开“已选中文件时 Shift 不取消选中”（需要辅助功能权限，默认关闭）。
- **不覆盖已有文件：** 先写临时文件再改名，重名自动加数字，失败不留残渣。

## 可选组件

WebP、MP3、PDF→DOCX 需要一次性安装（约 250 MB，联网），装进 `~/Library/Application Support/Phaeton`，不改动系统。第一次用到时会询问；也可运行 `bash scripts/install-extras.sh`。它们有各自的许可证（GPL / AGPL / LGPL），见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 构建与测试

macOS 13+ 和 Swift 工具链，无 Swift 包依赖。

```bash
bash scripts/build-app.sh     # 生成 dist/Phaeton.app（本地临时签名）
swift test                    # 单元测试，需要完整 Xcode
bash scripts/validate.sh      # 引擎端到端检查，样本现场生成
bash scripts/make-release.sh  # 打包 Release zip
```

测试覆盖转换引擎，不含界面和拖拽手感。

## 已知限制

- 拖拽监听依赖 macOS 向后台应用传递鼠标事件；收不到时轮盘不出现，可用右键入口。
- 不支持 MKV / WebM / AVI 输入、FLAC / OGG 输出、Word 以外的 Office 转 PDF。
- PDF→DOCX 不保证复杂排版，扫描件不做文字识别。

MIT 许可，见 [LICENSE](LICENSE)。
