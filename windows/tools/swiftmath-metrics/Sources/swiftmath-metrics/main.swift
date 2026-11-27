import Foundation
import SwiftMath

struct Input: Decodable { let source: String; let latex: String; let block: Bool; let size: Double? }
struct Output: Encodable {
    let source: String; let latex: String; let block: Bool; let size: Double
    /// nil where the Mac's MathTypeset.line returns nil (HQMathLine nil, or a width not > 0, or a measure not finite).
    let width: Double?; let ascent: Double?; let descent: Double?
}

let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
var outputs: [Output] = []
for input in inputs {
    let size = input.size ?? 19
    if let line = HQMathLine(latex: input.latex, size: CGFloat(size), block: input.block),
       line.width > 0, line.width.isFinite, line.ascent.isFinite, line.descent.isFinite {
        outputs.append(Output(source: input.source, latex: input.latex, block: input.block, size: size,
                              width: Double(line.width), ascent: Double(line.ascent), descent: Double(line.descent)))
    } else {
        outputs.append(Output(source: input.source, latex: input.latex, block: input.block, size: size,
                              width: nil, ascent: nil, descent: nil))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(outputs))
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
