import Foundation
import Network

/// Allocates available ports for Core process
/// Uses NWListener to bind to port 0 and get system-assigned port
enum PortAllocator {
    /// Port range for dynamic allocation (ephemeral ports)
    static let portRangeStart: UInt16 = 49152
    static let portRangeEnd: UInt16 = 65535

    /// Find an available port by binding to port 0
    /// Returns the system-assigned port, or nil if allocation fails
    static func findAvailablePort() -> Int? {
        // Create a TCP socket
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            print("[PortAllocator] Failed to create socket")
            return nil
        }
        defer { close(socketFD) }

        // Allow address reuse
        var reuseAddr: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port 0 on localhost
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // Let system assign port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[PortAllocator] Failed to bind socket: \(errno)")
            return nil
        }

        // Get the assigned port
        var assignedAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let getsocknameResult = withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(socketFD, sockaddrPtr, &addrLen)
            }
        }

        guard getsocknameResult == 0 else {
            print("[PortAllocator] Failed to get socket name: \(errno)")
            return nil
        }

        let port = Int(UInt16(bigEndian: assignedAddr.sin_port))
        print("[PortAllocator] Allocated port: \(port)")
        return port
    }

    /// Check if a port is available by attempting to bind
    static func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return bindResult == 0
    }
}
