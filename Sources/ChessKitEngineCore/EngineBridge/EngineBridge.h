#ifndef EngineBridge_h
#define EngineBridge_h

#ifdef __cplusplus
extern "C" {
#endif

/// Creates a new Stockfish engine instance.
void * _Nonnull ChessKitCreateStockfishEngine(void);

/// Creates a new Lc0 engine instance.
void * _Nonnull ChessKitCreateLc0Engine(void);

/// Releases the provided engine instance.
void ChessKitDestroyEngine(void * _Nullable engine);

/// Initializes the provided engine instance.
void ChessKitInitializeEngine(void * _Nullable engine);

/// Deinitializes the provided engine instance.
void ChessKitDeinitializeEngine(void * _Nullable engine);

#ifdef __cplusplus
}
#endif

#endif /* EngineBridge_h */
