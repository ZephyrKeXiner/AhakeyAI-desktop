import Foundation

/// 访问 app bundle 内置的默认 LCD 素材。
/// 资源由 scripts/build-debug.sh 从项目根的 Resources/DefaultOLED/ 拷贝到
/// AhaKey Studio.app/Contents/Resources/DefaultOLED/。
enum DefaultOLEDAssets {
    private static let subdirectory = "DefaultOLED"

    /// 每个 Mode 在工程里预置的出厂 GIF 文件名（不带扩展名）。
    /// 没有内置素材的 Mode 返回 nil，走用户自定义或固件端默认动图。
    static func bundledFileName(for mode: AhaKeyModeSlot) -> String? {
        switch mode {
        case .mode0:
            return "claude_0"
        case .mode1:
            return "cursor"
        case .mode2:
            return "codex"
        case .mode3:
            return nil
        }
    }

    /// 解析出 bundle 内该 GIF 的绝对文件路径；资源不存在时返回 nil。
    static func bundledAssetPath(for mode: AhaKeyModeSlot) -> String? {
        guard let name = bundledFileName(for: mode) else { return nil }
        return bundledAssetPath(forName: name)
    }

    /// 按名字查找 bundle 里的 .gif，返回绝对路径。
    static func bundledAssetPath(forName name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: subdirectory)?.path
    }

    /// 判断一个 localAssetPath 是否指向当前或历史 app bundle 的内置素材。
    /// 迁移逻辑用：当用户的草稿引用旧构建目录、旧安装位置或旧文件名时，可以安全重写。
    static func isBundledPath(_ path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path

        if let resourcesURL = Bundle.main.resourceURL {
            let currentResourcesPath = resourcesURL
                .appendingPathComponent(subdirectory, isDirectory: true)
                .standardizedFileURL.path
            if normalizedPath.hasPrefix(currentResourcesPath + "/") {
                return true
            }
        }

        // 旧版本会把 bundle 内资源的绝对路径写进 UserDefaults。应用换目录或重新安装后，
        // 该路径不再位于 Bundle.main 下，但目录结构仍能可靠地区分内置素材与普通外部 GIF。
        let historicalBundleMarker = ".app/Contents/Resources/\(subdirectory)/"
        return normalizedPath.contains(historicalBundleMarker)
    }
}
