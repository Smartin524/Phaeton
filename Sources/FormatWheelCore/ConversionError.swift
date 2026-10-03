#if os(macOS)
import Foundation

public enum ConversionError: Error, LocalizedError, Sendable {
    case notAFileURL
    case unreadableSource
    case invalidImage
    case multipleImages(Int)
    case invalidPixelLimit
    case imageTooLarge(Int)
    case unexpectedImageDimensions
    case cannotRenderImage
    case cannotCreateEncoder
    case encodingFailed
    case outputCreationFailed(Int32)
    case outputWriteFailed(Int32)
    case outputChanged
    case incompleteOutput(URL, String)
    case tooManyOutputNames
    case unsupportedFormat
    case noAudioTrack
    case noVideoTrack
    case unreadableMedia
    case exportFailed(String)
    case cancelled
    case noTextFound
    case unreadableDocument
    case extrasNotInstalled
    case tooManyPages(Int)
    case alreadySmall
    case noSubject
    case needsNewerSystem(String)
    case invalidPages(String)
    case notEnoughFiles

    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "请选择保存在这台 Mac 上的图片。"
        case .unreadableSource:
            return "无法读取原文件。请检查文件是否存在，以及是否有访问权限。"
        case .invalidImage:
            return "文件损坏，或 macOS 无法解码此图片。"
        case .multipleImages(let count):
            return "文件包含 \(count) 张图片或动画帧。请选择单张静态图片，避免丢失内容。"
        case .invalidPixelLimit:
            return "图片转换器的像素限制无效。"
        case .imageTooLarge(let limit):
            return "图片超过 \(limit / 1_000_000) 百万像素的安全限制，未缩小或转换。"
        case .unexpectedImageDimensions:
            return "macOS 无法在校正方向时保留图片完整尺寸。"
        case .cannotRenderImage:
            return "macOS 无法绘制此图片，可能没有足够可用内存。"
        case .cannotCreateEncoder, .encodingFailed:
            return "macOS 无法编码所选格式，未保存完整输出。"
        case .outputCreationFailed(let code):
            return "无法在原文件所在文件夹创建输出（系统错误代码：\(code)）。"
        case .outputWriteFailed(let code):
            return "无法完整写入输出（系统错误代码：\(code)）。"
        case .outputChanged:
            return "输出位置在转换过程中发生变化，请重试。"
        case .incompleteOutput(let url, let reason):
            return "\(reason) 可能残留不完整文件：\(url.path)。使用前请检查。"
        case .tooManyOutputNames:
            return "目标文件夹中存在过多同名文件。"
        case .unsupportedFormat:
            return "不支持把此类文件转为所选格式。"
        case .noAudioTrack:
            return "文件里没有音频轨道。"
        case .noVideoTrack:
            return "文件里没有视频轨道。"
        case .unreadableMedia:
            return "macOS 无法读取这个音频或视频文件，可能是系统不支持的格式。"
        case .exportFailed(let reason):
            return "转换失败：\(reason)"
        case .cancelled:
            return "已取消转换。"
        case .noTextFound:
            return "没有识别到文字。"
        case .unreadableDocument:
            return "无法读取这个文档，可能已损坏或格式不受支持。"
        case .noSubject:
            return "没有找到可以抠出的主体。"
        case .needsNewerSystem(let feature):
            return "\(feature)需要 macOS 14 或更高版本。"
        case .invalidPages(let text):
            return "页码无效：\(text)。请输入类似 1-3,5 的页码。"
        case .notEnoughFiles:
            return "至少需要两个文件。"
        case .alreadySmall:
            return "这个文件已经很小，压缩后反而更大，没有生成新文件。"
        case .tooManyPages(let limit):
            return "页数超过 \(limit) 页的上限，未转换。"
        case .extrasNotInstalled:
            return "需要先运行 scripts/install-extras.sh 安装可选组件。"
        }
    }
}
#endif
