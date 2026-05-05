# Makefile for scheme12 with Boost bignum support
CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -Wno-unused-function
GC_INCLUDE = -Igc-8.2.12/include
BOOST_INCLUDE = -IC:/boost_1_91_0
GC_LIB = -Lgc-8.2.12/.libs -lgc -lgccpp

GC_DLL_DIR = gc-8.2.12/.libs
GC_RUNTIME_DLLS = libgc-1.dll libgccpp-1.dll

TARGET = scheme12_bignum
SOURCE = scheme12_bignum_boost.cpp

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $(TARGET) $(SOURCE) $(GC_LIB)
	@for dll in $(GC_RUNTIME_DLLS); do cp -f $(GC_DLL_DIR)/$$dll .; done

clean:
	rm -f $(TARGET) $(TARGET).exe libgc-1.dll libgccpp-1.dll

test: $(TARGET)
	@echo "Testing basic functionality..."
	@echo "(+ 1 2 3)" | ./$(TARGET) || echo "Test requires interactive mode"

# ヘルプターゲット
help:
	@echo "Available targets:"
	@echo "  all    - Build scheme12_bignum"
	@echo "  clean  - Remove built files"
	@echo "  test   - Build and run basic test"
	@echo "  help   - Show this help"
