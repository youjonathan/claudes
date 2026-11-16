// lib/windows.swift — prints the pid of every app that owns a full-screen window, one per line.
// Run by lib/update_detect.sh (compiled into the claudes state folder). Read-only: it only asks
// macOS for the window list; it needs no permission and sends nothing anywhere.
import Foundation
import CoreGraphics

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
let screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { exit(1) }

var seen = Set<Int>()
for w in list {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    guard let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
    guard let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
    if screens.contains(where: { $0 == r }) && !seen.contains(pid) {
        seen.insert(pid)
        print(pid)
    }
}
