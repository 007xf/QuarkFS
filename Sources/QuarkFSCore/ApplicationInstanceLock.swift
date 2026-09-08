import Darwin
import Foundation

/// An OS-owned lock: process exit releases it, even after a crash. The empty
/// lock file stays in place so another process can never lock a different inode.
public final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Returns nil only when another process owns this lock. Other failures
    /// throw, allowing the caller to stop before opening shared runtime state.
    public static func acquire(at url: URL) throws -> ApplicationInstanceLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ownsDescriptor = false
        defer { if !ownsDescriptor { close(descriptor) } }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid() else {
            throw POSIXError(.EPERM)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        ownsDescriptor = true
        return ApplicationInstanceLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
