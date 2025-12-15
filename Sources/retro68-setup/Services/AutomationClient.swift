import Foundation

/// Swift client for BasiliskII automation server
actor AutomationClient {
    private var socket: Int32 = -1
    private let socketPath: String
    private let instanceId = UUID().uuidString.prefix(8)

    // RPC Protocol constants
    private let RPC_START: Int32 = -3000
    private let RPC_END: Int32 = -3001
    private let RPC_ACK: Int32 = -3002
    private let RPC_REPLY: Int32 = -3003
    private let TYPE_INT32: Int32 = -2002
    private let TYPE_UINT32: Int32 = -2003
    private let TYPE_STRING: Int32 = -2005
    private let TYPE_ARRAY: Int32 = -2006
    private let TYPE_CHAR: Int32 = -2001

    // Method IDs
    private let METHOD_KEY_DOWN: Int32 = 101
    private let METHOD_KEY_UP: Int32 = 102
    private let METHOD_MOUSE_MOVE: Int32 = 103
    private let METHOD_MOUSE_DOWN: Int32 = 104
    private let METHOD_MOUSE_UP: Int32 = 105
    private let METHOD_GET_SCREEN_SIZE: Int32 = 106
    private let METHOD_SCREENSHOT: Int32 = 107
    private let METHOD_TYPE_TEXT: Int32 = 108
    private let METHOD_CLICK: Int32 = 109
    private let METHOD_PING: Int32 = 110
    private let METHOD_WAIT_MS: Int32 = 111

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Connect to the automation server
    func connect() throws {
        print("[client \(instanceId)] connect - creating socket")
        fflush(stdout)
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw AutomationError.connectionFailed("Failed to create socket")
        }
        print("[client \(instanceId)] connect - socket created: \(socket)")
        fflush(stdout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AutomationError.connectionFailed("Socket path too long")
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(socket)
            socket = -1
            throw AutomationError.connectionFailed("Failed to connect: \(String(cString: strerror(errno)))")
        }
    }

    /// Disconnect from the automation server
    func disconnect() {
        if socket >= 0 {
            close(socket)
            socket = -1
        }
    }

    // MARK: - Low-level I/O

    private func sendInt32(_ value: Int32) throws {
        guard socket >= 0 else {
            print("[client] ERROR: socket is invalid (\(socket))")
            fflush(stdout)
            throw AutomationError.sendFailed
        }
        var networkValue = value.bigEndian
        let sent = withUnsafeBytes(of: &networkValue) { ptr in
            send(socket, ptr.baseAddress, 4, 0)
        }
        if sent != 4 {
            print("[client] ERROR: send returned \(sent), errno=\(errno) (\(String(cString: strerror(errno))))")
            fflush(stdout)
            throw AutomationError.sendFailed
        }
    }

    private func sendUInt32(_ value: UInt32) throws {
        var networkValue = value.bigEndian
        let sent = withUnsafeBytes(of: &networkValue) { ptr in
            send(socket, ptr.baseAddress, 4, 0)
        }
        guard sent == 4 else {
            throw AutomationError.sendFailed
        }
    }

    private func recvInt32() throws -> Int32 {
        var value: Int32 = 0
        let received = withUnsafeMutableBytes(of: &value) { ptr in
            recv(socket, ptr.baseAddress, 4, 0)
        }
        guard received == 4 else {
            throw AutomationError.receiveFailed
        }
        return Int32(bigEndian: value)
    }

    private func recvUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        let received = withUnsafeMutableBytes(of: &value) { ptr in
            recv(socket, ptr.baseAddress, 4, 0)
        }
        guard received == 4 else {
            throw AutomationError.receiveFailed
        }
        return UInt32(bigEndian: value)
    }

    private func recvExact(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var totalReceived = 0

        while totalReceived < count {
            let received = data.withUnsafeMutableBytes { ptr in
                recv(socket, ptr.baseAddress! + totalReceived, count - totalReceived, 0)
            }
            guard received > 0 else {
                throw AutomationError.receiveFailed
            }
            totalReceived += received
        }

        return data
    }

    // MARK: - RPC Protocol

    private func sendCall(_ methodId: Int32, args: [(Int32, Any)] = []) throws {
        print("[client] sendCall - RPC_START")
        fflush(stdout)
        try sendInt32(RPC_START)
        print("[client] sendCall - methodId: \(methodId)")
        fflush(stdout)
        try sendInt32(methodId)

        for (type, value) in args {
            try sendInt32(type)
            switch type {
            case TYPE_INT32:
                try sendInt32(value as! Int32)
            case TYPE_UINT32:
                try sendUInt32(value as! UInt32)
            case TYPE_STRING:
                let str = value as! String
                let data = str.data(using: .utf8) ?? Data()
                print("[client] sending string: '\(str)' len=\(data.count)")
                fflush(stdout)
                try sendInt32(Int32(data.count))
                if !data.isEmpty {
                    let sent = data.withUnsafeBytes { ptr in
                        send(socket, ptr.baseAddress, data.count, 0)
                    }
                    print("[client] string bytes sent: \(sent)")
                    fflush(stdout)
                    if sent != data.count {
                        print("[client] ERROR: string send incomplete")
                        fflush(stdout)
                        throw AutomationError.sendFailed
                    }
                }
            default:
                break
            }
        }

        try sendInt32(RPC_END)
    }

    private func recvReply() throws -> [Any] {
        let reply = try recvInt32()
        guard reply == RPC_REPLY else {
            throw AutomationError.protocolError("Expected REPLY, got \(reply)")
        }

        var values: [Any] = []

        while true {
            let typeTag = try recvInt32()
            if typeTag == RPC_END {
                break
            }

            switch typeTag {
            case TYPE_INT32:
                values.append(try recvInt32())
            case TYPE_UINT32:
                values.append(try recvUInt32())
            case TYPE_ARRAY:
                let elemType = try recvInt32()
                let arrayLen = try recvUInt32()
                if elemType == TYPE_CHAR {
                    let data = try recvExact(Int(arrayLen))
                    values.append(data)
                }
            default:
                break
            }
        }

        let ack = try recvInt32()
        guard ack == RPC_ACK else {
            throw AutomationError.protocolError("Expected ACK, got \(ack)")
        }

        return values
    }

    // MARK: - Public API

    /// Test connection to the emulator
    func ping() throws -> Bool {
        print("[client \(instanceId)] ping - socket: \(socket)")
        fflush(stdout)
        try sendCall(METHOD_PING)
        let result = try recvReply()
        return (result.first as? Int32) == 1
    }

    /// Get screen dimensions
    func getScreenSize() throws -> (width: UInt32, height: UInt32, depth: UInt32) {
        try sendCall(METHOD_GET_SCREEN_SIZE)
        let result = try recvReply()
        guard result.count >= 3 else {
            throw AutomationError.protocolError("Invalid screen size response")
        }
        return (result[0] as! UInt32, result[1] as! UInt32, result[2] as! UInt32)
    }

    /// Move mouse to position
    func mouseMove(x: Int32, y: Int32) throws {
        try sendCall(METHOD_MOUSE_MOVE, args: [(TYPE_INT32, x), (TYPE_INT32, y)])
        _ = try recvReply()
    }

    /// Click at position
    func click(x: Int32, y: Int32, button: Int32 = 0) throws {
        print("[client \(instanceId)] click(\(x), \(y)) - socket: \(socket)")
        fflush(stdout)
        try sendCall(METHOD_CLICK, args: [(TYPE_INT32, x), (TYPE_INT32, y), (TYPE_INT32, button)])
        print("[client \(instanceId)] click - waiting for reply")
        fflush(stdout)
        _ = try recvReply()
        print("[client \(instanceId)] click - done")
        fflush(stdout)
    }

    /// Double-click at position
    func doubleClick(x: Int32, y: Int32, button: Int32 = 0) throws {
        try click(x: x, y: y, button: button)
        try waitMs(100)
        try click(x: x, y: y, button: button)
    }

    /// Press mouse button
    func mouseDown(button: Int32 = 0) throws {
        try sendCall(METHOD_MOUSE_DOWN, args: [(TYPE_INT32, button)])
        _ = try recvReply()
    }

    /// Release mouse button
    func mouseUp(button: Int32 = 0) throws {
        try sendCall(METHOD_MOUSE_UP, args: [(TYPE_INT32, button)])
        _ = try recvReply()
    }

    /// Press key
    func keyDown(keycode: Int32) throws {
        try sendCall(METHOD_KEY_DOWN, args: [(TYPE_INT32, keycode)])
        _ = try recvReply()
    }

    /// Release key
    func keyUp(keycode: Int32) throws {
        try sendCall(METHOD_KEY_UP, args: [(TYPE_INT32, keycode)])
        _ = try recvReply()
    }

    /// Type text string
    func typeText(_ text: String) throws {
        print("[client \(instanceId)] typeText('\(text)') - socket: \(socket)")
        fflush(stdout)
        try sendCall(METHOD_TYPE_TEXT, args: [(TYPE_STRING, text)])
        print("[client \(instanceId)] typeText - waiting for reply")
        fflush(stdout)
        _ = try recvReply()
        print("[client \(instanceId)] typeText - done")
        fflush(stdout)
    }

    /// Wait for specified milliseconds
    func waitMs(_ ms: Int32) throws {
        print("[client] waitMs(\(ms)) - sending call")
        fflush(stdout)
        try sendCall(METHOD_WAIT_MS, args: [(TYPE_INT32, ms)])
        print("[client] waitMs - waiting for reply")
        fflush(stdout)
        _ = try recvReply()
        print("[client] waitMs - done")
        fflush(stdout)
    }

    /// Capture screenshot
    func screenshot() throws -> (width: UInt32, height: UInt32, depth: UInt32, bytesPerRow: UInt32, data: Data) {
        try sendCall(METHOD_SCREENSHOT)
        let result = try recvReply()
        guard result.count >= 5 else {
            throw AutomationError.protocolError("Invalid screenshot response")
        }
        return (
            result[0] as! UInt32,
            result[1] as! UInt32,
            result[2] as! UInt32,
            result[3] as! UInt32,
            result[4] as! Data
        )
    }
}

enum AutomationError: Error, LocalizedError {
    case connectionFailed(String)
    case sendFailed
    case receiveFailed
    case protocolError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sendFailed: return "Failed to send data"
        case .receiveFailed: return "Failed to receive data"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .timeout: return "Operation timed out"
        }
    }
}
