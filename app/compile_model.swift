// Compiles a Core ML package into an .mlmodelc folder with the system Core ML framework.
// build.sh uses this instead of `xcrun coremlcompiler`, which ships only with full Xcode:
// the Command Line Tools alone are enough to build GoldWare OS.
// Usage: swift compile_model.swift <in.mlpackage> <out dir>
import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: swift compile_model.swift <in.mlpackage> <out dir>\n", stderr); exit(2) }
let source = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
do {
    let compiled = try MLModel.compileModel(at: source)   // lands in a temp folder
    let dest = outDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mlmodelc")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: compiled, to: dest)
} catch {
    fputs("Could not compile \(source.path): \(error)\n", stderr)
    exit(1)
}
