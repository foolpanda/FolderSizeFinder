import Foundation

/// 单个枚举事件(后台 -> 主线程的批量载荷)
struct ScanEvent {
    let path: String       // 相对扫描根的路径
    let isDirectory: Bool
    let logical: Int64
    let allocated: Int64
}

/// 后台目录扫描器:NSDirectoryEnumerator 深度优先(先序)遍历,
/// 每累计 8192 条或 200ms 回传一批,由主线程增量建树(小批保证主线程流畅,扫描中仍可展开/交互)。
enum DirectoryScanner {
    final class ErrorBox: @unchecked Sendable {
        var count = 0
        var last: String?
    }

    /// 返回无法读取的条目数
    static func scan(
        root: URL,
        includeHidden: Bool,
        onBatch: @Sendable ([ScanEvent]) async -> Void
    ) async -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let keySet = Set(keys)

        var options: FileManager.DirectoryEnumerationOptions = [.producesRelativePathURLs]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let box = ErrorBox()
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { url, error in
                box.count += 1
                box.last = "\(url.path): \(error.localizedDescription)"
                return true
            }
        ) else {
            box.count += 1
            box.last = "无法读取 \(root.path)"
            return 1
        }

        var batch: [ScanEvent] = []
        batch.reserveCapacity(8192)
        var lastFlush = DispatchTime.now().uptimeNanoseconds

        while let obj = enumerator.nextObject() {
            if Task.isCancelled { return box.count }
            guard let url = obj as? URL else { continue }

            let values = try? url.resourceValues(forKeys: keySet)
            let isDir = values?.isDirectory ?? false
            let logical = Int64(values?.fileSize ?? 0)
            let allocated = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)

            batch.append(ScanEvent(
                path: url.relativePath,
                isDirectory: isDir,
                logical: logical,
                allocated: allocated
            ))

            if batch.count >= 8192 ||
                (batch.count & 4095) == 0 && DispatchTime.now().uptimeNanoseconds &- lastFlush > 200_000_000 {
                await onBatch(batch)
                batch.removeAll(keepingCapacity: true)
                lastFlush = DispatchTime.now().uptimeNanoseconds
            }
        }

        if !batch.isEmpty { await onBatch(batch) }
        return box.count
    }
}
