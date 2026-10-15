import Foundation
import WorkScribeCore
let args = CommandLine.arguments
do {
    guard let index = args.firstIndex(of: "--bench-vectors"), index + 1 < args.count,
          let n = Int(args[index + 1]) else { throw EmbedderError.badVector("usage: WorkScribeVectorBench --bench-vectors N") }
    let result = try VectorBenchmark.run(count: n)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
    print("")
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
