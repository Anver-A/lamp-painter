import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let D = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
func load(_ p: String) -> CGImage {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: D + "/" + p) as CFURL, nil)!
  return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func ctx(_ w: Int, _ h: Int) -> CGContext {
  CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
// multiply-tint an image, keeping its alpha
func tint(_ img: CGImage, _ c: [CGFloat]) -> CGImage {
  let k = ctx(img.width, img.height)
  let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
  k.draw(img, in: r)
  k.setBlendMode(.multiply); k.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: 1); k.fill(r)
  k.setBlendMode(.destinationIn); k.draw(img, in: r)
  return k.makeImage()!
}

let N = 288                       // render at 2x, downscale to 144
let tile = CGFloat(N) / 5         // 5 tiles across
let hr = tile / 64                // scale for high-res (64 px per tile) sprites
let c = ctx(N, N)
// flip so y grows downwards like Factorio
c.translateBy(x: 0, y: CGFloat(N)); c.scaleBy(x: 1, y: -1)
func drawImg(_ img: CGImage, cx: CGFloat, cy: CGFloat, scale: CGFloat, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
  let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
  c.saveGState()
  c.setAlpha(alpha); c.setBlendMode(blend)
  // undo the flip locally so the sprite isn't upside down
  c.translateBy(x: cx - w / 2, y: cy + h / 2); c.scaleBy(x: 1, y: -1)
  c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  c.restoreGState()
}

// floor: refined concrete, 5x5 tiles, darkened to night
let floor = load("base/graphics/terrain/concrete/refined-concrete.png").cropping(to: CGRect(x: 0, y: 0, width: 320, height: 320))!
drawImg(floor, cx: CGFloat(N) / 2, cy: CGFloat(N) / 2, scale: CGFloat(N) / 320)
c.setFillColor(red: 0, green: 0, blue: 0.02, alpha: 0.68); c.fill(CGRect(x: 0, y: 0, width: N, height: N))

let lamp = load("base/graphics/entity/small-lamp/lamp.png")
let shadow = load("base/graphics/entity/small-lamp/lamp-shadow.png")
let light = load("base/graphics/entity/small-lamp/lamp-light.png")
let glow = load("core/graphics/light-medium.png")
let colours: [[CGFloat]] = [[1, 0.1, 0.1], [0.1, 1, 0.15], [0.15, 0.45, 1], [1, 0.85, 0.1]]
let spots: [(CGFloat, CGFloat)] = [(1.5, 1.5), (3.5, 1.5), (1.5, 3.5), (3.5, 3.5)]

// glows first (additive), so lamps sit on top of the light pool
for (i, s) in spots.enumerated() {
  let g = tint(glow, colours[i])
  drawImg(g, cx: s.0 * tile, cy: s.1 * tile, scale: tile * 3.7 / CGFloat(glow.width), alpha: 0.8, blend: .plusLighter)
}
for (i, s) in spots.enumerated() {
  let x = s.0 * tile, y = s.1 * tile
  drawImg(shadow, cx: x + 8 * hr, cy: y + 9.5 * hr, scale: hr, alpha: 0.5, blend: .multiply)
  drawImg(lamp, cx: x + 0.5 * hr, cy: y + 6 * hr, scale: hr)
  drawImg(tint(light, colours[i]), cx: x, cy: y - 14 * hr, scale: hr, blend: .plusLighter); drawImg(tint(light, colours[i]), cx: x, cy: y - 14 * hr, scale: hr, alpha: 0.6, blend: .plusLighter)
}

// yellow selection-tool box corners from the game's cursor boxes (first 64x64 cell)
let boxes = load("core/graphics/cursor-boxes-32x32.png")
let L = 0.55 * tile, R = 4.45 * tile, cs2 = CGFloat(32) * 0.85
let corners: [(CGRect, CGFloat, CGFloat)] = [
  (CGRect(x: 0, y: 0, width: 32, height: 32), L + cs2 / 2, L + cs2 / 2),
  (CGRect(x: 32, y: 0, width: 32, height: 32), R - cs2 / 2, L + cs2 / 2),
  (CGRect(x: 0, y: 32, width: 32, height: 32), L + cs2 / 2, R - cs2 / 2),
  (CGRect(x: 32, y: 32, width: 32, height: 32), R - cs2 / 2, R - cs2 / 2)]
for (r, x, y) in corners {
  drawImg(boxes.cropping(to: r)!, cx: x, cy: y, scale: 0.85)
}

let full = c.makeImage()!
let small = ctx(144, 144)
small.interpolationQuality = .high
small.draw(full, in: CGRect(x: 0, y: 0, width: 144, height: 144))
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, small.makeImage()!, nil)
CGImageDestinationFinalize(dest)
let dest2 = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + ".big.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest2, full, nil); CGImageDestinationFinalize(dest2)
print("ok")
