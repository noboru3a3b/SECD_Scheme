# scheme13 — SECD 仮想マシン方式 Scheme 処理系
#
# リポジトリのルートからでも scheme13/ からでも叩ける:
#     make -f scheme13/Makefile
#     make -C scheme13
#
# 注意: 処理系は起動時に cwd から system_lib.scm を読むため、
#       実行と test は必ずリポジトリのルートから行うこと。

# このMakefile自身の位置。呼び出し元のディレクトリに依存しないようにする。
HERE  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ROOT  := $(patsubst %/,%,$(dir $(HERE)))

CXX      = clang++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -Wno-unused-function

GC_INCLUDE    = -I/usr/local/include
BOOST_INCLUDE = -I/usr/include
GC_LIB        = -L/usr/local/lib -lgc -lgccpp

TARGET = $(HERE)/scheme13
SOURCE = $(HERE)/scheme13.cpp

.PHONY: all clean test bench help

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $@ $< $(GC_LIB)

# 既存 .scm 資産との互換性回帰（受け入れ基準そのもの）
test: $(TARGET)
	@cd $(ROOT) && $(HERE)/tests/run_golden.sh $(TARGET)

# 呼び出し性能のベンチ。scheme12 は約3.4秒（100万回）
bench: $(TARGET)
	@cd $(ROOT) && printf '(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1))))\n(display (loop 1000000 0))\n(newline)\n' > $(HERE)/.bench.scm
	@cd $(ROOT) && time $(TARGET) --load $(HERE)/.bench.scm
	@rm -f $(HERE)/.bench.scm

clean:
	rm -f $(TARGET) $(HERE)/.bench.scm

help:
	@echo "scheme13 targets:"
	@echo "  all    - ビルド"
	@echo "  test   - 既存 .scm 資産との互換性回帰（ゴールデン比較）"
	@echo "  bench  - 呼び出し性能のベンチ（scheme12 は約3.4秒）"
	@echo "  clean  - 生成物を削除"
