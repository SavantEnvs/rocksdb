// Leak detection is not the bug class this fleet fuzzes for; ASan and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }
