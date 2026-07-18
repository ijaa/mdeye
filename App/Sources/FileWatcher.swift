import Foundation

final class FileWatcher {
    var onChange: ((String) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var watchedPath: String?
    private let queue = DispatchQueue(label: "app.mdeye.filewatcher")
    private var debounceWork: DispatchWorkItem?

    func watch(path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            self.watchedPath = path
            self.armLocked(path: path)
        }
    }

    /// Open fd + install the DispatchSource. Must run on `queue` with no active source.
    private func armLocked(path: String) {
        let newFd = open(path, O_EVTONLY)
        guard newFd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.scheduleNotify()
        }
        src.setCancelHandler { [newFd] in
            close(newFd)
        }
        // Point of no return: only mutate shared state after the source is built.
        fd = newFd
        source = src
        src.resume()
    }

    /// Synchronous teardown (already on `queue`): cancel source, reset state.
    private func teardownLocked() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
        fd = -1
        watchedPath = nil
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardownLocked()
        }
    }

    private func scheduleNotify() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let path = self.watchedPath else { return }
            // Re-arm after rename/replace (common for atomic saves): drop the old
            // source and open a fresh fd+source, then notify.
            guard FileManager.default.fileExists(atPath: path) else { return }
            self.source?.cancel()
            self.source = nil
            self.fd = -1
            self.armLocked(path: path)
            self.onChange?(path)
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    deinit {
        // Cancel synchronously on dealloc since `self` is going away.
        debounceWork?.cancel()
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }
}
