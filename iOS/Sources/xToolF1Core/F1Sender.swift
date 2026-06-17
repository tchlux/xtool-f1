import Foundation
import Network

public final class F1Sender {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 8780) {
        self.host = host
        self.port = port
    }

    public func send(_ gcode: String, timeout: TimeInterval = 5) throws {
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let result = SendResult()

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                result.error = error
                done.signal()
            }
        }

        connection.start(queue: .global())
        connection.send(content: Data(gcode.utf8), completion: .contentProcessed { error in
            result.error = error
            connection.cancel()
            done.signal()
        })

        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw SenderError.timeout
        }

        if let error = result.error {
            throw error
        }
    }
}

public enum SenderError: Error {
    case timeout
}

private final class SendResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?

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
