# scheme14 — scheme13 の複製。開発環境は Windows（w64devkit / MinGW）。
#
#     make -C scheme14
#     make -f scheme14/Makefile
#
# ソースは scheme14.cpp、実行ファイルは scheme14.exe。
# ツールチェインはリポジトリ直下の Makefile（Windows）と同じ:
#   g++、同梱の Boehm GC、C:/boost_1_91_0。
# GC のランタイム DLL は実行ファイルの隣に置く。ローダは .exe の隣を
# 最初に見る（決定162）。ルートには置かない。ルートのコピーは
# scheme12 / scheme13 用である。

HERE := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ROOT := $(patsubst %/,%,$(dir $(HERE)))

CXX      = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2 -Wno-unused-function

GC_INCLUDE    = -I$(ROOT)/gc-8.2.12/include
BOOST_INCLUDE = -IC:/boost_1_91_0
GC_LIB        = -L$(ROOT)/gc-8.2.12/.libs -lgc -lgccpp

GC_DLL_DIR      = $(ROOT)/gc-8.2.12/.libs
GC_RUNTIME_DLLS = libgc-1.dll libgccpp-1.dll

TARGET = $(HERE)/scheme14.exe
SOURCE = $(HERE)/scheme14.cpp

.PHONY: all clean selftest compare test sicp bench help

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) $(GC_INCLUDE) $(BOOST_INCLUDE) -o $@ $< $(GC_LIB)
	@for dll in $(GC_RUNTIME_DLLS); do cp -f "$(GC_DLL_DIR)/$$dll" "$(HERE)/"; done

# 凍結仕様（dev_memo.md §2）との突き合わせ。エラー本文と位置もここで見る。
selftest: $(TARGET)
	@"$(TARGET)" --selftest

# 構文展開が scheme12 と等価かを突き合わせる。scheme12_debug のビルドが要る
# （リポジトリのルートで make scheme12）。
compare: $(TARGET)
	@cd "$(ROOT)" && "$(HERE)/tests/compare_expand.sh" "$(TARGET)"

# 既存 .scm 資産との互換性回帰（受け入れ基準そのもの）。
test: $(TARGET)
	@cd "$(ROOT)" && "$(HERE)/tests/run_golden.sh" "$(TARGET)"

sicp: $(TARGET)
	@cd "$(ROOT)" && "$(HERE)/sicp/run_sicp.sh" "$(TARGET)"

# 呼び出し性能のベンチ。time は w64devkit の sh にある。
bench: $(TARGET)
	@cd "$(ROOT)" && printf '(define (loop i acc) (if (= i 0) acc (loop (- i 1) (+ acc 1))))\n(display (loop 1000000 0))\n(newline)\n' > "$(HERE)/.bench.scm"
	@cd "$(ROOT)" && time "$(TARGET)" --load "$(HERE)/.bench.scm"
	@rm -f "$(HERE)/.bench.scm"

clean:
	rm -f "$(TARGET)" "$(HERE)/scheme13.exe" "$(HERE)/scheme13" "$(HERE)/.bench.scm" \
	      "$(HERE)/libgc-1.dll" "$(HERE)/libgccpp-1.dll"

help:
	@echo "scheme14 targets (Windows / w64devkit):"
	@echo "  all      - ビルド（scheme14.exe と GC の DLL）"
	@echo "  selftest - 凍結仕様との突き合わせ（C++ 単体の回帰）"
	@echo "  compare  - 構文展開が scheme12 と等価かを突き合わせる"
	@echo "  test     - 互換性回帰 + エラーの包み + REPL の筋道（受け入れ基準）"
	@echo "  sicp     - SICP を教材にした回帰"
	@echo "  bench    - 呼び出し性能のベンチ"
	@echo "  clean    - 生成物を削除"
