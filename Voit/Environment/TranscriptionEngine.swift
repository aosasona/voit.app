//
//  ProcessingQueue.swift
//  Voit
//
//  Created by Ayodeji Osasona on 01/10/2023.
//

import Foundation
import SwiftData
import SwiftUI
import SwiftWhisper

enum TranscriptionError: Error {
    case noAudioFrames
    case noSegments
}

final class TranscriptionEngine: ObservableObject {
    static let shared = TranscriptionEngine()
    
    @Published var hasInitializedContext = false
    @Published var importingFiles = false
    @Published var queue = [Recording]()
    @Published var isLocked = false
    
    private var ctx: Whisper? = nil
    private let modelController = ModelService()
    private let processingQueue = DispatchQueue(label: "queue.processing")
    
    // Queue methods
    public func enqueue(_ recording: Recording) {
        // make sure it hasn't failed one too many times before adding it to the queue
        guard recording.failedAttempts < 5 else { return }
        self.queue.append(recording)
    }

    public func enqueueMultiple(_ recordings: [Recording]) { recordings.forEach { self.enqueue($0) } }
    private func next() -> Recording? { return self.queue.first }
    public func dequeue(_ recording: Recording) { self.queue.removeAll(where: { $0.id == recording.id }) }
    public func dequeue() {
        guard self.queue.count > 0 else { return }
        self.queue.remove(at: 0)
    }
    
    // Engine methods
    public func isImportingFiles() { DispatchQueue.main.async { self.importingFiles = true } }
    public func hasImportedFiles() { DispatchQueue.main.async { self.importingFiles = false } }
    
    public func initWhisperCtx() throws {
        DispatchQueue.main.async { self.hasInitializedContext = false }
        let params = WhisperParams(strategy: .greedy)
        params.language = self.modelController.language
        guard let modelUrl = ModelService.getModelURL(modelController.model) else { return }
        self.ctx = Whisper(fromFileURL: modelUrl, withParams: params)
        DispatchQueue.main.async { self.hasInitializedContext = true }
    }
    
    private func lock() { DispatchQueue.main.async { self.isLocked = true } }
    private func unlock() { DispatchQueue.main.async { self.isLocked = false } }
    
    private func cancel(_ recording: Recording) throws {
        if let inProgress = self.ctx?.inProgress {
            if inProgress { try? self.ctx?.cancel {} }
        }
        
        // TODO: get it out of the queue properly (private for now)
        if let recording = self.next() { recording.status = .pending }
        DispatchQueue.main.async { self.dequeue(recording) }
        self.startProcessing()
    }
    
    private func transcribe(frames audioFrames: [Float], recording: Recording, onComplete: @escaping ([Segment]) -> Void) {
        // TODO: btter error handling
        self.ctx?.transcribe(audioFrames: audioFrames) { result in
            switch result {
            case .failure(let e):
                print(e.localizedDescription)
            case .success(let segments):
                onComplete(segments)
            }
        }
    }
    
    private func toAudioFrames(path: URL, onComplete: @escaping ([Float]) -> Void) {
        // TODO: btter error handling
        AudioService.convertToPCMArray(input: path) { result in
            switch result {
            case .failure(let e):
                print(e.localizedDescription)
            case .success(let audioFrames):
                onComplete(audioFrames)
            }
        }
    }
    
    private func process(_ recording: Recording) {
        // Prevent recordings that have failed one too many times from being processed
        if recording.failedAttempts >= 5 {
            DispatchQueue.main.async { self.dequeue(recording) }
            print("Failed too many times, will not retry (\(recording.title)")
            return
        }
        
        recording.status = .processing
        
        guard let path = recording.path else {
            print("Unable to get path for \(recording.title)")
            return
        }
        
        self.toAudioFrames(path: path) { frames in
            self.transcribe(frames: frames, recording: recording) { rawSegments in
                let segments = rawSegments.map { TranscriptSegment(text: $0.text, startTime: $0.startTime, endTime: $0.endTime) }
                recording.transcript = Transcript(segments: segments)
                recording.status = .processed
                recording.lastModifiedAt = .now
                
                // Remove from queue, release lock and recursely process next item
                // TODO: send notification on completion if enabled
                DispatchQueue.main.async {
                    Notification.main.trigger(title: "Recording processed!", subtitle: "`\(recording.title)` has now been processed and added to your library")
                    self.dequeue()
                    self.unlock()
                    self.startProcessing()
                }
            }
        }
    }
     
    /// Start processing items in the queue recursively
    public func startProcessing() {
        guard !self.isLocked else { return }
        self.processingQueue.async {
            // Acquire lock
            self.lock()
            
            guard let recording = self.next() else {
                self.unlock()
                return
            }
            
            self.process(recording)
        }
    }
}
