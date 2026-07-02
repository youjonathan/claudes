import AppKit
import CoreImage

// usage: recolor <in.icns> <iconset-dir> <hue 0-255>
let a = CommandLine.arguments
guard a.count >= 4, let hue = Int(a[3]) else {
  FileHandle.standardError.write(Data("usage: recolor <in.icns> <iconset-dir> <hue 0-255>\n".utf8)); exit(2)
}
guard let src = NSImage(contentsOfFile: a[1]),
      let tiff = src.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else { exit(1) }

// hue 0-255 -> a fully-saturated target color
let target = NSColor(hue: CGFloat(hue % 256) / 255.0, saturation: 1, brightness: 1, alpha: 1)
let ciColor = CIColor(color: target)!
let ctx = CIContext(options: nil)
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)

let base = CIImage(cgImage: cg)
let sizes: [(String, Int)] = [
  ("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
  ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
  ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]

for (name, px) in sizes {
  let scale = CGFloat(px) / base.extent.width
  let scaled = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  // CIColorMonochrome: luminance-preserving tint to the target color; alpha passes through.
  let f = CIFilter(name: "CIColorMonochrome")!
  f.setValue(scaled, forKey: kCIInputImageKey)
  f.setValue(ciColor, forKey: "inputColor")
  f.setValue(1.0, forKey: "inputIntensity")
  guard let out = f.outputImage,
        let cgOut = ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: px, height: px)) else { continue }
  let bmp = NSBitmapImageRep(cgImage: cgOut)
  guard let png = bmp.representation(using: .png, properties: [:]) else { continue }
  try? png.write(to: URL(fileURLWithPath: "\(a[2])/\(name).png"))
}
