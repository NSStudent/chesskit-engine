//
//  EngineMessenger.swift
//  ChessKitEngine
//

import ChessKitEngineCore
import Darwin
import Foundation

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
      stdoutObserver = notificationCenter.addObserver(
        forName: FileHandle.readCompletionNotification,
        object: pipeReadHandle,
        queue: nil
      ) { [weak self] notification in
        Task {
          await self?.handleStdout(notification)
        }
      }

      await MainActor.run {
        pipeReadHandle.readInBackgroundAndNotify()
      }
    }

    let writePipe = Pipe()
    self.writePipe = writePipe
    pipeWriteHandle = writePipe.fileHandleForWriting

    let readHandle = writePipe.fileHandleForReading
    dup2(readHandle.fileDescriptor, STDIN_FILENO)

    engineTask = Task.detached(priority: .userInitiated) { [enginePointer] in
      ChessKitInitializeEngine(enginePointer)
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
      notificationCenter.removeObserver(observer)
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
      enginePointer = ChessKitCreateStockfishEngine()
    case .lc0:
      enginePointer = ChessKitCreateLc0Engine()
    }
  }

  deinit {
    if let observer = stdoutObserver {
      notificationCenter.removeObserver(observer)
    }

    ChessKitDeinitializeEngine(enginePointer)
    ChessKitDestroyEngine(enginePointer)
  }

  // MARK: - Private

  private let enginePointer: UnsafeMutableRawPointer
  private let notificationCenter = NotificationCenter.default

  private var responseHandler: ResponseHandler?
  private var readPipe: Pipe?
  private var writePipe: Pipe?
  private var pipeReadHandle: FileHandle?
  private var pipeWriteHandle: FileHandle?
  private var stdoutObserver: NSObjectProtocol?
  private var engineTask: Task<Void, Never>?

  private func handleStdout(_ notification: Notification) async {
    if let handle = pipeReadHandle {
      await MainActor.run {
        handle.readInBackgroundAndNotify()
      }
    }

    guard
      let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data,
      !data.isEmpty,
      let output = String(data: data, encoding: .utf8)
    else { return }

    let responses = output.split(separator: "\n", omittingEmptySubsequences: false)
    for response in responses {
      responseHandler?(String(response))
    }
  }
}
