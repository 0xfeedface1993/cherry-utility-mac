import Darwin
import Foundation

/// 客户端与服务端共用的 AF_UNIX 系统调用封装。
enum UnixSocket {
    struct SystemError: Error, Equatable, Sendable {
        let operation: String
        let code: Int32
    }

    /// `sun_path` 的容量（含结尾的 0）。
    static let pathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func fits(_ path: String) -> Bool { path.utf8.count < pathCapacity }

    /// 新建流式 socket：exec 时关闭，写入已断开的对端时返回 EPIPE 而不是触发 SIGPIPE。
    static func make() throws(SystemError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemError(operation: "socket", code: errno) }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// 以 `path` 构造地址并调用 `body`（connect / bind）。调用前须已用 `fits` 检查长度。
    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// 阻塞 socket 的读写超时；nil 为不限时。
    static func setTimeout(_ fd: Int32, option: Int32, _ duration: Duration?) {
        var value = timeval()
        if let duration {
            let (seconds, attoseconds) = duration.components
            value.tv_sec = Int(seconds)
            value.tv_usec = Int32(attoseconds / 1_000_000_000_000)
        }
        _ = setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// 写完全部字节。非阻塞 fd 写满时最多等 `stall` 再继续；对端不读就放弃。
    static func writeAll(_ fd: Int32, _ data: Data, stall: Int32 = 2_000) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&descriptor, 1, stall) > 0 else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }
}
