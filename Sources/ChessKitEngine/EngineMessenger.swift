//
//  EngineMessenger.swift
//  ChessKitEngine
//

import ChessKitEngineCore
import Darwin
import Foundation

private final class WeakActorBox<T: AnyObject>: @unchecked Sendable {
  weak var value: T?

  init(_ value: T) {
    self.value = value
  }
}

private struct EngineHandle: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer
}

private struct ObserverToken: @unchecked Sendable {
  let value: NSObjectProtocol
}

actor EngineMessenger {

  typealias ResponseHandler = @Sendable (String) -> Void

  /// Sets the closure invoked for every engine response.
  func setResponseHandler(_ handler: ResponseHandler?) {
    responseHandler = handler
  }

  /// Opens the communication channel with the engine.
  func start() async {
    guard readPipe == nil, writePipe == nil else { return }

    let readPipe = Pipe()
    self.readPipe = readPipe
    pipeReadHandle = readPipe.fileHandleForReading

    let writeHandle = readPipe.fileHandleForWriting
    dup2(writeHandle.fileDescriptor, STDOUT_FILENO)

    if let pipeReadHandle {
      let weakSelf = WeakActorBox(self)
      let observer = notificationCenter.addObserver(
        forName: FileHandle.readCompletionNotification,
        object: pipeReadHandle,
        queue: nil
      ) { notification in
        guard
          let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data
        else { return }

        Task {
          guard let messenger = weakSelf.value else { return }
          await messenger.handleStdout(data)
        }
      }
      stdoutObserver = ObserverToken(value: observer)

      await MainActor.run {
        pipeReadHandle.readInBackgroundAndNotify()
      }
    }

    let writePipe = Pipe()
    self.writePipe = writePipe
    pipeWriteHandle = writePipe.fileHandleForWriting

    let readHandle = writePipe.fileHandleForReading
    dup2(readHandle.fileDescriptor, STDIN_FILENO)

    let handle = engineHandle
    engineTask = Task.detached(priority: .userInitiated) {
      ChessKitInitializeEngine(handle.pointer)
    }
  }

  /// Closes the communication channel with the engine.
  func stop() {
    pipeReadHandle?.closeFile()
    pipeWriteHandle?.closeFile()
    readPipe = nil
    writePipe = nil
    pipeReadHandle = nil
    pipeWriteHandle = nil

    if let observer = stdoutObserver {
      notificationCenter.removeObserver(observer.value)
      stdoutObserver = nil
    }

    engineTask?.cancel()
    engineTask = nil
  }

  /// Sends a command to the engine.
  func sendCommand(_ command: String) {
    guard let pipeWriteHandle else { return }
    guard var data = command.data(using: .utf8) else { return }
    data.append(0x0a)

    data.withUnsafeBytes { buffer in
      guard let pointer = buffer.baseAddress else { return }
      _ = Darwin.write(pipeWriteHandle.fileDescriptor, pointer, buffer.count)
    }
  }

  // MARK: - Life Cycle

  init(engineType: EngineType) {
    switch engineType {
    case .stockfish:
      engineHandle = EngineHandle(pointer: ChessKitCreateStockfishEngine())
    case .lc0:
      engineHandle = EngineHandle(pointer: ChessKitCreateLc0Engine())
    }
  }

  deinit {
    if let observer = stdoutObserver {
      notificationCenter.removeObserver(observer.value)
    }

    ChessKitDeinitializeEngine(engineHandle.pointer)
    ChessKitDestroyEngine(engineHandle.pointer)
  }

  // MARK: - Private

  private let engineHandle: EngineHandle
  private let notificationCenter = NotificationCenter.default

  private var responseHandler: ResponseHandler?
  private var readPipe: Pipe?
  private var writePipe: Pipe?
  private var pipeReadHandle: FileHandle?
  private var pipeWriteHandle: FileHandle?
  private var stdoutObserver: ObserverToken?
  private var engineTask: Task<Void, Never>?
  private var bufferString: String = ""

  private func handleStdout(_ data: Data) async {
    if let handle = pipeReadHandle {
      await MainActor.run {
        handle.readInBackgroundAndNotify()
      }
    }

    guard
      !data.isEmpty,
      let output = String(data: data, encoding: .utf8)
    else { return }
    bufferString.append(output)
    let responses = bufferString.split(separator: "\n", omittingEmptySubsequences: false)
    for response in responses {
      responseHandler?(String(response))
    }
    bufferString = String(responses.last ?? "")
  }
}
