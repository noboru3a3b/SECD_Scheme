# Unified Makefile for scheme12 with Boost bignum support
# Supports: Windows (cmd.exe), Linux, and FreeBSD

# Platform detection
UNAME_S := $(shell uname -s)
OS := $(OS)

# Determine platform and set variables accordingly
ifeq ($(OS),Windows_NT)
    PLATFORM := WINDOWS
    CXX := g++
    CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -Wno-unused-function
    GC_INCLUDE := -Igc-8.2.12/include
    BOOST_INCLUDE := -IC:/boost_1_91_0
    GC_LIB := -Lgc-8.2.12/.libs -lgc -lgccpp
    GC_DLL_DIR := gc-8.2.12/.libs
    GC_RUNTIME_DLLS := libgc-1.dll libgccpp-1.dll
    TARGET := scheme12_bignum.exe
    RM := del /Q
    COPY := copy /Y
    PATH_SEP := \
else ifeq ($(UNAME_S),Linux)
    PLATFORM := LINUX
    CXX := clang++
    CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -Wno-unused-function
    GC_INCLUDE := -I/usr/local/include
    BOOST_INCLUDE := -I/usr/include/boost
    GC_LIB := -L/usr/local/lib -lgc -lgccpp
    TARGET := scheme12_bignum
    RM := rm -f
    COPY := cp -f
    PATH_SEP := /
else ifeq ($(UNAME_S),FreeBSD)
    PLATFORM := FREEBSD
    CXX := clang++
    CXXFLAGS := -std=c++17 -Wall -Wextra -O2 -Wno-unused-function
    GC_INCLUDE := -I/usr/local/include
    BOOST_INCLUDE := -I/usr/local/include/boost
    GC_LIB := -L/usr/local/lib -lgc -lgccpp
    TARGET := scheme12_bignum
    RM := rm -f
    COPY := cp -f
    PATH_SEP := /
else
    $(error Unsupported platform: $(UNAME_S))
endif

SOURCE := scheme12_bignum_boost.cpp

.PHONY: all clean test help info

all: info $(TARGET)

info:
	@echo Platform detected: $(PLATFORM)
	@echo Compiler: $(CXX)

$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $(TARGET) $(SOURCE) $(GC_LIB)
ifeq ($(PLATFORM),WINDOWS)
	@echo Copying DLL files...
	@for %F in ($(GC_RUNTIME_DLLS)) do @$(COPY) "$(GC_DLL_DIR)\%F" . > nul 2>&1 || echo Warning: Could not copy %F
else
	@echo Build complete for $(PLATFORM)
endif

clean:
ifeq ($(PLATFORM),WINDOWS)
	$(RM) $(TARGET) $(GC_RUNTIME_DLLS) 2>nul || echo No files to remove
else
	$(RM) $(TARGET) $(GC_RUNTIME_DLLS) 2>/dev/null || echo No files to remove
endif

test: $(TARGET)
	@echo Testing basic functionality...
	@echo (+ 1 2 3) | ./$(TARGET) || echo Test requires interactive mode

help:
	@echo Available targets:
	@echo   all    - Build scheme12_bignum
	@echo   clean  - Remove built files
	@echo   test   - Build and run basic test
	@echo   info   - Show platform information
	@echo   help   - Show this help
