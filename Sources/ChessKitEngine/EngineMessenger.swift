//
//  EngineMessenger.swift
//  ChessKitEngine
//

import ChessKitEngineCore
import Darwin
import Foundation

private struct EngineHandle: @unchecked Sendable {
  let pointer: UnsafeMutableRawPointer
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

    startReadLoop()

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
    readTask?.cancel()
    readTask = nil

    try? pipeReadHandle?.close()
    try? pipeWriteHandle?.close()
    readPipe = nil
    writePipe = nil
    pipeReadHandle = nil
    pipeWriteHandle = nil

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
    ChessKitDeinitializeEngine(engineHandle.pointer)
    ChessKitDestroyEngine(engineHandle.pointer)
  }

  // MARK: - Private

  private let engineHandle: EngineHandle

  private var responseHandler: ResponseHandler?
  private var readPipe: Pipe?
  private var writePipe: Pipe?
  private var pipeReadHandle: FileHandle?
  private var pipeWriteHandle: FileHandle?
  private var engineTask: Task<Void, Never>?
  private var readTask: Task<Void, Never>?

  private func startReadLoop() {
    guard let pipeReadHandle else { return }

    readTask = Task.detached { [weak self] in
      guard let self else { return }
      await self.consumeOutput(from: pipeReadHandle)
    }
  }

  private func consumeOutput(from handle: FileHandle) async {
    var buffer = Data()
    do {
      for try await byte in handle.bytes {
        buffer.append(byte)

        if byte == UInt8(ascii: "\n") {
          await emitBuffer(&buffer)
        }
      }

      // Flush any remaining data that wasn't newline-terminated.
      if !buffer.isEmpty {
        await emitBuffer(&buffer)
      }
    } catch is CancellationError {
      return
    } catch {
      await emitBuffer(&buffer)
    }
  }

  private func emitBuffer(_ buffer: inout Data) async {
    guard !buffer.isEmpty else { return }
    defer { buffer.removeAll(keepingCapacity: true) }

    guard let output = String(data: buffer, encoding: .utf8) else { return }
    let responses = output.split(separator: "\n", omittingEmptySubsequences: false)
    for response in responses {
      responseHandler?(String(response))
    }
  }
}
