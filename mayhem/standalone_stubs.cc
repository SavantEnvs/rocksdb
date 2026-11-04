// The standalone reproducers link no libFuzzer runtime, but the libprotobuf-mutator custom-mutator
// entry points the proto harnesses define still reference LLVMFuzzerMutate. Never called standalone.
#include <cstddef>
#include <cstdint>
extern "C" size_t LLVMFuzzerMutate(uint8_t*, size_t size, size_t) { return size; }
