// File-streamed uploads and downloads with the account's auth (docs/spec/1x-attachments.md §3.3, §8.2, §13.1).
// Each runs as its own task on the account's bulk pool (its cookie jar, redirects refused) with a per-task delegate
// for progress, the byte ceiling and the body; `GatewayAuth` decorates it exactly as `rest` (cookies, or the Nous
// bearer applied at send time) and a 401 on an /api/ route refreshes once (single flight) and sends again.

import Foundation
import Synchronization

nonisolated enum GatewayTransfer {
    /// The most an upload's answer may hold (the answer is a small JSON record).
    static let answerCeiling = 1 << 20

    static func upload(auth: GatewayAuth, transport: HTTPTransport, base: URL, path: String, query: [URLQueryItem],
                       contentType: String, bodyFile: URL, timeout: TimeInterval, priority: Float,
                       progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> Data {
        let url = try GatewayAddress.endpoint(base: base, path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: min(max(timeout, 1), 600))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let ext = bodyFile.pathExtension.isEmpty ? "?" : bodyFile.pathExtension
        let size = (try? FileManager.default.attributesOfItem(atPath: bodyFile.path)[.size] as? Int64) ?? -1
        let began = ContinuousClock.now
        AppLog.trace("transfer", "upload start \(contentType)/\(ext), \(size) B, \(AppLog.path(url))")
        let milestones = TransferMilestones()
        let watched: (@Sendable (Int64, Int64) -> Void)? = { sent, total in
            progress?(sent, total)
            if let pct = milestones.crossed(sent, total) { AppLog.trace("transfer", "upload \(pct)%: \(sent)/\(total) B") }
        }
        var retried = false
        while true {
            let (prepared, sentAccess) = try await auth.prepareTransfer(request)
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await TransferTask.upload(prepared, file: bodyFile, transport: transport, priority: priority,
                                                                 ceiling: answerCeiling, progress: watched)
            } catch {
                AppLog.note("transfer", "upload failed: \(AppLog.scrub(String(describing: error))), \(AppLog.ms(since: began)) ms")
                throw error
            }
            if try await auth.finishTransfer(response, request: request, sentAccess: sentAccess, retried: retried) {
                retried = true
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                let detail = String(decoding: data.prefix(64 << 10), as: UTF8.self)
                AppLog.note("transfer", "upload failed: \(response.statusCode) \(detail.prefix(200)), \(AppLog.ms(since: began)) ms")
                throw HTTPError(status: response.statusCode, body: detail)
            }
            AppLog.trace("transfer", "upload finished: \(response.statusCode), \(AppLog.ms(since: began)) ms")
            return data
        }
    }

    static func download(auth: GatewayAuth, transport: HTTPTransport, base: URL, path: String, query: [URLQueryItem], to file: URL,
                         ceiling: Int64, priority: Float, progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> HTTPURLResponse {
        let url = try GatewayAddress.endpoint(base: base, path: path, query: query)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        let ext = file.pathExtension.isEmpty ? "?" : file.pathExtension
        let began = ContinuousClock.now
        AppLog.trace("transfer", "download start \(ext), ceiling \(ceiling) B, \(AppLog.path(url))")
        let milestones = TransferMilestones()
        let watched: (@Sendable (Int64, Int64) -> Void)? = { written, total in
            progress?(written, total)
            if let pct = milestones.crossed(written, total) { AppLog.trace("transfer", "download \(pct)%: \(written)/\(total) B") }
        }
        var retried = false
        while true {
            let (prepared, sentAccess) = try await auth.prepareTransfer(request)
            let (response, errorBody): (HTTPURLResponse, Data?)
            do {
                (response, errorBody) = try await TransferTask.download(prepared, to: file, transport: transport, priority: priority,
                                                                        ceiling: ceiling, progress: watched)
            } catch {
                AppLog.note("transfer", "download failed: \(AppLog.scrub(String(describing: error))), \(AppLog.ms(since: began)) ms")
                throw error
            }
            if try await auth.finishTransfer(response, request: request, sentAccess: sentAccess, retried: retried) {
                retried = true
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                let detail = errorBody.map { String(decoding: $0.prefix(64 << 10), as: UTF8.self) }
                AppLog.note("transfer", "download failed: \(response.statusCode) \(detail?.prefix(200) ?? "")")
                throw HTTPError(status: response.statusCode, body: detail)
            }
            AppLog.trace("transfer", "download finished: \(response.statusCode), \(AppLog.ms(since: began)) ms")
            return response
        }
    }
}

/// Progress milestones at 25/50/75% only, once each, for a transfer's trace lines (never per-byte, never per frame).
nonisolated final class TransferMilestones: @unchecked Sendable {
    private let crossedSet = Mutex<Set<Int>>([])

    func crossed(_ done: Int64, _ total: Int64) -> Int? {
        guard total > 0 else { return nil }
        let pct = Int((Double(done) / Double(total)) * 100)
        guard let milestone = [75, 50, 25].first(where: { pct >= $0 }) else { return nil }
        return crossedSet.withLock { set -> Int? in
            guard !set.contains(milestone) else { return nil }
            set.insert(milestone)
            return milestone
        }
    }
}

/// One URLSession task with its own delegate (iOS 15+ per-task delegates): progress, ceiling and completion.
nonisolated final class TransferTask: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var data = Data()
        var response: HTTPURLResponse?
        var tooLarge = false
        var moved: Bool = false
        var errorBody: Data?
        var uploadContinuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var downloadContinuation: CheckedContinuation<(HTTPURLResponse, Data?), Error>?
    }

    private let state = Mutex(State())
    private let ceiling: Int64
    private let target: URL?
    private let progress: (@Sendable (Int64, Int64) -> Void)?

    private init(ceiling: Int64, target: URL?, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.ceiling = ceiling
        self.target = target
        self.progress = progress
    }

    static func upload(_ request: URLRequest, file: URL, transport: HTTPTransport, priority: Float, ceiling: Int,
                       progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let delegate = TransferTask(ceiling: Int64(ceiling), target: nil, progress: progress)
        let task = try transport.uploadTask(with: request, fromFile: file)
        task.delegate = delegate
        task.priority = priority
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                delegate.state.withLock { $0.uploadContinuation = continuation }
                if Task.isCancelled {
                    // Cancelled before it started: settle here (whoever takes the continuation resumes it).
                    if let taken = delegate.state.withLock({ s -> CheckedContinuation<(Data, HTTPURLResponse), Error>? in
                        defer { s.uploadContinuation = nil }
                        return s.uploadContinuation
                    }) { taken.resume(throwing: CancellationError()) }
                    task.cancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func download(_ request: URLRequest, to file: URL, transport: HTTPTransport, priority: Float, ceiling: Int64,
                         progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> (HTTPURLResponse, Data?) {
        let delegate = TransferTask(ceiling: ceiling, target: file, progress: progress)
        let task = try transport.downloadTask(with: request)
        task.delegate = delegate
        task.priority = priority
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(HTTPURLResponse, Data?), Error>) in
                delegate.state.withLock { $0.downloadContinuation = continuation }
                if Task.isCancelled {
                    if let taken = delegate.state.withLock({ s -> CheckedContinuation<(HTTPURLResponse, Data?), Error>? in
                        defer { s.downloadContinuation = nil }
                        return s.downloadContinuation
                    }) { taken.resume(throwing: CancellationError()) }
                    task.cancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)   // never send credentials to a redirected host; the 3xx is the answer
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        state.withLock { $0.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { s -> Bool in
            guard !s.tooLarge else { return false }
            if Int64(s.data.count + data.count) > ceiling { s.tooLarge = true; return true }
            s.data.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // Error bodies are small; a success past the ceiling (or announcing more) stops here.
        let limit = status >= 400 ? Int64(1 << 20) : ceiling
        if totalBytesWritten > limit || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > limit) {
            state.withLock { $0.tooLarge = true }
            downloadTask.cancel()
            return
        }
        if status < 400 { progress?(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        if (200..<300).contains(status), let target {
            // Moved now: the system deletes `location` when this returns.
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            let moved = (try? FileManager.default.moveItem(at: location, to: target)) != nil
            state.withLock { $0.moved = moved; $0.response = response }
        } else {
            let body = try? Data(contentsOf: location, options: .mappedIfSafe)
            state.withLock { $0.errorBody = body.map { Data($0.prefix(64 << 10)) }; $0.response = response }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (upload, download, s) = state.withLock { s -> (CheckedContinuation<(Data, HTTPURLResponse), Error>?,
                                                            CheckedContinuation<(HTTPURLResponse, Data?), Error>?, State) in
            let u = s.uploadContinuation, d = s.downloadContinuation
            s.uploadContinuation = nil
            s.downloadContinuation = nil
            return (u, d, s)
        }
        let response = s.response ?? task.response as? HTTPURLResponse
        if let upload {
            if s.tooLarge { return upload.resume(throwing: GatewayFailure.responseTooLarge) }
            if let error { return upload.resume(throwing: error) }
            guard let response else { return upload.resume(throwing: URLError(.badServerResponse)) }
            upload.resume(returning: (s.data, response))
        } else if let download {
            if s.tooLarge {
                if let target { try? FileManager.default.removeItem(at: target) }
                return download.resume(throwing: GatewayFailure.responseTooLarge)
            }
            if let error {
                if let target, !s.moved { try? FileManager.default.removeItem(at: target) }
                return download.resume(throwing: error)
            }
            guard let response else { return download.resume(throwing: URLError(.badServerResponse)) }
            if (200..<300).contains(response.statusCode), !s.moved { return download.resume(throwing: URLError(.cannotCreateFile)) }
            download.resume(returning: (response, s.errorBody))
        }
    }
}
