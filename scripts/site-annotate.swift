// site-annotate — the numbered outlines on the English guide's pictures.
//
//     swift scripts/site-annotate.swift          (from the repository root)
//
// Each picture is a snapshot baseline (ios/Tests/Fixtures/snapshots, the real
// views rendered by ViewSnapshotTests) with the parts the guide talks about
// outlined and numbered, and the rest dimmed. The style is the Chinese
// pictures': a 3 px outline with a 14 px corner, a badge 20 px in radius on the
// top right corner, everything outside the outlines under 43 % black.
// The boxes are pixels of the 780 px wide baseline, left, top, right, bottom.
// A baseline that is re-recorded with another layout wants them measured again.
import Foundation
import CoreGraphics
import CoreText
import ImageIO

struct Picture {
    let source: String, out: String
    let height: Int?                 // keep only the top rows (nil = all of it)
    let boxes: [[CGFloat]]
}

let snapshots = "ios/Tests/Fixtures/snapshots/"
let docs = "web/assets/docs/"
let pictures = [
    Picture(source: "snap-home-page-en.png", out: "home-page-annotated-en.png", height: nil,
            boxes: [[35, 145, 752, 206], [28, 242, 204, 291], [387, 242, 491, 291], [46, 482, 150, 524], [28, 578, 752, 658]]),
    Picture(source: "snap-chat-composer-en.png", out: "chat-composer-annotated-en.png", height: nil,
            boxes: [[98, 400, 172, 478], [630, 14, 742, 75], [20, 89, 760, 358]]),
    Picture(source: "snap-market-row-subscribed-en.png", out: "market-row-subscribed-annotated-en.png", height: 300,
            boxes: [[148, 197, 334, 246], [339, 197, 594, 246]]),
    Picture(source: "snap-route-editor-en.png", out: "route-editor-en.png", height: nil, boxes: []),
]

let orange = CGColor(srgbRed: 233 / 255, green: 90 / 255, blue: 42 / 255, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func fail(_ words: String) -> Never {
    FileHandle.standardError.write((words + "\n").data(using: .utf8)!)
    exit(1)
}

for p in pictures {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: snapshots + p.source) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(snapshots + p.source)") }
    let w = image.width, full = image.height, h = p.height ?? full
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no canvas") }
    // the baseline, its top edge on the canvas's top edge
    ctx.draw(image, in: CGRect(x: 0, y: h - full, width: w, height: full))
    // from here on y runs down, like the numbers in the table
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    let rects = p.boxes.map { CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1]) }
    if !rects.isEmpty {
        let dim = CGMutablePath()
        dim.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        for r in rects { dim.addRoundedRect(in: r, cornerWidth: 14, cornerHeight: 14) }
        ctx.addPath(dim)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.43))
        ctx.fillPath(using: .evenOdd)
    }
    for r in rects {
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 12.5, cornerHeight: 12.5, transform: nil))
        ctx.setStrokeColor(orange)
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
    for (i, r) in rects.enumerated() {
        let c = CGPoint(x: r.maxX, y: r.minY)
        ctx.setFillColor(orange)
        ctx.fillEllipse(in: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 25, nil)!
        let text = NSAttributedString(string: "\(i + 1)", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: c.x - box.midX, y: c.y + box.midY)
        CTLineDraw(line, ctx)
    }
    guard let result = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: docs + p.out) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("cannot write \(docs + p.out)") }
    CGImageDestinationAddImage(dest, result, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot write \(docs + p.out)") }
    print("\(docs + p.out)  \(w)x\(h)  \(rects.count) outlined")
}
