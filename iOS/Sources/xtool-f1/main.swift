import Foundation
import xToolF1Core

let args = CommandLine.arguments.dropFirst()
let send = args.contains("--send")
let host = value(after: "--host", in: Array(args))
let projectPath = args.first { !$0.hasPrefix("--") && $0 != host } ?? "sample.xtoolproject.json"
let project = try JSONDecoder().decode(LaserProject.self, from: Data(contentsOf: URL(fileURLWithPath: projectPath)))
let gcode = GCodeGenerator.makeGCode(for: project)

if send {
    let endpoint = try host.map { F1MachineEndpoint(host: $0) } ?? F1Discovery().discover()
    try F1Sender(host: endpoint.host, port: endpoint.tcpPort).send(gcode)
    print("sent \(gcode.utf8.count) bytes to \(endpoint.host):\(endpoint.tcpPort)")
} else {
    print(gcode)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}
