// window-id.swift <owner name>: the id of the first on-screen window of that
// application, for `screencapture -l<id>` (docs/screenshots/macos.sh)
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for w in windows {
    if (w[kCGWindowOwnerName as String] as? String) == owner,
       (w[kCGWindowLayer as String] as? Int) == 0,
       let id = w[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
}
exit(1)
