//
//  EngineMessenger.swift
//  ChessKitEngine
//

import ChessKitEngineCore
import Darwin
import Foundation

/// Messenger that communicates with the configured chess engine.
final class EngineMessenger: @unchecked Sendable {

  // MARK: - Public API

  /// Called whenever a response is received from the engine.
  var responseHandler: ((String) -> Void)?

  /// Initializes the messenger with the chosen engine type.
  init(engineType: EngineType) {
    switch engineType {
    case .stockfish:
      enginePointer = ChessKitCreateStockfishEngine()
    case .lc0:
      enginePointer = ChessKitCreateLc0Engine()
    }
  }

  deinit {
    if let stdoutObserver {
      notificationCenter.removeObserver(stdoutObserver)
      self.stdoutObserver = nil
    }
    ChessKitDeinitializeEngine(enginePointer)
    ChessKitDestroyEngine(enginePointer)
  }

  /// Opens the communication channel with the engine.
  func start() {
    lock.lock()
    defer { lock.unlock() }

    guard readPipe == nil, writePipe == nil else { return }

    readPipe = Pipe()
    pipeReadHandle = readPipe?.fileHandleForReading

    if let writeHandle = readPipe?.fileHandleForWriting {
      dup2(writeHandle.fileDescriptor, STDOUT_FILENO)
    }

    if let pipeReadHandle {
      stdoutObserver = notificationCenter.addObserver(
        forName: FileHandle.readCompletionNotification,
        object: pipeReadHandle,
        queue: nil
      ) { [weak self] notification in
        self?.handleStdout(notification)
      }

      DispatchQueue.main.async {
        pipeReadHandle.readInBackgroundAndNotify()
      }
    }

    writePipe = Pipe()
    pipeWriteHandle = writePipe?.fileHandleForWriting

    if let readHandle = writePipe?.fileHandleForReading {
      dup2(readHandle.fileDescriptor, STDIN_FILENO)
    }

    responseQueue.async { [weak self] in
      guard let enginePointer = self?.enginePointer else { return }
      ChessKitInitializeEngine(enginePointer)
    }
  }

  /// Closes the communication channel with the engine.
  func stop() {
    lock.lock()
    defer { lock.unlock() }

    pipeReadHandle?.closeFile()
    pipeWriteHandle?.closeFile()
    readPipe = nil
    writePipe = nil
    pipeReadHandle = nil
    pipeWriteHandle = nil

    if let stdoutObserver {
      notificationCenter.removeObserver(stdoutObserver)
      self.stdoutObserver = nil
    }
  }

  /// Sends a command to the engine.
  func sendCommand(_ command: String) {
    responseQueue.sync {
      guard let pipeWriteHandle else { return }
      guard var data = command.data(using: .utf8) else { return }
      data.append(0x0a)

      data.withUnsafeBytes { buffer in
        guard let pointer = buffer.baseAddress else { return }
        _ = Darwin.write(pipeWriteHandle.fileDescriptor, pointer, buffer.count)
      }
    }
  }

  // MARK: - Private

  private let lock = NSLock()
  private let notificationCenter = NotificationCenter.default
  private let responseQueue = DispatchQueue(
    label: "ck-engine-response-queue",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private let enginePointer: UnsafeMutableRawPointer

  private var readPipe: Pipe?
  private var writePipe: Pipe?
  private var pipeReadHandle: FileHandle?
  private var pipeWriteHandle: FileHandle?
  private var stdoutObserver: NSObjectProtocol?

  private func handleStdout(_ notification: Notification) {
    pipeReadHandle?.readInBackgroundAndNotify()

    guard
      let data = notification.userInfo?[NSFileHandleNotificationDataItem] as? Data,
      let output = String(data: data, encoding: .utf8)
    else { return }

    let responses = output.split(separator: "\n", omittingEmptySubsequences: false)
    responses.forEach { response in
      responseHandler?(String(response))
    }
  }
}
