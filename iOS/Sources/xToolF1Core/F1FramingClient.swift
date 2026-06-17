import Foundation

public final class F1FramingClient {
    public let host: String
    public let port: Int

    public init(host: String, port: Int = 8080) {
        self.host = host
        self.port = port
    }

    public func connect(timeout: TimeInterval = 3) throws {
        _ = try request(path: "/device/machineInfo", timeout: timeout)
    }

    public func startFrame(gcode: String, timeout: TimeInterval = 6) throws {
        try post(
            path: "/processing/upload",
            query: [
                URLQueryItem(name: "gcodeType", value: "frame"),
                URLQueryItem(name: "fileType", value: "txt"),
                URLQueryItem(name: "autoStart", value: "1"),
                URLQueryItem(name: "loopPrint", value: "1")
            ],
            body: gcode,
            timeout: timeout
        )
    }

    public func replaceFrame(gcode: String, timeout: TimeInterval = 6) throws {
        try post(path: "/processing/replace", query: frameReplaceQuery, body: gcode, timeout: timeout)
    }

    public func replaceFrameFast(gcode: String) {
        postWithoutWaiting(path: "/processing/replace", query: frameReplaceQuery, body: gcode)
    }

    public func stop(timeout: TimeInterval = 3) throws {
        try post(path: "/processing/stop", body: "", timeout: timeout)
    }

    public func uploadProcessing(_ gcode: String, taskID: String = UUID().uuidString, timeout: TimeInterval = 30) throws {
        try post(
            path: "/processing/upload",
            query: [
                URLQueryItem(name: "gcodeType", value: "processing"),
                URLQueryItem(name: "fileType", value: "txt"),
                URLQueryItem(name: "taskId", value: taskID)
            ],
            body: gcode,
            timeout: timeout
        )
    }

    public func status(timeout: TimeInterval = 3) throws -> F1ProcessingStatus {
        let data = try request(path: "/cnc/status", timeout: timeout)
        return F1ProcessingStatus(data: data)
    }

    public func uploadProcessingURL(taskID: String) -> URL {
        url(
            path: "/processing/upload",
            query: [
                URLQueryItem(name: "gcodeType", value: "processing"),
                URLQueryItem(name: "fileType", value: "txt"),
                URLQueryItem(name: "taskId", value: taskID)
            ]
        )
    }

    public func replaceFrameURL() -> URL {
        url(path: "/processing/replace", query: frameReplaceQuery)
    }

    private var frameReplaceQuery: [URLQueryItem] {
        [
            URLQueryItem(name: "gcodeType", value: "frame"),
            URLQueryItem(name: "loopPrint", value: "1")
        ]
    }

    private func post(path: String, query: [URLQueryItem] = [], body: String, timeout: TimeInterval) throws {
        var request = URLRequest(url: url(path: path, query: query), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        _ = try self.request(request, timeout: timeout)
    }

    private func postWithoutWaiting(path: String, query: [URLQueryItem] = [], body: String) {
        var request = URLRequest(url: url(path: path, query: query), timeoutInterval: 1)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    private func request(path: String, timeout: TimeInterval) throws -> Data {
        try request(URLRequest(url: url(path: path), timeoutInterval: timeout), timeout: timeout)
    }

    private func request(_ request: URLRequest, timeout: TimeInterval) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        let result = HTTPResult()

        URLSession.shared.dataTask(with: request) { data, response, error in
            result.data = data
            result.error = error
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                result.error = FramingError.httpStatus(status)
            }
            done.signal()
        }.resume()

        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw FramingError.timeout
        }

        if let error = result.error {
            throw error
        }

        return result.data ?? Data()
    }

    private func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

}

public struct F1ProcessingStatus: Equatable, Sendable {
    public var raw: String
    public var ready: Bool
    public var working: Bool
    public var finished: Bool
    public var stopped: Bool
    public var idle: Bool

    public init(raw: String) {
        self.raw = raw
        self.ready = Self.isReady(raw)
        self.working = Self.contains(raw, ["WORK_STARTED", "START_PROCESS", "PRINTING", #""currentStatus":"Work""#, #""currentStatus": "Work""#])
        self.finished = Self.contains(raw, ["WORK_FINISHED", "P_WORK_DONE", "FINISH_PROCESS"])
        self.stopped = Self.contains(raw, ["WORK_STOPED", "WORK_STOPPED", "CANCEL_PROCESS"])
        self.idle = Self.contains(raw, ["IDLE", #""currentStatus":"Idle""#, #""currentStatus": "Idle""#])
    }

    public init(data: Data) {
        self.init(raw: String(data: data, encoding: .utf8) ?? "")
    }

    public static func isReady(_ raw: String) -> Bool {
        ["WORK_PREPARED", "workReady", "BEFORE_START"].contains { raw.contains($0) }
    }

    private static func contains(_ raw: String, _ needles: [String]) -> Bool {
        needles.contains { raw.contains($0) }
    }
}

public enum FramingError: LocalizedError {
    case timeout
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Timed out waiting for the xTool HTTP service"
        case .httpStatus(let status):
            return "xTool HTTP service returned status \(status)"
        }
    }
}

private final class HTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _error: Error?

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

    var error: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }
        set {
            lock.lock()
            _error = newValue
            lock.unlock()
        }
    }
}
