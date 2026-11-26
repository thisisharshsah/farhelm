import Foundation

private final class ChatDocumentBundleFinder {}

/// Where the chat document's page (`page/index.html`, `chat.css`,
/// `chat.js`) is at run time. SwiftPM bundles resources only inside a
/// target's own folder, so the page is a target of its own; its bundle sits
/// beside the binary in a build and in Contents/Resources in the app
/// (build.sh copies every SwiftPM bundle there). Found here rather than
/// through `Bundle.module`, which stops the app when its bundle is missing.
public enum ChatDocumentPage {
    public static let bundleName = "Companion_ChatDocumentPage.bundle"

    /// The folder holding index.html, or nil when this build has no page.
    public static let folder: URL? = {
        var places: [URL] = []
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            places.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        if let resources = Bundle.main.resourceURL { places.append(resources) }
        if let resources = Bundle(for: ChatDocumentBundleFinder.self).resourceURL { places.append(resources) }
        places.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL { places.append(executable.deletingLastPathComponent()) }
        for place in places {
            let bundle = place.appendingPathComponent(bundleName, isDirectory: true)
            for candidate in [bundle.appendingPathComponent("page", isDirectory: true),
                              bundle.appendingPathComponent("Contents/Resources/page", isDirectory: true)]
            where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate
            }
        }
        return nil
    }()
}