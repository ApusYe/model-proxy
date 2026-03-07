import Foundation

enum AppPaths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("ModelProxy", isDirectory: true)
    }()
}
