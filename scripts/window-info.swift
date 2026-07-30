import CoreGraphics
import Foundation

let targetOwner = CommandLine.arguments.dropFirst().first ?? "CodexWorkbenchApp"
let targetProcessID = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init)
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let name = window[kCGWindowName as String] as? String ?? ""
    let processID = window[kCGWindowOwnerPID as String] as? Int ?? 0
    guard owner == targetOwner || name == targetOwner else { continue }
    guard targetProcessID == nil || processID == targetProcessID else { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(
        "id=\(number) pid=\(processID) layer=\(layer) "
            + "owner=\(owner) name=\(name) bounds=\(bounds)"
    )
}
