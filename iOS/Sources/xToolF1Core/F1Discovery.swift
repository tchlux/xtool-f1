import Darwin
import Foundation

public struct F1MachineEndpoint: Equatable, Sendable {
    public let host: String
    public let httpPort: Int
    public let tcpPort: UInt16
    public let deviceName: String?
    public let serial: String?
    public let firmwareVersion: String?

    public init(host: String, httpPort: Int = 8080, tcpPort: UInt16 = 8780, deviceName: String? = nil, serial: String? = nil, firmwareVersion: String? = nil) {
        self.host = host
        self.httpPort = httpPort
        self.tcpPort = tcpPort
        self.deviceName = deviceName
        self.serial = serial
        self.firmwareVersion = firmwareVersion
    }
}

public final class F1Discovery {
    public init() {}

    public func discover(timeout: TimeInterval = 0.7, preferredHosts: [String] = []) throws -> F1MachineEndpoint {
        let interface = try Self.wifiInterface()
        let stats = ProbeStats()
        for host in Self.preferredHosts(preferredHosts, address: interface.address) {
            for port in Self.httpPorts {
                if let endpoint = Self.probe(host: host, port: port, timeout: timeout, stats: stats) {
                    return endpoint
                }
            }
        }

        let hosts = Self.candidateHosts(address: interface.address, netmask: interface.netmask)
            .sorted { Self.hostSort($0, $1, from: interface.address) }
            .filter { !preferredHosts.contains($0) }
        let result = DiscoveryResult()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 32

        for host in hosts {
            for port in Self.httpPorts {
                queue.addOperation {
                    guard result.endpoint == nil else { return }
                    if let endpoint = Self.probe(host: host, port: port, timeout: timeout, stats: stats) {
                        result.endpoint = endpoint
                        queue.cancelAllOperations()
                    }
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()
        guard let endpoint = result.endpoint else {
            throw DiscoveryError.notFound("scanned \(hosts.count) hosts from \(interface.name) \(Self.ipString(interface.address))/\(Self.ipString(interface.netmask)); \(stats.summary)")
        }
        return endpoint
    }

    static func candidateHosts(address: UInt32, netmask: UInt32) -> [String] {
        let network = address & netmask
        let broadcast = network | ~netmask
        guard broadcast > network else { return [] }
        return ((network + 1)..<broadcast)
            .filter { $0 != address }
            .map(ipString)
    }

    static func orderedHosts(preferredHosts: [String], address: UInt32, netmask: UInt32) -> [String] {
        let candidates = candidateHosts(address: address, netmask: netmask)
            .sorted { hostSort($0, $1, from: address) }
        let preferred = Self.preferredHosts(preferredHosts, address: address)
        return preferred + candidates.filter { !preferred.contains($0) }
    }

    private static func preferredHosts(_ hosts: [String], address: UInt32) -> [String] {
        var seen = Set<String>()
        return hosts.filter { $0 != ipString(address) && seen.insert($0).inserted }
    }

    static func machineEndpoint(from data: Data, host: String, port: Int) -> F1MachineEndpoint? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let object = (root["data"] as? [String: Any]) ?? root
        guard isF1(object) else { return nil }
        let firmware = object["firmware"] as? [String: Any]
        let firmwareVersion = firmware?["package_version"] as? String
            ?? (firmware?["version"] as? [String: Any])?["master_h3_laserservice"] as? String
        return F1MachineEndpoint(
            host: host,
            httpPort: port,
            deviceName: object["deviceName"] as? String,
            serial: object["sn"] as? String,
            firmwareVersion: firmwareVersion
        )
    }

    private static let httpPorts = [8080, 80, 8081]

    private static func probe(host: String, port: Int, timeout: TimeInterval, stats: ProbeStats) -> F1MachineEndpoint? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/device/machineInfo"
        guard let url = components.url else { return nil }

        let done = DispatchSemaphore(value: 0)
        let result = ProbeResult()
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, response, error in
            if let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                result.data = data
            } else if let status = (response as? HTTPURLResponse)?.statusCode {
                stats.add("HTTP \(status) at \(host):\(port)")
            } else if let error {
                stats.add("\(host):\(port) \(error.localizedDescription)")
            }
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + timeout) == .timedOut {
            stats.add("timeout at \(host):\(port)")
            return nil
        }
        guard let data = result.data else { return nil }
        let endpoint = machineEndpoint(from: data, host: host, port: port)
        if endpoint == nil, let body = String(data: data.prefix(80), encoding: .utf8) {
            stats.add("non-F1 response at \(host):\(port): \(body)")
        }
        return endpoint
    }

    private static func wifiInterface() throws -> IPv4Interface {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { throw DiscoveryError.noWifiInterface }
        defer { freeifaddrs(interfaces) }

        var matches: [IPv4Interface] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard
                let addressPointer = current.pointee.ifa_addr,
                let netmaskPointer = current.pointee.ifa_netmask,
                flags & IFF_UP != 0,
                flags & IFF_LOOPBACK == 0,
                addressPointer.pointee.sa_family == UInt8(AF_INET),
                let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { Optional($0.pointee.sin_addr.s_addr) }),
                let netmask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { Optional($0.pointee.sin_addr.s_addr) })
            else { continue }
            matches.append(IPv4Interface(name: String(cString: current.pointee.ifa_name), address: UInt32(bigEndian: address), netmask: UInt32(bigEndian: netmask)))
        }

        guard let match = matches.first(where: { $0.name == "en0" }) ?? matches.first else { throw DiscoveryError.noWifiInterface }
        return match
    }

    private static func isF1(_ object: [String: Any]) -> Bool {
        let code = (object["deviceCode"] as? String)?.uppercased() ?? ""
        let name = (object["deviceName"] as? String)?.uppercased() ?? ""
        let subtype = (object["machineSubType"] as? String)?.uppercased() ?? ""
        if code == "MF1" || code.contains("F1") || name.contains("F1") || subtype.contains("F1") { return true }
        guard
            subtype == "LG4",
            let laserPower = object["laserPower"] as? [Int],
            let laserType = object["laserType"] as? [String],
            let workSize = object["workSize"] as? [String: Any],
            let width = workSize["x"] as? Double,
            let height = workSize["y"] as? Double
        else { return false }
        return laserPower == [10, 2]
            && Set(laserType.map { $0.uppercased() }) == ["RED", "BLUE"]
            && (110...130).contains(width)
            && (110...130).contains(height)
    }

    private static func ipString(_ ip: UInt32) -> String {
        "\(ip >> 24 & 255).\(ip >> 16 & 255).\(ip >> 8 & 255).\(ip & 255)"
    }

    private static func distance(_ host: String, from address: UInt32) -> UInt32 {
        let parts = host.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return UInt32.max }
        let hostAddress = parts.reduce(0) { ($0 << 8) | $1 }
        return hostAddress > address ? hostAddress - address : address - hostAddress
    }

    private static func hostSort(_ left: String, _ right: String, from address: UInt32) -> Bool {
        let leftDistance = distance(left, from: address)
        let rightDistance = distance(right, from: address)
        return leftDistance == rightDistance ? left < right : leftDistance < rightDistance
    }
}

public enum DiscoveryError: LocalizedError {
    case noWifiInterface
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .noWifiInterface:
            return "No active Wi-Fi IPv4 network was found"
        case .notFound(let details):
            return "No xTool F1 was found on the current Wi-Fi network (\(details))"
        }
    }
}

private struct IPv4Interface {
    var name: String
    var address: UInt32
    var netmask: UInt32
}

private final class DiscoveryResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _endpoint: F1MachineEndpoint?

    var endpoint: F1MachineEndpoint? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _endpoint
        }
        set {
            lock.lock()
            _endpoint = newValue
            lock.unlock()
        }
    }
}

private final class ProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?

    var data: Data? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }
        set {
            lock.lock()
            _data = newValue
            lock.unlock()
        }
    }
}

private final class ProbeStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [String] = []

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return samples.isEmpty ? "no HTTP responses" : samples.joined(separator: "; ")
    }

    func add(_ sample: String) {
        lock.lock()
        defer { lock.unlock() }
        if samples.count < 8, !samples.contains(sample) {
            samples.append(sample)
        }
    }
}
