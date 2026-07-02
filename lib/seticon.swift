import AppKit
// usage: seticon <image-file> <target-path>
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else { exit(1) }
_ = NSWorkspace.shared.setIcon(img, forFile: a[2], options: [])
