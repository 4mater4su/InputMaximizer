//
//  BackgroundSessionDelegate.swift
//  InputMaximizer
//
//  Handles background URLSession events for robust generation
//

import Foundation

/// Singleton delegate for background URLSession
/// Collects data chunks and manages completion handlers for background requests
final class BackgroundSessionDelegate: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundSessionDelegate()
    
    private var dataTasks: [Int: NSMutableData] = [:]
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private let lock = NSLock()
    
    private override init() {
        super.init()
    }
    
    /// Register a task and get its data when complete
    func dataTask(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.lock()
            dataTasks[task.taskIdentifier] = NSMutableData()
            continuations[task.taskIdentifier] = continuation
            lock.unlock()
            task.resume()
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        if let buffer = dataTasks[dataTask.taskIdentifier] {
            buffer.append(data)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let taskId = task.taskIdentifier
        let continuation = continuations.removeValue(forKey: taskId)
        let dataBuffer = dataTasks.removeValue(forKey: taskId)
        lock.unlock()
        
        if let error = error {
            continuation?.resume(throwing: error)
        } else if let response = task.response {
            let data = (dataBuffer as Data?) ?? Data()
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
    
    // MARK: - Cleanup
    
    /// Clean up any orphaned tasks (shouldn't happen in normal flow)
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        
        dataTasks.removeAll()
        continuations.removeAll()
    }
}

