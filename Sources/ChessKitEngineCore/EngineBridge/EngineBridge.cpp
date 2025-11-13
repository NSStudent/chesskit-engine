#include "EngineBridge.h"

#include "../Engines/AvailableEngines.h"

namespace {

inline Engine * _Nullable EngineFromPointer(void * _Nullable engine) {
  return static_cast<Engine *>(engine);
}

}

void * _Nonnull ChessKitCreateStockfishEngine(void) {
  return static_cast<void *>(new StockfishEngine());
}

void * _Nonnull ChessKitCreateLc0Engine(void) {
  return static_cast<void *>(new Lc0Engine());
}

void ChessKitDestroyEngine(void * _Nullable engine) {
  delete EngineFromPointer(engine);
}

void ChessKitInitializeEngine(void * _Nullable engine) {
  auto *instance = EngineFromPointer(engine);
  if (instance != nullptr) {
    instance->initialize();
  }
}

void ChessKitDeinitializeEngine(void * _Nullable engine) {
  auto *instance = EngineFromPointer(engine);
  if (instance != nullptr) {
    instance->deinitialize();
  }
}
