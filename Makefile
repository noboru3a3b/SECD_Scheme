# Makefile for scheme13 with Boost bignum support
# scheme13 is the current implementation. `make scheme12` still builds the
# earlier one, which is kept on purpose as the previous version.
CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -Wno-unused-function
GC_INCLUDE = -Igc-8.2.12/include
BOOST_INCLUDE = -IC:/boost_1_91_0
GC_LIB = -Lgc-8.2.12/.libs -lgc -lgccpp

GC_DLL_DIR = gc-8.2.12/.libs
GC_RUNTIME_DLLS = libgc-1.dll libgccpp-1.dll

TARGET = scheme13/scheme13
TARGET_DIR = scheme13
SOURCE = scheme13/scheme13.cpp

# The earlier implementation. This is the design scheme13 was rewritten away
# from; it is kept as a record, not maintained.
LEGACY_TARGET = scheme12_debug
LEGACY_SOURCE = scheme12_bignum_boost_debug.cpp

.PHONY: all clean test scheme12 help

all: $(TARGET)

# The GC runtime DLLs go NEXT TO THE EXECUTABLE. On Windows the loader looks
# in the .exe's own directory first; the current directory is consulted much
# later (and not at all under some launch modes). A copy in the repository root
# only works while the shell happens to sit there, so `cd scheme13` followed by
# `.\scheme13.exe` used to die before main() with STATUS_DLL_NOT_FOUND --
# no message, the prompt just comes back. Keep the root copy as well: that is
# where scheme12_debug is built.
$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $@ $< $(GC_LIB)
	@for dll in $(GC_RUNTIME_DLLS); do cp -f $(GC_DLL_DIR)/$$dll $(TARGET_DIR)/; cp -f $(GC_DLL_DIR)/$$dll .; done

scheme12: $(LEGACY_TARGET)

$(LEGACY_TARGET): $(LEGACY_SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $@ $< $(GC_LIB)
	@for dll in $(GC_RUNTIME_DLLS); do cp -f $(GC_DLL_DIR)/$$dll .; done

clean:
	rm -f $(TARGET) $(TARGET).exe $(LEGACY_TARGET) $(LEGACY_TARGET).exe $(GC_RUNTIME_DLLS) $(addprefix $(TARGET_DIR)/,$(GC_RUNTIME_DLLS))

test: $(TARGET)
	@echo "Testing basic functionality..."
	@echo "(+ 1 2 3)" | ./$(TARGET) || echo "Test requires interactive mode"

# ヘルプターゲット
help:
	@echo "Available targets:"
	@echo "  all      - Build scheme13 (current implementation)"
	@echo "  scheme12 - Build scheme12_debug (earlier version, kept as a record)"
	@echo "  clean    - Remove built files"
	@echo "  test     - Build and run a basic smoke test"
	@echo "  help     - Show this help"
	@echo ""
	@echo "Full regression suite: make -C scheme13 test"
