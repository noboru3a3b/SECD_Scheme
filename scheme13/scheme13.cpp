// scheme13.cpp — SECD 仮想マシン方式 Scheme 処理系
//
// scheme12_bignum_boost_debug.cpp の書き直し。設計判断とその理由は
// すべて scheme13/dev_memo.md にある。**このファイルを触る前に必ず読むこと。**
//
// セクション構造は dev_memo.md §3 に固定されている。新しいコードを
// 「とりあえず近くに」置かない。該当セクションがなければセクションごと作る。
//
//   1. 依存と GC 設定
//   2. ソース位置とエラー
//   3. 値モデル
//   4. 表示
//   5. リーダ
//   6. 構文検査        （未着手）
//   7. 構文展開        （未着手）
//   8. コンパイラ      （未着手）
//   9. 命令セット      （未着手）
//  10. VM              （未着手）
//  11. プリミティブ    （未着手）
//  12. 起動            （暫定：自己テストのみ）

// ===========================================================================
// セクション 1. 依存と GC 設定
// ===========================================================================

#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <charconv>
#include <climits>
#include <optional>
#include <random>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// char-ready? が「いま読んでも待たされないか」を見るためだけに使う
// （10日目の決定50）。libc の一部であって新しい依存ではない。POSIX 以外
// （root の Makefile が想定する MinGW）には対応する術がないので、
// そちらでは常に「読める」と答える。
#if !defined(_WIN32)
#include <poll.h>
#endif

#define GC_NO_INLINE_STD_NEW

#if __has_include(<gc/gc.h>)
#include <gc/gc.h>
#include <gc/gc_cpp.h>
#include <gc/gc_allocator.h>
#elif __has_include(<gc.h>)
#include <gc.h>
#include <gc_cpp.h>
#include <gc_allocator.h>
#elif __has_include("gc-8.2.12/include/gc.h")
#include "gc-8.2.12/include/gc.h"
#include "gc-8.2.12/include/gc_cpp.h"
#include "gc-8.2.12/include/gc_allocator.h"
#else
#error "Boehm GC headers not found. Install bdwgc or add include path."
#endif

// cpp_int の limb 型（64bit 環境では unsigned long long）はポインタを含まない。
// gc_allocator.h は unsigned long までしか ptr-free 宣言していないため、
// ここで追加宣言して limb 配列を GC_MALLOC_ATOMIC で確保させる。
// （GC のスキャン対象から外し、数値のビット列がポインタと誤認されてゴミを
//   保持する保守的 GC の偽 retention も同時に防ぐ。dev_memo.md §1.6-4）
GC_DECLARE_PTRFREE(unsigned long long);

#if __has_include(<boost/multiprecision/cpp_int.hpp>)
#include <boost/multiprecision/cpp_int.hpp>
#else
#error "Boost.Multiprecision not found. scheme13 requires cpp_int."
#endif

// GC オブジェクトが持つ文字列は必ずこれ。std::string を持たせると、
// gc 継承クラスのデストラクタが呼ばれないために GC_MALLOC_UNCOLLECTABLE
// から確保されたバッファが永久に解放されない。（dev_memo.md §1.6-2）
using GcString = std::basic_string<char, std::char_traits<char>, gc_allocator<char> >;

// GcString と std::string / string_view の相互変換。
// 多重定義にすると "abc" のようなリテラルで曖昧になるので string_view 一本にする
// （std::string も GcString も string_view へ暗黙に変換できる）。
static inline std::string to_std(const GcString& s) { return std::string(s.data(), s.size()); }
static inline GcString    to_gc(std::string_view s) { return GcString(s.data(), s.size()); }
static inline std::string_view view_of(const GcString& s) {
    return std::string_view(s.data(), s.size());
}

// limb 配列は Boehm GC 管理下に置く。gc 継承クラスはデストラクタが呼ばれない
// ため、既定の std::allocator（libgccpp により GC_MALLOC_UNCOLLECTABLE へ
// 差し替わる）だと limb 配列が回収されずルート集合に残り続けてしまう。
using BigInt = boost::multiprecision::number<
    boost::multiprecision::cpp_int_backend<0, 0,
        boost::multiprecision::signed_magnitude,
        boost::multiprecision::unchecked,
        gc_allocator<unsigned long long> > >;

// GC オブジェクトが持つコンテナは gc_allocator、GC 管理外のルート（グローバル
// 表など）は traceable_allocator。（dev_memo.md §1.6-3）
template <class T> using GcVec = std::vector<T, gc_allocator<T> >;
template <class T> using RootVec = std::vector<T, traceable_allocator<T> >;

// ===========================================================================
// セクション 2. ソース位置とエラー
// ===========================================================================
//
// 位置の持たせ方（dev_memo.md §9 の保留事項に対する決定）:
//
//   オブジェクトのヘッダに直接埋める。副表（Pair* -> SourcePos の
//   unordered_map）は採らない。理由:
//     - 副表はキーが強参照になるので、読み込んだペアが永久に回収されない
//     - ヘッダには tag(1バイト) の後ろにどのみち詰め物が入る。そこへ
//       col/file/line を置けば、ペア1個あたりの増分は 32-16=16 バイトで済む
//     - 参照がハッシュ引きでなくフィールド読み出しになる
//
//   位置を持つのはリーダが作ったオブジェクトだけ。実行時に cons した
//   ペアの位置は 0（＝位置なし）。シンボルはインターンされる（＝共有される）
//   ので位置を持てない。エラーは「最も内側の、位置を持つ囲みフォーム」を指す。

struct SourceFile {
    GcString name;  // 表示名（ファイルパス、あるいは "<stdin>" など）
    GcString text;  // 全文。エラー時にキャレット行を描くために保持する
    // 起動時ライブラリ（system_lib.scm / lib13.scm）か。エラーの位置を
    // 選ぶときに使う。**利用者はライブラリの中身を書いていない**ので、
    // ライブラリの行を指しても直しようがない（決定43）。
    bool is_library = false;
};

// 添字 0 は「位置なし」を表す番兵。ファイル id は 16bit なので上限 65535。
static RootVec<SourceFile> g_sources;

static void source_table_init() {
    if (g_sources.empty()) g_sources.push_back(SourceFile{to_gc("<unknown>"), GcString()});
}

// ソースを登録して id を返す。上限を超えたら 0（位置なし）を返す。
static std::uint16_t source_intern(const std::string& name, const std::string& text,
                                   bool is_library = false) {
    source_table_init();
    if (g_sources.size() >= 0xFFFFu) return 0;
    g_sources.push_back(SourceFile{to_gc(name), to_gc(text), is_library});
    return static_cast<std::uint16_t>(g_sources.size() - 1);
}


struct SourcePos {
    std::uint16_t file = 0;  // g_sources の添字。0 なら位置なし
    std::uint16_t col  = 0;  // 1 起点
    std::uint32_t line = 0;  // 1 起点
    bool known() const { return file != 0 && line != 0; }
};

// ソース中の 1 行を取り出す（line は 1 起点）。無ければ空。
static std::string_view source_line(const SourcePos& pos) {
    if (!pos.known() || pos.file >= g_sources.size()) return std::string_view();
    std::string_view text = view_of(g_sources[pos.file].text);
    std::size_t begin = 0;
    for (std::uint32_t n = 1; n < pos.line; ++n) {
        std::size_t nl = text.find('\n', begin);
        if (nl == std::string_view::npos) return std::string_view();
        begin = nl + 1;
    }
    std::size_t end = text.find('\n', begin);
    if (end == std::string_view::npos) end = text.size();
    // CRLF 対策
    if (end > begin && text[end - 1] == '\r') --end;
    return text.substr(begin, end - begin);
}

// 位置が起動時ライブラリ（system_lib.scm / lib13.scm）の中を指しているか。
static bool pos_in_library(const SourcePos& pos) {
    return pos.known() && pos.file < g_sources.size() && g_sources[pos.file].is_library;
}

static std::string source_name(const SourcePos& pos) {
    if (!pos.known() || pos.file >= g_sources.size()) return "<unknown>";
    return to_std(g_sources[pos.file].name);
}

// 「ファイル名:行:桁」。エラーの見出し（format_error）と、マクロ展開の実況
// （セクション8 の macro_print_step）が同じ書き方をするための1箇所。
static std::string pos_label(const SourcePos& pos) {
    return source_name(pos) + ":" + std::to_string(pos.line) + ":" +
           std::to_string(pos.col);
}

// 処理系が投げる例外はこれと SchemeExit の2つだけ。
// 位置は任意（known() が false なら位置なし）。
struct SchemeError : std::runtime_error {
    SourcePos pos;
    SchemeError(const std::string& msg, SourcePos p)
        : std::runtime_error(msg), pos(p) {}
};

// (exit) の終了要求（15日目の決定64）。誤りの報告ではないので SchemeError とは
// 別にし、**std::exception を継承しない**。継承すると try_load_library や
// REPL の catch (const std::exception&) に飲まれて、終了要求が「読めなかった」
// 「エラーだった」に化ける。main まで素通りさせ、そこで return する。
//
// std::exit を呼ばずに例外にするのは、main から普通に返れば stdio が
// 開いている出力ポートを流して閉じてくれるから（§1.6 の後始末）。
struct SchemeExit {
    int code;
};

[[noreturn]] static void error_at(const SourcePos& pos, const std::string& msg) {
    throw SchemeError(msg, pos);
}
[[noreturn]] static void error_here(const std::string& msg) {
    throw SchemeError(msg, SourcePos{});
}

// --- 本文の形（7日目の決定33） ---------------------------------------------
//
// 本文は **見出し1行 + 字下げした詳細行** に揃える。見出しは「誰が」「何を
// しくじったか」だけを言い、「何を期待していたか」「実際は何だったか」は
// 詳細行に置く。読む側が毎回同じ場所を見れば済むようにするのが目的。
//
//   car: wrong type of argument
//     expected: pair
//     given: 5
//
// 見出しの語彙は次の4つに限る。増やすときは §4.2 に足してから使うこと。
//   wrong type of argument / wrong number of arguments /
//   index out of range / bad syntax in <form>
//
// 詳細行の綴りはここに閉じ込める。文面を各所で組み立てさせない。

static std::string detail(std::string_view label, std::string_view text) {
    return "\n  " + std::string(label) + ": " + std::string(text);
}
static std::string expected_given(std::string_view expected, std::string_view given) {
    return detail("expected", expected) + detail("given", given);
}

// 処理系自身の不変条件が壊れた場合。**利用者の書いたプログラムの誤りではない。**
// VM のスタック不足や、検査済みのはずの型が違う、といったものはこちら。
// 利用者が自分の誤りと取り違えないよう、見出しで明示的に切り分ける。
[[noreturn]] static void internal_error(const SourcePos& pos, const std::string& what) {
    throw SchemeError("internal error: " + what +
                      detail("note", "this is a bug in scheme13 itself, "
                                     "not in the program being run"), pos);
}

// エラーの本文を組み立てる。呼び出し側が "Error: " などの前置きを付ける。
//
//   mylib.scm:42:8: bad syntax in define:
//     variable definition needs a value expression
//       (define x)
//               ^
//
// 位置が無いときはメッセージだけを返す。
static std::string format_error(const SchemeError& e) {
    if (!e.pos.known()) return e.what();

    std::string out;
    out += pos_label(e.pos);
    out += ": ";
    out += e.what();

    std::string_view line = source_line(e.pos);
    if (!line.empty()) {
        out += "\n    ";
        out.append(line.data(), line.size());
        out += "\n    ";
        // タブは桁がずれるので、キャレット行にもタブをそのまま置く
        for (std::uint16_t i = 1; i < e.pos.col && i <= line.size(); ++i)
            out += (line[i - 1] == '\t') ? '\t' : ' ';
        out += '^';
    }
    return out;
}

// ===========================================================================
// セクション 3. 値モデル
// ===========================================================================
//
// 値は `Object*`（= ValuePtr）ひとつで表す。scheme12 の
// `Value{std::variant<...>}` + 別確保の実体（Pair など）という二段構えを
// やめ、**タグ付きの基底クラス Object を各型が継承する**形にした。
//
//   - cons 1 個が 2 回の確保・56 バイトから、1 回の確保・32 バイトになる
//   - variant は最大要素（32バイトの文字列）に合わせて全 Value が太る。
//     継承なら型ごとに必要なだけ
//   - ヘッダの詰め物にソース位置を置ける（セクション2 の決定）
//
// さらに **小さい整数はポインタに埋め込む（即値 fixnum）**。最下位ビットが
// 1 なら整数、0 ならヒープ上のオブジェクト。`(+ acc 1)` のような算術が
// 1 回も確保しなくなる。保守的 GC との相性: 奇数のビット列はヒープ
// オブジェクトの誤保持（偽 retention）を起こしうるだけで、破壊は起きない。
//
// nullptr は値ではない。空リストは必ず g_nil（唯一のシングルトン）。

struct Object;
struct Code;    // セクション9
struct Env;     // セクション9（環境フレームの連結リスト）
using ValuePtr = Object*;
using CodePtr  = Code*;
using ValueVec = GcVec<ValuePtr>;

enum class Tag : std::uint8_t {
    Fixnum,       // ヘッダを持たない即値。tag_of() だけが返す
    Nil, Boolean, Bignum, Flonum, String, Symbol, Pair, Vector,
    Closure, Continuation, Primitive, Macro, SpecialForm, Port, Eof, Values
};

// ヘッダ 12 バイト（tag / src_col / src_file / src_line）。
// 位置を持つのはリーダが作ったオブジェクトだけ（セクション2 参照）。
struct Object : public gc {
    Tag           tag;
    std::uint16_t src_col  = 0;
    std::uint16_t src_file = 0;
    std::uint32_t src_line = 0;
    explicit Object(Tag t) : tag(t) {}
};

// --- 即値 fixnum -----------------------------------------------------------

static_assert((-2 >> 1) == -1, "算術右シフトを前提にしている");
static_assert(sizeof(void*) == sizeof(std::intptr_t), "");

static constexpr std::intptr_t FIXNUM_MAX = (INTPTR_MAX >> 1);
static constexpr std::intptr_t FIXNUM_MIN = -FIXNUM_MAX - 1;

static inline bool is_fixnum(ValuePtr v) {
    return (reinterpret_cast<std::uintptr_t>(v) & 1u) != 0;
}
static inline std::intptr_t fixnum_value(ValuePtr v) {
    return reinterpret_cast<std::intptr_t>(v) >> 1;
}
static inline ValuePtr make_fixnum(std::intptr_t n) {
    return reinterpret_cast<ValuePtr>((static_cast<std::uintptr_t>(n) << 1) | 1u);
}
static inline bool fits_fixnum(const BigInt& n) {
    return n >= BigInt(FIXNUM_MIN) && n <= BigInt(FIXNUM_MAX);
}

static inline Tag tag_of(ValuePtr v) {
    return is_fixnum(v) ? Tag::Fixnum : v->tag;
}
static inline bool has_tag(ValuePtr v, Tag t) {
    return !is_fixnum(v) && v->tag == t;
}

// --- 各型 ------------------------------------------------------------------

struct Pair : Object {
    ValuePtr car;
    ValuePtr cdr;
    Pair(ValuePtr a, ValuePtr d) : Object(Tag::Pair), car(a), cdr(d) {}
};

struct Str : Object {          // Scheme の文字列（可変）。文字型は存在しない
    GcString s;
    explicit Str(const GcString& v) : Object(Tag::String), s(v) {}
};

struct Symbol : Object {       // インターンされる。大小文字を保存する
    GcString name;
    explicit Symbol(const GcString& n) : Object(Tag::Symbol), name(n) {}
};

struct Vector : Object {
    ValueVec elems;
    Vector() : Object(Tag::Vector) {}
};

struct Bignum : Object {       // fixnum に収まらない整数だけがここに来る
    BigInt v;
    explicit Bignum(const BigInt& n) : Object(Tag::Bignum), v(n) {}
};

// 不正確な実数（18日目の決定81）。数は「正確な整数」と「不正確な実数」の
// 2階建てで、有理数と複素数は無い。
//
// **即値にはしない**（決定84）。64ビットの double は、最下位1ビットをタグに
// 使う即値方式に入らない。確保は make_flonum() ただ一つを通すこと。
struct Flonum : Object {
    double v;
    explicit Flonum(double d) : Object(Tag::Flonum), v(d) {}
};

// クロージャの「コンパイル時に決まる側」。lambda 1つにつき1個だけ作り、
// LDF は雛形と現在の環境を束ねるだけにする。scheme12 は LDF のたびに
// 仮引数名の配列を複製していた。
struct Template : public gc {
    GcVec<GcString>         params;
    std::optional<GcString> rest;
    CodePtr                 body = nullptr;
    GcString                name;   // 逆アセンブル表示用（define で付く）
};

struct Closure : Object {
    Template* tmpl;
    Env*      env;
    Closure(Template* t, Env* e) : Object(Tag::Closure), tmpl(t), env(e) {}
};

// ダンプの1段。呼び出し元の状態を丸ごと持つ（§4.4.2）。
// 継続がこれの配列を丸ごと持つので、値モデル側で定義しておく。
// 実際に積み下ろしするのはセクション10 の VM。
struct DumpEntry {
    CodePtr       c;
    std::uint32_t pc;
    Env*          env;
    std::uint32_t base;   // 呼び出し元のオペランドスタックの床
};

// 継続は機械の状態のスナップショット。S とダンプはコピーして持ち、
// 環境（Env*）は共有する（set! が捕捉をまたいで見えるのが正しい意味論）。
// (values a b ...) の結果。**1個のときは値そのもの**を返すので、この型が
// 現れるのは0個または2個以上のときだけ（13日目の決定58）。
struct Values : Object {
    ValueVec vals;
    Values() : Object(Tag::Values) {}
};

// dynamic-wind の1段。id は「同じ枠か」を見るための通し番号で、同じ
// before/after の組が入れ子で二度積まれても別物と分かるようにする（決定59）。
struct WindEntry {
    ValuePtr      before;
    ValuePtr      after;
    std::uint64_t id;
};

struct Continuation : Object {
    ValueVec          stack;
    GcVec<DumpEntry>  dump;
    GcVec<WindEntry>  winds;      // 捕捉した時点の dynamic-wind の入れ子（決定59）
    CodePtr           c    = nullptr;
    std::uint32_t     pc   = 0;
    Env*              env  = nullptr;
    std::uint32_t     base = 0;
    Continuation() : Object(Tag::Continuation) {}
};

// プリミティブは std::function ではなく素の関数ポインタ。
// (1) std::function はキャプチャを持つと ::operator new（libgccpp 経由で
//     GC_MALLOC_UNCOLLECTABLE）から確保し、gc 継承クラスのデストラクタは
//     呼ばれないので解放されない。(2) 引数を ValueVec に詰め替えず、VM の
//     スタック上の区間をそのまま (argv, argc) で渡せる（dev_memo.md §4.1）。
using PrimitiveFn = ValuePtr (*)(ValuePtr* argv, std::size_t argc);

struct Primitive : Object {
    GcString    name;
    PrimitiveFn fn;
    Primitive(const GcString& n, PrimitiveFn f) : Object(Tag::Primitive), name(n), fn(f) {}
};

struct Macro : Object {
    Closure* transformer;
    explicit Macro(Closure* t) : Object(Tag::Macro), transformer(t) {}
};

struct SpecialForm : Object {
    GcString name;
    explicit SpecialForm(const GcString& n) : Object(Tag::SpecialForm), name(n) {}
};

// gc_cleanup は使わない。Object が既に gc を継承しているので多重継承すると
// operator new が曖昧になる。ファイナライザは make_port() で明示登録する。
// 登録を忘れるとディスクリプタが枯渇する（scheme12 の実バグ。§1.6-1）ので、
// ポートを作る経路は make_port() ただ一つに限ること。
//
// 標準ポート（stdin / stdout）だけは FILE* を**所有しない**。所有しない
// ポートは close() が何もしない（10日目の決定46）。fclose(stdout) を一度でも
// 許すと、以後の出力がすべて黙って消えるため。
//
// 入力は has_peek / peek_ch の1文字先読みを持つ。peek-char と char-ready? が
// これを使う。**入力は必ず get_char / peek_char / unget_char を通すこと。**
// std::fgetc を直に呼ぶと先読みの1文字が消える。
struct Port : Object {
    std::FILE* fp;
    bool is_input;
    bool is_closed;
    bool owns_fp;        // 偽なら標準ポート。閉じないしファイナライザも付けない
    bool has_peek;       // 先読みの1文字を持っているか
    int  peek_ch;        // has_peek のときだけ意味を持つ。EOF もそのまま入る
    Port(std::FILE* f, bool input, bool owns)
        : Object(Tag::Port), fp(f), is_input(input), is_closed(false),
          owns_fp(owns), has_peek(false), peek_ch(EOF) {}
    void close() {
        if (!owns_fp) return;
        if (fp && !is_closed) { std::fclose(fp); is_closed = true; fp = nullptr; }
    }
    int get_char() {
        if (has_peek) { has_peek = false; return peek_ch; }
        return std::fgetc(fp);
    }
    int peek_char() {
        if (!has_peek) { peek_ch = std::fgetc(fp); has_peek = true; }
        return peek_ch;
    }
    void unget_char(int c) { peek_ch = c; has_peek = true; }
};

// --- シングルトン ----------------------------------------------------------

static ValuePtr g_nil   = nullptr;
static ValuePtr g_true  = nullptr;
static ValuePtr g_false = nullptr;
static ValuePtr g_eof   = nullptr;

// 標準ポート。(current-input-port) / (current-output-port) が返す値そのもの。
// display などの既定の出力先もここから取る（10日目の決定48）。
static ValuePtr g_stdin_port  = nullptr;
static ValuePtr g_stdout_port = nullptr;

// いま入っている dynamic-wind の入れ子。**動的エクステントは1本しかない**ので
// 大域に置く。継続はこれのコピーを持ち、起動時に差分だけ巻き戻す（決定59）。
static RootVec<WindEntry> g_winds;
static std::uint64_t      g_wind_next_id = 1;

// --- 構築 ------------------------------------------------------------------

static inline ValuePtr make_bool(bool b) { return b ? g_true : g_false; }

static ValuePtr make_int(const BigInt& n) {
    if (fits_fixnum(n)) return make_fixnum(static_cast<std::intptr_t>(n));
    return new Bignum(n);
}
static inline ValuePtr make_int(long long n) {
    if (n >= FIXNUM_MIN && n <= FIXNUM_MAX) return make_fixnum(static_cast<std::intptr_t>(n));
    return new Bignum(BigInt(n));
}
static ValuePtr make_int_from_text(const std::string& digits) {
    return make_int(BigInt(digits));
}

// 実数はポインタを1つも持たないので、**走査しないヒープから確保する**
// （18日目の決定84）。double のビット列を保守的 GC がポインタと誤解して
// 掴み続けるのを防ぐ。§1.6-4 の cpp_int の limb 配列と同じ趣旨。
//
// **結果が整数でも整数に落とさない**（決定85）。正確さは値の一部で、
// (* 2.0 3.0) は 6.0 であって 6 ではない。make_int が表現を1つに正規化するのと
// **向きが逆**なので、あちらの感覚でここを触らないこと。
static inline ValuePtr make_flonum(double d) { return new (PointerFreeGC) Flonum(d); }

static inline ValuePtr make_string(std::string_view s) { return new Str(to_gc(s)); }

// キーは Symbol 自身が持つバッファを指す string_view。名前を二重に持たずに済み、
// 検索のたびに GcString を作る必要もない。バッファは値（Symbol*）が生かす。
using SymbolTable = std::unordered_map<
    std::string_view, ValuePtr, std::hash<std::string_view>, std::equal_to<std::string_view>,
    traceable_allocator<std::pair<const std::string_view, ValuePtr> > >;
static SymbolTable g_symbols;

static ValuePtr make_symbol(std::string_view name) {
    auto it = g_symbols.find(name);
    if (it != g_symbols.end()) return it->second;
    Symbol* s = new Symbol(to_gc(name));
    g_symbols.emplace(view_of(s->name), s);
    return s;
}

static inline ValuePtr make_pair(ValuePtr a, ValuePtr d) { return new Pair(a, d); }

static ValuePtr make_vector(std::size_t n, ValuePtr init) {
    Vector* v = new Vector();
    v->elems.assign(n, init);
    return v;
}
static ValuePtr make_vector(const ValueVec& elems) {
    Vector* v = new Vector();
    v->elems = elems;
    return v;
}

static inline ValuePtr make_special_form(std::string_view n) {
    return new SpecialForm(to_gc(n));
}
static inline ValuePtr make_primitive(std::string_view n, PrimitiveFn fn) {
    return new Primitive(to_gc(n), fn);
}

static void port_finalizer(void* obj, void* /*client_data*/) {
    static_cast<Port*>(obj)->close();
}
static ValuePtr make_port(std::FILE* fp, bool is_input) {
    Port* p = new Port(fp, is_input, true);
    GC_REGISTER_FINALIZER_IGNORE_SELF(p, port_finalizer, nullptr, nullptr, nullptr);
    return p;
}
// 標準ポートは FILE* を所有しないので、閉じるファイナライザを付けない。
// 経路をここ一つに限るのは make_port と同じ理由（§1.6-1）。
static ValuePtr make_std_port(std::FILE* fp, bool is_input) {
    return new Port(fp, is_input, false);
}

// --- 述語 ------------------------------------------------------------------

static inline bool is_nil(ValuePtr v)     { return v == g_nil; }
static inline bool is_pair(ValuePtr v)    { return has_tag(v, Tag::Pair); }
static inline bool is_string(ValuePtr v)  { return has_tag(v, Tag::String); }
static inline bool is_vector(ValuePtr v)  { return has_tag(v, Tag::Vector); }
static inline bool is_symbol(ValuePtr v)  { return has_tag(v, Tag::Symbol); }
static inline bool is_flonum(ValuePtr v)  { return has_tag(v, Tag::Flonum); }
// 正確な整数（fixnum か Bignum）。**実数と区別したいところはこちらを使う**。
// number? が真でも整数とは限らない（18日目の決定86・92）。
static inline bool is_exact_int(ValuePtr v) { return is_fixnum(v) || has_tag(v, Tag::Bignum); }
static inline bool is_number(ValuePtr v)  { return is_exact_int(v) || is_flonum(v); }

// 偽なのは #f ただ一つ。nil も 0 も空文字列も真。（dev_memo.md §2）
static inline bool is_false(ValuePtr v) { return v == g_false; }
static inline bool is_true(ValuePtr v)  { return v != g_false; }

static bool is_symbol_named(ValuePtr v, std::string_view name) {
    return is_symbol(v) && view_of(static_cast<Symbol*>(v)->name) == name;
}

// --- アクセサ --------------------------------------------------------------
//
// **これらは処理系の内部用で、利用者のプログラムからは直に到達しない。**
// 利用者の値を検査するのは構文検査（セクション6）とプリミティブ（セクション11）の
// 仕事で、そこを素通りしてここに落ちたなら scheme13 側の検査漏れである。
// だから型が違ったときは internal_error にする。scheme12 は利用者の誤りと
// 見分けのつかない "expected pair" を返していて、どちらの問題か分からなかった。

static Pair* as_pair(ValuePtr v) {
    if (!is_pair(v)) internal_error(SourcePos{}, "as_pair on a non-pair");
    return static_cast<Pair*>(v);
}
static GcString& as_string(ValuePtr v) {
    if (!is_string(v)) internal_error(SourcePos{}, "as_string on a non-string");
    return static_cast<Str*>(v)->s;
}
static Vector* as_vector(ValuePtr v) {
    if (!is_vector(v)) internal_error(SourcePos{}, "as_vector on a non-vector");
    return static_cast<Vector*>(v);
}
static const GcString& as_symbol_name(ValuePtr v) {
    if (!is_symbol(v)) internal_error(SourcePos{}, "as_symbol_name on a non-symbol");
    return static_cast<Symbol*>(v)->name;
}
static BigInt as_bigint(ValuePtr v) {
    if (is_fixnum(v)) return BigInt(static_cast<long long>(fixnum_value(v)));
    if (has_tag(v, Tag::Bignum)) return static_cast<Bignum*>(v)->v;
    internal_error(SourcePos{}, "as_bigint on a non-integer");
}

static inline ValuePtr car(ValuePtr v) { return as_pair(v)->car; }
static inline ValuePtr cdr(ValuePtr v) { return as_pair(v)->cdr; }

// --- ソース位置の読み書き --------------------------------------------------

static inline SourcePos pos_of(ValuePtr v) {
    if (is_fixnum(v)) return SourcePos{};
    return SourcePos{v->src_file, v->src_col, v->src_line};
}
static inline void set_pos(ValuePtr v, const SourcePos& p) {
    if (is_fixnum(v)) return;   // 即値は位置を持てない
    v->src_file = p.file;
    v->src_col  = p.col;
    v->src_line = p.line;
}

// リストを辿って、位置を持つ最初のオブジェクトの位置を返す。
// エラー報告はこれで「一番近い、位置の分かるフォーム」を指す。
static SourcePos nearest_pos(ValuePtr v) {
    SourcePos p = pos_of(v);
    if (p.known()) return p;
    if (is_pair(v)) return pos_of(as_pair(v)->car);
    return SourcePos{};
}

// --- リストの補助（cdr 方向は必ずループ。dev_memo.md §4.3） ----------------

static ValuePtr list_from(const ValueVec& xs) {
    ValuePtr out = g_nil;
    for (std::size_t i = xs.size(); i > 0; --i) out = make_pair(xs[i - 1], out);
    return out;
}
static ValuePtr list_from(std::initializer_list<ValuePtr> xs) {
    ValuePtr out = g_nil;
    for (auto it = std::rbegin(xs); it != std::rend(xs); ++it) out = make_pair(*it, out);
    return out;
}

static void value_model_init() {
    g_nil   = new Object(Tag::Nil);
    g_true  = new Object(Tag::Boolean);
    g_false = new Object(Tag::Boolean);
    g_eof   = new Object(Tag::Eof);
    g_stdin_port  = make_std_port(stdin,  true);
    g_stdout_port = make_std_port(stdout, false);
}

// ===========================================================================
// セクション 4. 表示
// ===========================================================================
//
// 出力は dev_memo.md §2.1 の凍結仕様どおり。write と display の違いは
// **一番外側の値が文字列のときに引用符を付けるかどうかだけ**。リストの
// 要素にある文字列は display でも引用符つきで出る。
//
// 循環検出は「いま辿っている経路上のノードの集合」で行い、走査を終えたら
// 自分が入れた分を取り除く（バックトラック）。取り除かないと共有構造（DAG）を
// 循環と誤判定する。car 方向にも同じ集合を引き回す。（dev_memo.md §4.3）
// ここは実行のホットパスではないので、集合の確保コストは問題にしない。

using PathSet = std::unordered_set<const void*, std::hash<const void*>,
                                   std::equal_to<const void*>,
                                   gc_allocator<const void*> >;

// 実数の表示（18日目の決定90）。**読み戻すと同じ値になる最短形**を出す。
// std::to_chars の shortest round-trip に、Scheme の形へ寄せる後処理をかける:
//
//   to_chars   scheme13   直し方
//   1          1.0        '.' も 'e' も無ければ ".0" を足す（-0 → -0.0 も同じ規則）
//   1e+21      1e21       指数の '+' を落とす
//   1e-07      1e-7       指数の先頭の 0 を落とす
//
// 無限大と非数は to_chars に渡さず、R7RS の綴りで出す。
//
// **丸めて隠さない。** (+ 0.1 0.2) は 0.30000000000000004 と出る。§1.5 に
// 照らせば、見えている数がメモリにある数であることのほうが大事である。
// **number->string もこの関数を使う**（書式を2つ持たない）。
static std::string format_flonum(double d) {
    if (std::isnan(d)) return "+nan.0";
    if (std::isinf(d)) return (d > 0) ? "+inf.0" : "-inf.0";

    char buf[64];
    auto r = std::to_chars(buf, buf + sizeof buf, d);
    std::string s(buf, r.ptr);

    std::size_t e = s.find_first_of("eE");
    if (e == std::string::npos) {
        if (s.find('.') == std::string::npos) s += ".0";
        return s;
    }
    std::string mantissa = s.substr(0, e);
    std::string exponent = s.substr(e + 1);
    bool neg = false;
    if (!exponent.empty() && (exponent[0] == '+' || exponent[0] == '-')) {
        neg = (exponent[0] == '-');
        exponent.erase(0, 1);
    }
    while (exponent.size() > 1 && exponent[0] == '0') exponent.erase(0, 1);
    return mantissa + "e" + (neg ? "-" : "") + exponent;
}

static void write_value(std::string& out, ValuePtr v, PathSet& path);

static void write_list(std::string& out, ValuePtr ls, PathSet& path) {
    out += '(';
    bool first = true;
    GcVec<const void*> mine;   // この呼び出しで path に入れた分

    while (!is_nil(ls)) {
        if (!is_pair(ls)) {                  // ドット対の尻尾
            out += " . ";
            write_value(out, ls, path);
            break;
        }
        if (!path.insert(static_cast<const void*>(ls)).second) {
            out += " . #<circular>";
            break;
        }
        mine.push_back(static_cast<const void*>(ls));

        if (!first) out += ' ';
        first = false;
        write_value(out, as_pair(ls)->car, path);
        ls = as_pair(ls)->cdr;
    }
    out += ')';
    for (const void* p : mine) path.erase(p);
}

static void write_vector(std::string& out, Vector* vec, PathSet& path) {
    if (!path.insert(static_cast<const void*>(vec)).second) {
        out += "#<circular-vector>";
        return;
    }
    out += "#(";
    for (std::size_t i = 0; i < vec->elems.size(); ++i) {
        if (i > 0) out += ' ';
        write_value(out, vec->elems[i], path);
    }
    out += ')';
    path.erase(static_cast<const void*>(vec));
}

static void write_params(std::string& out, const Template* t) {
    out += '(';
    for (std::size_t i = 0; i < t->params.size(); ++i) {
        if (i > 0) out += ' ';
        out.append(t->params[i].data(), t->params[i].size());
    }
    if (t->rest) {
        if (!t->params.empty()) out += " . ";
        out.append(t->rest->data(), t->rest->size());
    }
    out += ')';
}

static void write_value(std::string& out, ValuePtr v, PathSet& path) {
    switch (tag_of(v)) {
        case Tag::Fixnum:
            out += std::to_string(static_cast<long long>(fixnum_value(v)));
            return;
        case Tag::Bignum:
            out += static_cast<Bignum*>(v)->v.str();
            return;
        case Tag::Flonum:
            out += format_flonum(static_cast<Flonum*>(v)->v);
            return;
        case Tag::Nil:
            out += "NIL";
            return;
        case Tag::Boolean:
            out += (v == g_true) ? "TRUE" : "FALSE";
            return;
        case Tag::String: {
            // write は文字列の中身をエスケープしない（凍結仕様）
            const GcString& s = static_cast<Str*>(v)->s;
            out += '"';
            out.append(s.data(), s.size());
            out += '"';
            return;
        }
        case Tag::Symbol: {
            const GcString& s = static_cast<Symbol*>(v)->name;
            out.append(s.data(), s.size());
            return;
        }
        case Tag::Pair:
            write_list(out, v, path);
            return;
        case Tag::Vector:
            write_vector(out, static_cast<Vector*>(v), path);
            return;
        case Tag::Closure:
            out += "#<closure:";
            write_params(out, static_cast<Closure*>(v)->tmpl);
            out += '>';
            return;
        case Tag::Values: {
            Values* mv = static_cast<Values*>(v);
            out += "#<values";
            for (ValuePtr x : mv->vals) { out += ' '; write_value(out, x, path); }
            out += '>';
            return;
        }
        case Tag::Continuation:
            out += "#<continuation>";
            return;
        case Tag::Primitive: {
            const GcString& n = static_cast<Primitive*>(v)->name;
            out += "(PRIMITIVE ";
            out.append(n.data(), n.size());
            out += ')';
            return;
        }
        case Tag::Macro:
            out += "(MACRO ";
            out += "#<closure:";
            write_params(out, static_cast<Macro*>(v)->transformer->tmpl);
            out += '>';
            out += ')';
            return;
        case Tag::SpecialForm: {
            const GcString& n = static_cast<SpecialForm*>(v)->name;
            out += "(SPECIAL-FORM ";
            out.append(n.data(), n.size());
            out += ')';
            return;
        }
        case Tag::Port: {
            Port* p = static_cast<Port*>(v);
            if (p->is_closed) out += "#<closed-port>";
            else out += p->is_input ? "#<input-port>" : "#<output-port>";
            return;
        }
        case Tag::Eof:
            out += "#<eof>";
            return;
    }
    out += "#<unknown>";
}

// write 表現。エラーメッセージや REPL の結果表示もこれを使う。
static std::string to_string(ValuePtr v) {
    std::string out;
    PathSet path;
    write_value(out, v, path);
    return out;
}

// display 表現。一番外側が文字列のときだけ引用符を外す。
static std::string to_display_string(ValuePtr v) {
    if (is_string(v)) return to_std(as_string(v));
    return to_string(v);
}

// ===========================================================================
// セクション 5. リーダ
// ===========================================================================
//
// 凍結仕様（dev_memo.md §2.5）:
//   - 角括弧 [ ] は区切り文字ではない。'[1 2] は [1 と 2] の 2 シンボル
//   - #t / #f と true / false / nil のリテラルを両方受け付ける
//   - ,@ は splice というシンボルに読まれる（unquote-splicing ではない）
//   - 文字列のエスケープは \n だけが特別。\t は 't'、\" は '"'、\\ は '\'
//   - 数値は「先頭が数字、または符号+2文字以上」かつ残りが全部数字のときだけ。
//     1a は数値でなくシンボル
//
// scheme12 から意図的に変えた点（dev_memo.md §6 に理由を記録した）:
//   - ドットは **単独のトークンのときだけ** ドット対の区切り。scheme12 は
//     リストの要素位置にある '.' を無条件にドットとみなしていたので、
//     '(...) が (quote ..) に読まれていた
//   - #t / #f も後ろが区切り文字のときだけ真偽値。scheme12 は #true を
//     TRUE と rest というシンボルに割っていた
//   - 閉じ括弧の余り、終端のない文字列、'. の位置違反をエラーにする
//     （scheme12 は ')' をシンボルとして読み、終端のない文字列を黙って通した）

static bool is_delimiter(char c) {
    return std::isspace(static_cast<unsigned char>(c)) ||
           c == '(' || c == ')' || c == '\'' || c == '`' ||
           c == ',' || c == '"' || c == ';';
}

// トークンを数に変える。**「数かどうか」の判定は自前でやる**（18日目の決定89）。
//
// std::from_chars に判定まで任せてはいけない。libstdc++ のそれは `inf` / `nan` /
// `infinity` を受け付けるので、任せるとシンボル `inf` が数に化ける（実測）。
// 受け付ける形は dev_memo.md §2.5 に固定してあり、**トークン全体が一致した
// ときだけ数**になる。外れたもの（`1/2` `1.2.3` `1e`）はシンボルのまま。
//
// **リーダと string->number の両方がこれを使う。** 数の文法を2つ持たない。
static bool parse_number(std::string_view tok, ValuePtr* out) {
    if (tok.empty()) return false;

    if (tok == "+inf.0" || tok == "-inf.0") {
        *out = make_flonum(tok[0] == '-' ? -INFINITY : INFINITY);
        return true;
    }
    if (tok == "+nan.0" || tok == "-nan.0") { *out = make_flonum(NAN); return true; }

    auto digit = [](char c) { return std::isdigit(static_cast<unsigned char>(c)) != 0; };

    std::size_t i = 0;
    if (tok[0] == '+' || tok[0] == '-') i = 1;

    std::size_t int_digits = 0, frac_digits = 0;
    while (i < tok.size() && digit(tok[i])) { ++i; ++int_digits; }

    bool real = false;
    if (i < tok.size() && tok[i] == '.') {
        real = true;
        ++i;
        while (i < tok.size() && digit(tok[i])) { ++i; ++frac_digits; }
    }
    if (int_digits == 0 && frac_digits == 0) return false;   // 数字が1つも無い（`.` `+` `-`）

    if (i < tok.size() && (tok[i] == 'e' || tok[i] == 'E')) {
        std::size_t j = i + 1;
        if (j < tok.size() && (tok[j] == '+' || tok[j] == '-')) ++j;
        std::size_t exp_digits = 0;
        while (j < tok.size() && digit(tok[j])) { ++j; ++exp_digits; }
        if (exp_digits == 0) return false;                   // `1e` はシンボル
        i = j;
        real = true;
    }
    if (i != tok.size()) return false;                       // 末尾が残ったらシンボル（`1.2.3`）

    // 整数。**先頭の '+' は落としてから渡す。** BigInt("+5") は Boost が
    // "Unexpected character encountered in input." を投げ、Scheme のエラーに
    // ならずに処理系ごと落ちる（19日目の決定99 で見つけた既存の不具合）。
    if (!real) {
        std::string_view digits = (tok[0] == '+') ? tok.substr(1) : tok;
        *out = make_int_from_text(std::string(digits));
        return true;
    }

    // ここまで来たトークンは §2.5 の文法に一致している。**変換だけ**を任せる。
    // from_chars は先頭の '+' を受け付けないので落としてから渡す（実測）。
    std::string body(tok);
    if (body[0] == '+') body.erase(0, 1);
    double d = 0;
    auto r = std::from_chars(body.data(), body.data() + body.size(), d);
    if (r.ptr != body.data() + body.size()) return false;    // 起きないはずだが黙って通さない
    if (r.ec == std::errc::result_out_of_range) {
        // 桁あふれ・桁不足。from_chars は値を書かずに帰るので、±inf / ±0.0 への
        // 丸めは strtod に任せる（判定は済んでいるので、任せるのは変換だけ）。
        d = std::strtod(body.c_str(), nullptr);
    } else if (r.ec != std::errc()) {
        return false;
    }
    *out = make_flonum(d);
    return true;
}

struct Reader {
    std::uint16_t    file;
    std::string_view src;
    std::size_t      p    = 0;
    std::uint32_t    line = 1;
    std::uint32_t    col  = 1;

    explicit Reader(std::uint16_t file_id) : file(file_id) {
        source_table_init();
        if (file_id < g_sources.size()) src = view_of(g_sources[file_id].text);
    }

    SourcePos here() const {
        SourcePos q;
        q.file = file;
        q.line = line;
        q.col  = static_cast<std::uint16_t>(col > 0xFFFFu ? 0xFFFFu : col);
        return q;
    }

    bool done() const { return p >= src.size(); }
    char peek(std::size_t ahead = 0) const {
        return (p + ahead < src.size()) ? src[p + ahead] : '\0';
    }
    bool delimiter_at(std::size_t ahead) const {
        return (p + ahead >= src.size()) || is_delimiter(src[p + ahead]);
    }
    char advance() {
        char c = src[p++];
        if (c == '\n') { ++line; col = 1; } else { ++col; }
        return c;
    }

    // 空白と ; 行コメントを読み飛ばす
    void skip_atmosphere() {
        while (!done()) {
            char c = peek();
            if (std::isspace(static_cast<unsigned char>(c))) { advance(); continue; }
            if (c == ';') { while (!done() && peek() != '\n') advance(); continue; }
            break;
        }
    }

    bool at_eof() { skip_atmosphere(); return done(); }

    // 入力を読み切っていたら nullptr を返す。
    ValuePtr read_expr() {
        skip_atmosphere();
        if (done()) return nullptr;

        SourcePos start = here();
        char c = peek();

        if (c == '(')  { advance(); return read_list(start); }
        if (c == ')')  { advance(); error_at(start, "unexpected ')'"); }
        if (c == '"')  { advance(); return read_string(start); }
        if (c == '\'') { advance(); return read_abbrev("quote", start); }
        if (c == '`')  { advance(); return read_abbrev("quasiquote", start); }
        if (c == ',')  {
            advance();
            if (peek() == '@') { advance(); return read_abbrev("splice", start); }
            return read_abbrev("unquote", start);
        }
        if (c == '#') {
            if (peek(1) == '(') { advance(); advance(); return read_vector(start); }
            char t = peek(1);
            if ((t == 't' || t == 'T' || t == 'f' || t == 'F') && delimiter_at(2)) {
                advance(); advance();
                return make_bool(t == 't' || t == 'T');
            }
            // #1= のような他の # トークンはシンボルとして読む
        }
        return read_atom(start);
    }

    ValuePtr read_abbrev(const char* head, const SourcePos& start) {
        ValuePtr x = read_expr();
        if (!x) error_at(start, std::string("unexpected EOF after ") + head + " abbreviation");
        ValuePtr inner = make_pair(x, g_nil);
        ValuePtr outer = make_pair(make_symbol(std::string(head)), inner);
        set_pos(outer, start);
        set_pos(inner, start);
        return outer;
    }

    // ドット対の区切りは、'.' が単独のトークンのときだけ。
    bool at_dot() const { return peek() == '.' && delimiter_at(1); }

    ValuePtr read_list(const SourcePos& start) {
        ValueVec      items;
        GcVec<SourcePos> poss;
        ValuePtr      tail = g_nil;

        while (true) {
            skip_atmosphere();
            if (done()) error_at(start, "unexpected EOF in list");
            if (peek() == ')') { advance(); break; }

            if (at_dot()) {
                SourcePos dot = here();
                advance();
                if (items.empty()) error_at(dot, "misplaced '.' in list");
                tail = read_expr();
                if (!tail) error_at(dot, "unexpected EOF after '.'");
                skip_atmosphere();
                if (done()) error_at(start, "unexpected EOF in list");
                if (peek() != ')') error_at(here(), "expected ')' after dotted tail");
                advance();
                break;
            }

            SourcePos ipos = here();
            ValuePtr  x    = read_expr();
            if (!x) error_at(start, "unexpected EOF in list");
            items.push_back(x);
            poss.push_back(ipos);
        }

        // 各ペアには、その car にあたる要素の位置を持たせる。
        // 先頭のペアだけは '(' の位置にする（エラーはフォームの頭を指したい）。
        ValuePtr out = tail;
        for (std::size_t i = items.size(); i > 0; --i) {
            ValuePtr cell = make_pair(items[i - 1], out);
            set_pos(cell, poss[i - 1]);
            out = cell;
        }
        if (!items.empty()) set_pos(out, start);
        return out;
    }

    ValuePtr read_vector(const SourcePos& start) {
        ValueVec items;
        while (true) {
            skip_atmosphere();
            if (done()) error_at(start, "unexpected EOF in vector literal");
            if (peek() == ')') { advance(); break; }
            ValuePtr x = read_expr();
            if (!x) error_at(start, "unexpected EOF in vector literal");
            items.push_back(x);
        }
        ValuePtr v = make_vector(items);
        set_pos(v, start);
        return v;
    }

    ValuePtr read_string(const SourcePos& start) {
        std::string out;
        while (true) {
            if (done()) error_at(start, "unexpected EOF in string literal");
            char c = advance();
            if (c == '"') break;
            if (c == '\\') {
                if (done()) error_at(start, "unexpected EOF in string literal");
                char n = advance();
                out += (n == 'n') ? '\n' : n;
            } else {
                out += c;
            }
        }
        ValuePtr s = make_string(out);
        set_pos(s, start);
        return s;
    }

    // アトムは位置を持たない（シンボルはインターンされて共有され、fixnum は
    // 即値なのでヘッダが無い）。エラーは囲みのペアの位置を使う。
    //
    // 実数はヘッダを持つので位置を貼れるが、**貼らない**（19日目の決定98）。
    // 貼っても引かれる場所が無く、アトムの扱いを1つだけ変えることになる。
    ValuePtr read_atom(const SourcePos& start) {
        std::string tok;
        while (!done() && !is_delimiter(peek())) tok += advance();
        if (tok.empty()) error_at(start, "empty token");

        if (tok == "nil")   return g_nil;
        if (tok == "true")  return g_true;
        if (tok == "false") return g_false;

        ValuePtr num = nullptr;
        if (parse_number(tok, &num)) return num;
        return make_symbol(tok);
    }
};

// トップレベルのフォームと、その開始位置。
// アトム（シンボル・fixnum）は自分では位置を持てないので、`A` のような裸の
// トップレベル式のエラーはこの位置を使う。
struct TopForm {
    ValuePtr  expr;
    SourcePos pos;
};

static GcVec<TopForm> read_all(std::uint16_t file_id) {
    Reader r(file_id);
    GcVec<TopForm> out;
    for (;;) {
        r.skip_atmosphere();
        SourcePos start = r.here();
        ValuePtr x = r.read_expr();
        if (!x) break;
        out.push_back(TopForm{x, start});
    }
    return out;
}

// ===========================================================================
// セクション 6. 構文検査
// ===========================================================================
//
// 素の car/cdr に構文検査を任せると、(define x) も (if) も (set! 1 2) も
// すべて "expected pair" という同じメッセージになり、どのフォームのどこが
// 悪いのか分からない（scheme12 がそうだった）。フォーム名・期待する形・
// そのフォームのソース位置を添えて報告する。

// フォーム全体（(let ...) など）を受け取り、その位置つきでエラーにする。
[[noreturn]] static void syntax_error(std::string_view form, std::string_view what,
                                      ValuePtr whole) {
    // what が既に detail() 形式（"\n  expected: ..."）ならそのまま繋ぎ、
    // そうでない散文なら1行の詳細として字下げする。
    std::string msg = "bad syntax in " + std::string(form);
    msg += (what.compare(0, 3, "\n  ") == 0) ? std::string(what)
                                            : "\n  " + std::string(what);
    SourcePos pos = nearest_pos(whole);
    if (!pos.known()) {
        // 位置が無い（マクロが作ったフォームなど）ときだけ式そのものを見せる
        std::string shown = to_string(whole);
        if (shown.size() > 160) shown = shown.substr(0, 157) + "...";
        msg += "\n  in " + shown;
    }
    error_at(pos, msg);
}

// 「いくつ期待して、いくつ来たか」の詳細行。max_args == 0 は上限なし。
// 特殊形式（セクション6）とプリミティブ（セクション11）で同じ文面を使う。
static std::string arity_detail(std::size_t min_args, std::size_t max_args,
                                std::size_t got) {
    std::string want;
    if (max_args == 0)             want = "at least " + std::to_string(min_args);
    else if (min_args == max_args) want = std::to_string(min_args);
    else                           want = std::to_string(min_args) + " to " +
                                          std::to_string(max_args);
    // 「1 argument」「at least 1 argument」は単数。範囲を言うときは複数。
    bool singular = (min_args == 1 && (max_args == 1 || max_args == 0));
    want += singular ? " argument" : " arguments";
    return expected_given(want, std::to_string(got));
}

// 真リストの長さ。ドットリスト（不正な形）なら nullopt。
// cdr 方向は再帰せず、Floyd の2ポインタ法で循環も検出する（§4.3）。
static std::optional<std::size_t> form_arity(ValuePtr rest) {
    std::size_t n = 0;
    ValuePtr slow = rest, fast = rest;
    while (is_pair(fast)) {
        ++n; fast = as_pair(fast)->cdr;
        if (!is_pair(fast)) break;
        ++n; fast = as_pair(fast)->cdr;
        slow = as_pair(slow)->cdr;
        if (fast == slow) return std::nullopt;   // 循環
    }
    if (!is_nil(fast)) return std::nullopt;
    return n;
}

// min 以上 max 以下の引数を要求する（max == 0 は上限なし）。rest は head を除いた残り。
static void check_arity(std::string_view form, ValuePtr whole, ValuePtr rest,
                        std::size_t min_args, std::size_t max_args) {
    auto n = form_arity(rest);
    if (!n) syntax_error(form, "the argument list is improper or circular", whole);
    if (*n < min_args || (max_args != 0 && *n > max_args))
        syntax_error(form, arity_detail(min_args, max_args, *n), whole);
}

// (let ((var expr) ...) ...) 系の束縛リストを検証する。
static void check_bindings(std::string_view form, ValuePtr whole, ValuePtr bindings) {
    if (!is_nil(bindings) && !is_pair(bindings))
        syntax_error(form, expected_given("a list of bindings", to_string(bindings)), whole);
    for (ValuePtr b = bindings; !is_nil(b); b = as_pair(b)->cdr) {
        if (!is_pair(b))
            syntax_error(form, expected_given("a proper list of bindings",
                                              to_string(bindings)), whole);
        ValuePtr one = as_pair(b)->car;
        if (!is_pair(one) || !is_symbol(as_pair(one)->car) ||
            !is_pair(as_pair(one)->cdr) || !is_nil(as_pair(as_pair(one)->cdr)->cdr))
            syntax_error(form, expected_given("each binding to be (variable expression)",
                                              to_string(one)), whole);
    }
}

// 仮引数リストを (x y) / (x . r) / r の形として分解する。
static bool extract_params(ValuePtr params_expr,
                           GcVec<GcString>& fixed,
                           std::optional<GcString>& rest) {
    fixed.clear();
    rest.reset();
    while (!is_nil(params_expr)) {
        if (!is_pair(params_expr)) {
            if (!is_symbol(params_expr)) return false;
            rest = as_symbol_name(params_expr);
            return true;
        }
        ValuePtr x = as_pair(params_expr)->car;
        if (!is_symbol(x)) return false;
        fixed.push_back(as_symbol_name(x));
        params_expr = as_pair(params_expr)->cdr;
    }
    return true;
}

// 真リストをベクタに直す。cdr 方向は再帰せず、Floyd の2ポインタ法で循環を検出する。
// ホットパスでハッシュ集合を確保しない（§4.1 / §4.3）。
static ValueVec list_to_vector(ValuePtr ls, std::string_view who) {
    ValueVec out;
    ValuePtr slow = ls, fast = ls;
    while (is_pair(fast)) {
        out.push_back(as_pair(fast)->car);
        fast = as_pair(fast)->cdr;
        if (!is_pair(fast)) break;
        out.push_back(as_pair(fast)->car);
        fast = as_pair(fast)->cdr;
        slow = as_pair(slow)->cdr;
        if (fast == slow)
            error_at(nearest_pos(ls), std::string(who) + ": wrong type of argument" +
                                      expected_given("a proper list", "a circular list"));
    }
    if (!is_nil(fast))
        error_at(nearest_pos(ls), std::string(who) + ": wrong type of argument" +
                                  expected_given("a proper list", to_string(ls)));
    return out;
}

// ===========================================================================
// セクション 7. 構文展開
// ===========================================================================
//
// let / let* / letrec / 名前つき let / and / or / cond / case / do /
// quasiquote を、より基本的なフォームへ書き換える。コンパイラ（セクション8）は
// これらを直接コンパイルせず、`expand_form_1` で1段書き換えてから作り直す。
//
// 展開結果の位置: 新しく作ったペアは位置を持たないので、**出力の先頭ペアに
// 元のフォームの位置を貼る**。ソースから持ってきた部分式は自分の位置を保った
// ままなので、これだけで「エラーがどのフォームの中か」は追える。
// （§9 の「マクロ展開後の位置情報」への最小限の答え）

static ValuePtr with_pos_of(ValuePtr out, ValuePtr src) {
    SourcePos p = nearest_pos(src);
    if (p.known() && is_pair(out)) set_pos(out, p);
    return out;
}

static ValuePtr make_begin_form(const ValueVec& forms) {
    if (forms.empty()) return g_nil;
    if (forms.size() == 1) return forms[0];
    ValueVec xs;
    xs.push_back(make_symbol("begin"));
    xs.insert(xs.end(), forms.begin(), forms.end());
    return list_from(xs);
}

static int g_gensym_counter = 0;
static ValuePtr make_gensym(std::string_view prefix) {
    return make_symbol(std::string(prefix) + std::to_string(++g_gensym_counter));
}

// (let ((v e) ...) body ...)        -> ((lambda (v ...) body ...) e ...)
// (let name ((v e) ...) body ...)   -> (letrec ((name (lambda (v ...) body ...)))
//                                        (name e ...))
static ValuePtr expand_let(ValuePtr form) {
    ValuePtr rest = cdr(form);
    check_arity("let", form, rest, 1, 0);
    ValuePtr bindings = car(rest);
    ValuePtr body     = cdr(rest);

    if (is_symbol(bindings)) {                     // 名前つき let
        if (!is_pair(body)) syntax_error("let", "named let needs a binding list", form);
        ValuePtr name           = bindings;
        ValuePtr real_bindings  = car(body);
        ValuePtr real_body      = cdr(body);
        check_bindings("let", form, real_bindings);
        ValueVec bs = list_to_vector(real_bindings, "let");
        ValueVec params, args;
        for (ValuePtr b : bs) { params.push_back(car(b)); args.push_back(car(cdr(b))); }
        ValuePtr lambda_expr = make_pair(make_symbol("lambda"),
                                         make_pair(list_from(params), real_body));
        ValueVec call;
        call.push_back(name);
        call.insert(call.end(), args.begin(), args.end());
        return with_pos_of(list_from({make_symbol("letrec"),
                                      list_from({list_from({name, lambda_expr})}),
                                      list_from(call)}), form);
    }

    check_bindings("let", form, bindings);
    ValueVec bs = list_to_vector(bindings, "let");
    ValueVec params, args;
    for (ValuePtr b : bs) { params.push_back(car(b)); args.push_back(car(cdr(b))); }
    ValuePtr lambda_expr = make_pair(make_symbol("lambda"),
                                     make_pair(list_from(params), body));
    ValueVec call;
    call.push_back(lambda_expr);
    call.insert(call.end(), args.begin(), args.end());
    return with_pos_of(list_from(call), form);
}

// (let* (b1 b2 ...) body ...) -> (let (b1) (let* (b2 ...) (begin body ...)))
static ValuePtr expand_let_star(ValuePtr form) {
    ValuePtr rest = cdr(form);
    check_arity("let*", form, rest, 1, 0);
    ValuePtr bindings = car(rest);
    ValuePtr body     = cdr(rest);
    check_bindings("let*", form, bindings);
    ValueVec bs = list_to_vector(bindings, "let*");
    ValuePtr body_form = make_begin_form(list_to_vector(body, "let*"));

    if (bs.empty()) return with_pos_of(body_form, form);
    if (bs.size() == 1)
        return with_pos_of(list_from({make_symbol("let"), list_from({bs[0]}), body_form}),
                           form);
    ValueVec tail_bindings(bs.begin() + 1, bs.end());
    ValuePtr nested = list_from({make_symbol("let*"), list_from(tail_bindings), body_form});
    return with_pos_of(list_from({make_symbol("let"), list_from({bs[0]}), nested}), form);
}

// (letrec ((v e) ...) body ...) -> (let ((v :undef) ...) (set! v e) ... body ...)
static ValuePtr expand_letrec(ValuePtr form) {
    ValuePtr rest = cdr(form);
    check_arity("letrec", form, rest, 1, 0);
    ValuePtr bindings = car(rest);
    ValuePtr body     = cdr(rest);
    check_bindings("letrec", form, bindings);
    ValueVec bs = list_to_vector(bindings, "letrec");

    ValueVec let_bindings, seq;
    for (ValuePtr b : bs)
        let_bindings.push_back(list_from({car(b), make_symbol(":undef")}));
    for (ValuePtr b : bs)
        seq.push_back(list_from({make_symbol("set!"), car(b), car(cdr(b))}));
    ValueVec body_vec = list_to_vector(body, "letrec");
    seq.insert(seq.end(), body_vec.begin(), body_vec.end());

    return with_pos_of(list_from({make_symbol("let"), list_from(let_bindings),
                                  make_begin_form(seq)}), form);
}

// (and)          -> #t
// (and x)        -> x
// (and x y ...)  -> (if x (and y ...) #f)
static ValuePtr expand_and(ValuePtr form) {
    ValueVec xs = list_to_vector(cdr(form), "and");
    if (xs.empty())      return g_true;
    if (xs.size() == 1)  return xs[0];
    ValuePtr out = xs.back();
    for (std::size_t i = xs.size() - 1; i > 0; --i)
        out = list_from({make_symbol("if"), xs[i - 1], out, g_false});
    return with_pos_of(out, form);
}

// (or)          -> #f
// (or x)        -> x
// (or x y ...)  -> (let ((t x)) (if t t (or y ...)))
// gensym は scheme12 と同じ順（外側から）で採番する。
static ValuePtr expand_or(ValuePtr form) {
    ValueVec xs = list_to_vector(cdr(form), "or");
    if (xs.empty())     return g_false;
    if (xs.size() == 1) return xs[0];

    ValueVec temps;
    for (std::size_t i = 0; i + 1 < xs.size(); ++i) temps.push_back(make_gensym("or"));

    ValuePtr out = xs.back();
    for (std::size_t i = xs.size() - 1; i > 0; --i) {
        ValuePtr t = temps[i - 1];
        out = list_from({make_symbol("let"),
                         list_from({list_from({t, xs[i - 1]})}),
                         list_from({make_symbol("if"), t, t, out})});
    }
    return with_pos_of(out, form);
}

// (cond)                     -> :undef
// (cond (else body ...) ...) -> (begin body ...)   ※ else 以降の節は捨てる
// (cond (test) rest ...)     -> (let ((t test)) (if t t <rest>))
// (cond (test body ...) ...) -> (if test (begin body ...) <rest>)
static ValuePtr expand_cond(ValuePtr form) {
    struct Clause { ValuePtr test; ValuePtr body; ValuePtr temp; bool is_else; };
    GcVec<Clause> clauses;

    ValuePtr cur = cdr(form);
    for (; !is_nil(cur); cur = as_pair(cur)->cdr) {
        if (!is_pair(cur))
            syntax_error("cond", expected_given("a proper list of clauses",
                                                to_string(cdr(form))), form);
        ValuePtr cl = as_pair(cur)->car;
        if (!is_pair(cl))
            syntax_error("cond", expected_given("each clause to be (test expression ...)",
                                                to_string(cl)), form);
        Clause c{car(cl), cdr(cl), nullptr, is_symbol_named(car(cl), "else")};
        // 本体のない節 (test) は値そのものを返すので、一時変数が要る
        if (!c.is_else && is_nil(c.body)) c.temp = make_gensym("cond");
        clauses.push_back(c);
        if (c.is_else) break;              // else 以降は評価されない（scheme12 と同じ）
    }

    ValuePtr out = make_symbol(":undef");
    for (std::size_t i = clauses.size(); i > 0; --i) {
        const Clause& c = clauses[i - 1];
        if (c.is_else) {
            out = make_begin_form(list_to_vector(c.body, "cond"));
        } else if (c.temp) {
            out = list_from({make_symbol("let"),
                             list_from({list_from({c.temp, c.test})}),
                             list_from({make_symbol("if"), c.temp, c.temp, out})});
        } else {
            out = list_from({make_symbol("if"), c.test,
                             make_begin_form(list_to_vector(c.body, "cond")), out});
        }
    }
    return with_pos_of(out, form);
}

// (case key ((d ...) body ...) ... (else body ...))
//   -> (let ((t key)) (cond ((memv t '(d ...)) body ...) ... (else body ...)))
static ValuePtr expand_case(ValuePtr form) {
    ValuePtr rest = cdr(form);
    check_arity("case", form, rest, 1, 0);
    ValuePtr key     = car(rest);
    ValuePtr clauses = cdr(rest);
    ValuePtr t       = make_gensym("case");

    ValueVec cond_clauses;
    for (ValuePtr cur = clauses; !is_nil(cur); cur = as_pair(cur)->cdr) {
        if (!is_pair(cur))
            syntax_error("case", expected_given("a proper list of clauses",
                                                to_string(clauses)), form);
        ValuePtr cl = as_pair(cur)->car;
        if (!is_pair(cl))
            syntax_error("case",
                         expected_given("each clause to be ((datum ...) expression ...)",
                                        to_string(cl)), form);
        ValuePtr head = car(cl);
        ValueVec one;
        if (is_symbol_named(head, "else")) {
            one.push_back(make_symbol("else"));
        } else {
            one.push_back(list_from({make_symbol("memv"), t,
                                     list_from({make_symbol("quote"), head})}));
        }
        ValueVec b = list_to_vector(cdr(cl), "case");
        one.insert(one.end(), b.begin(), b.end());
        cond_clauses.push_back(list_from(one));
    }

    return with_pos_of(list_from({make_symbol("let"),
                                  list_from({list_from({t, key})}),
                                  make_pair(make_symbol("cond"), list_from(cond_clauses))}),
                       form);
}

// (do ((v init step) ...) (test result ...) body ...)
//   -> (letrec ((loop (lambda (v ...) (if test (begin result ...)
//                                          (begin body ... (loop step ...))))))
//        (loop init ...))
static ValuePtr expand_do(ValuePtr form) {
    ValuePtr rest = cdr(form);
    check_arity("do", form, rest, 2, 0);
    ValuePtr var_form  = car(rest);
    ValuePtr test_form = car(cdr(rest));
    ValuePtr body      = cdr(cdr(rest));
    if (!is_pair(test_form))
        syntax_error("do", expected_given("the test clause to be (test expression ...)",
                                          to_string(test_form)), form);

    ValueVec vars, inits, steps;
    for (ValuePtr v : list_to_vector(var_form, "do")) {
        if (!is_pair(v) || !is_symbol(car(v)) || !is_pair(cdr(v)))
            syntax_error("do", expected_given("each spec to be (variable init [step])",
                                              to_string(v)), form);
        vars.push_back(car(v));
        inits.push_back(car(cdr(v)));
        ValuePtr step_tail = cdr(cdr(v));
        steps.push_back(is_nil(step_tail) ? car(v) : car(step_tail));
    }

    ValuePtr loop_name = make_gensym("loop");

    ValueVec recur;
    recur.push_back(loop_name);
    recur.insert(recur.end(), steps.begin(), steps.end());

    ValueVec else_seq = list_to_vector(body, "do");
    else_seq.push_back(list_from(recur));

    ValuePtr if_expr = list_from({make_symbol("if"), car(test_form),
                                  make_begin_form(list_to_vector(cdr(test_form), "do")),
                                  make_begin_form(else_seq)});
    ValuePtr lambda_expr = list_from({make_symbol("lambda"), list_from(vars), if_expr});

    ValueVec call;
    call.push_back(loop_name);
    call.insert(call.end(), inits.begin(), inits.end());

    return with_pos_of(list_from({make_symbol("letrec"),
                                  list_from({list_from({loop_name, lambda_expr})}),
                                  list_from(call)}), form);
}

// 準クオートの展開。cdr 方向は再帰せず、要素を前から集めて後ろから組み立てる（§4.3）。
// 準クオートのネストには対応しない（§2.5 の凍結仕様）。
static ValuePtr qq_transfer(ValuePtr x) {
    if (!is_pair(x)) {
        // ベクタリテラル内の unquote。要素をリストに直して変換し、list->vector で戻す。
        // これがないと `#(1 ,x) が #(1 (unquote x)) になる。
        if (is_vector(x))
            return list_from({make_symbol("list->vector"),
                              qq_transfer(list_from(as_vector(x)->elems))});
        return list_from({make_symbol("quote"), x});
    }

    struct Step { bool splice; ValuePtr expr; };
    GcVec<Step> steps;
    ValuePtr tail = nullptr;
    ValuePtr cur  = x;

    while (is_pair(cur)) {
        ValuePtr a = as_pair(cur)->car;
        // ドット位置の unquote。`(a . ,v) はリーダで (a unquote v) と読まれるため、
        // cdr へ降りた先で cur 自身が (unquote v) になる。ここで拾わないと
        // unquote がただのシンボルとして素通りし、(a unquote v) という3要素の
        // リストが黙って出来てしまう。R5RS では `(unquote v) と ,v は等価。
        if (is_symbol_named(a, "unquote")) {
            if (!is_pair(as_pair(cur)->cdr))
                error_at(nearest_pos(cur), "bad syntax in quasiquote" +
                                           expected_given("(unquote expression)",
                                                          to_string(cur)));
            tail = car(as_pair(cur)->cdr);
            break;
        }
        // `(a . ,@v) は R5RS で不正。黙って壊れた結果を返さずに知らせる。
        if (is_symbol_named(a, "splice"))
            error_at(nearest_pos(cur),
                     "bad syntax in quasiquote" +
                     detail("note", "unquote-splicing (,@) is not allowed in the tail "
                                    "position of a dotted list"));

        if (is_pair(a) && is_symbol_named(car(a), "unquote"))
            steps.push_back(Step{false, car(cdr(a))});
        else if (is_pair(a) && is_symbol_named(car(a), "splice"))
            steps.push_back(Step{true, car(cdr(a))});
        else if (is_pair(a))
            steps.push_back(Step{false, qq_transfer(a)});   // car 方向の再帰は可
        else
            steps.push_back(Step{false, list_from({make_symbol("quote"), a})});

        cur = as_pair(cur)->cdr;
    }
    if (!tail) tail = qq_transfer(cur);

    ValuePtr out = tail;
    for (std::size_t i = steps.size(); i > 0; --i) {
        const Step& st = steps[i - 1];
        out = list_from({make_symbol(st.splice ? "append" : "cons"), st.expr, out});
    }
    return out;
}

// R5RS 4.1.6 / 5.2.2: 本体先頭に並ぶ define 群を letrec へ移す。
// これをやらないと define が「大域への代入」にコンパイルされ、内部の補助関数が
// 大域を引くため、同名の補助関数を持つ別の関数に後勝ちで上書きされてしまう。
//
// **先頭の連続した define だけ**を対象にする（§2.6 の凍結仕様）。式より後ろの
// define、マクロが生成した define、本体先頭の (begin (define ...) ...) の
// スプライスは大域定義のまま残る。呼ぶのは comp() の lambda ケースのみ。
static ValuePtr scan_out_defines(ValuePtr body) {
    ValueVec forms = list_to_vector(body, "lambda body");
    ValueVec bindings;
    std::size_t n = 0;

    while (n < forms.size() && is_pair(forms[n]) && is_symbol_named(car(forms[n]), "define")) {
        ValuePtr drest = cdr(forms[n]);
        if (is_nil(drest)) syntax_error("define", "internal define needs a name", forms[n]);
        ValuePtr lhs      = car(drest);
        ValuePtr rhs_tail = cdr(drest);
        if (is_symbol(lhs)) {
            if (is_nil(rhs_tail))
                syntax_error("define", "internal define needs a value expression", forms[n]);
            bindings.push_back(list_from({lhs, car(rhs_tail)}));
        } else if (is_pair(lhs) && is_symbol(car(lhs))) {
            ValuePtr lambda_expr = make_pair(make_symbol("lambda"),
                                             make_pair(cdr(lhs), rhs_tail));
            bindings.push_back(list_from({car(lhs), lambda_expr}));
        } else {
            syntax_error("define",
                         "expected (define name expr) or (define (name . params) body ...)",
                         forms[n]);
        }
        ++n;
    }
    if (bindings.empty()) return body;

    ValueVec letrec_form;
    letrec_form.push_back(make_symbol("letrec"));
    letrec_form.push_back(list_from(bindings));
    for (std::size_t i = n; i < forms.size(); ++i) letrec_form.push_back(forms[i]);
    // 本体が define だけの場合、letrec の本体が空になるので :undef を足す
    if (n == forms.size()) letrec_form.push_back(make_symbol(":undef"));
    return list_from({with_pos_of(list_from(letrec_form), body)});
}

// 書き換えの対象になるフォームなら1段展開して返す。そうでなければそのまま返す。
// コンパイラ（セクション8）はこれを呼んでから、返ってきた式を作り直す。
static ValuePtr expand_form_1(ValuePtr form) {
    if (!is_pair(form)) return form;
    ValuePtr head = as_pair(form)->car;
    if (!is_symbol(head)) return form;
    std::string_view name = view_of(as_symbol_name(head));

    if (name == "let")     return expand_let(form);
    if (name == "let*")    return expand_let_star(form);
    if (name == "letrec")  return expand_letrec(form);
    if (name == "and")     return expand_and(form);
    if (name == "or")      return expand_or(form);
    if (name == "cond")    return expand_cond(form);
    if (name == "case")    return expand_case(form);
    if (name == "do")      return expand_do(form);
    if (name == "quasiquote") {
        check_arity("quasiquote", form, cdr(form), 1, 1);
        return with_pos_of(qq_transfer(car(cdr(form))), form);
    }
    return form;
}

// ===========================================================================
// セクション 9. 命令セット
// ===========================================================================
//
// 設計は dev_memo.md §4.4 に確定してある。**先にそちらを読むこと。**
//   - 引数はスタックに積んだまま渡す。`ARGS` は無い
//   - 大域変数は名前でなく GlobalCell* で引く（ハッシュ検索が消える）
//   - `LDCT` は作らない（デッドコードを最初から作らない。決定7）
//   - Instruction は固定長。汎用のポインタ枠 p1/p2 の意味は命令ごとに決まる

enum class Op : std::uint8_t {
    LD, LDC, LDG, LDF,
    APP, TAPP, ARGS_AP, APPLY, TAPPLY, RTN,
    SEL, SELR, JOIN, POP,
    DEF, DEFM, LSET, GSET,
    CALLCC, TCALLCC, STOP
};

static const char* op_name(Op op) {
    switch (op) {
        case Op::LD:      return "LD";
        case Op::LDC:     return "LDC";
        case Op::LDG:     return "LDG";
        case Op::LDF:     return "LDF";
        case Op::APP:     return "APP";
        case Op::TAPP:    return "TAPP";
        case Op::ARGS_AP: return "ARGS-AP";
        case Op::APPLY:   return "APPLY";
        case Op::TAPPLY:  return "TAPPLY";
        case Op::RTN:     return "RTN";
        case Op::SEL:     return "SEL";
        case Op::SELR:    return "SELR";
        case Op::JOIN:    return "JOIN";
        case Op::POP:     return "POP";
        case Op::DEF:     return "DEF";
        case Op::DEFM:    return "DEFM";
        case Op::LSET:    return "LSET";
        case Op::GSET:    return "GSET";
        case Op::CALLCC:  return "CALLCC";
        case Op::TCALLCC: return "TCALLCC";
        case Op::STOP:    return "STOP";
    }
    return "???";
}

// 大域変数は「セル」で持つ。名前による検索はコンパイル時に1回だけ。
// scheme12 の g_globals / g_macros という2つの表を1つに統合したもので、
// 原典がシンボルのプロパティリスト1箇所に両方入れていた形に戻る。
struct GlobalCell : public gc {
    ValuePtr value = nullptr;   // nullptr なら未束縛
    ValuePtr macro = nullptr;   // マクロなら変換子（クロージャ）、それ以外は nullptr
    GcString name;
    explicit GlobalCell(const GcString& n) : name(n) {}
};

// 固定長 32 バイト。p1 / p2 の意味は命令ごとに違う（§4.4.5 の表）。
//   LDC              p1 = 定数 (ValuePtr)
//   LDG DEF DEFM GSET p1 = GlobalCell*
//   LDF              p1 = Template*
//   SEL SELR         p1 = 真の枝 (Code*), p2 = 偽の枝 (Code*)
//   LD LSET          a = フレーム番号, b = 位置
//   APP TAPP ARGS_AP a = 個数
struct Instruction {
    Op            op;
    std::uint16_t a = 0;
    std::uint16_t b = 0;
    SourcePos     pos;
    void*         p1 = nullptr;
    void*         p2 = nullptr;

    explicit Instruction(Op o) : op(o) {}

    ValuePtr    constant() const { return static_cast<ValuePtr>(p1); }
    GlobalCell* cell()     const { return static_cast<GlobalCell*>(p1); }
    Template*   tmpl()     const { return static_cast<Template*>(p1); }
    CodePtr     code_true()  const { return static_cast<CodePtr>(p1); }
    CodePtr     code_false() const { return static_cast<CodePtr>(p2); }
};

struct Code : public gc {
    GcVec<Instruction> ins;
};

// 環境フレーム。可変長の末尾配列を持ち、1フレーム = 1回の確保で済ませる。
// Scheme の値ではないので Object は継承しない。
struct Env {
    Env*          next;
    std::uint32_t size;
    ValuePtr      vals[1];   // 実際は size 個
};

static Env* env_extend(Env* parent, std::size_t n) {
    std::size_t bytes = sizeof(Env) + (n > 0 ? (n - 1) * sizeof(ValuePtr) : 0);
    Env* e = static_cast<Env*>(GC_MALLOC(bytes));   // 0 で初期化され、走査される
    e->next = parent;
    e->size = static_cast<std::uint32_t>(n);
    return e;
}

static Env* env_at(Env* e, std::uint16_t depth) {
    for (std::uint16_t i = 0; i < depth; ++i) {
        if (!e) return nullptr;
        e = e->next;
    }
    return e;
}

// --- 大域環境 --------------------------------------------------------------

using GlobalTable = std::unordered_map<
    std::string_view, GlobalCell*, std::hash<std::string_view>,
    std::equal_to<std::string_view>,
    traceable_allocator<std::pair<const std::string_view, GlobalCell*> > >;
static GlobalTable g_globals;

// 未束縛でもセルは作る。前方参照はこれで自然に解決する。
static GlobalCell* global_cell(std::string_view name) {
    auto it = g_globals.find(name);
    if (it != g_globals.end()) return it->second;
    GlobalCell* cell = new GlobalCell(to_gc(name));
    g_globals.emplace(view_of(cell->name), cell);
    return cell;
}

static void global_define(std::string_view name, ValuePtr v) {
    global_cell(name)->value = v;
}

// --- 逆アセンブル表示（§1.5: デバッグ機能は一級市民） ----------------------
//
// 命令セットを変えたら必ずここも直す。SEL の枝は字下げして入れ子で見せる。

static void disassemble_code(std::string& out, CodePtr code, int indent, int depth_left);

static void disassemble_ins(std::string& out, const Instruction& ins,
                            int indent, int depth_left) {
    out.append(static_cast<std::size_t>(indent) * 2, ' ');
    out += op_name(ins.op);
    switch (ins.op) {
        case Op::LD:
        case Op::LSET:
            out += " (" + std::to_string(ins.a) + " . " + std::to_string(ins.b) + ")";
            break;
        case Op::LDC:
            out += " " + to_string(ins.constant());
            break;
        case Op::LDG: case Op::DEF: case Op::DEFM: case Op::GSET:
            out += " " + to_std(ins.cell()->name);
            break;
        case Op::LDF: {
            const Template* t = ins.tmpl();
            out += ' ';
            write_params(out, t);
            if (ins.b) out += " [no-alloc]";     // 直後の APP に消費される（決定54）
            if (!t->name.empty()) out += " ; " + to_std(t->name);
            if (depth_left > 0 && t->body) {
                out += "\n";
                out.append(static_cast<std::size_t>(indent) * 2 + 2, ' ');
                out += "body:\n";
                disassemble_code(out, t->body, indent + 2, depth_left - 1);
                return;
            }
            break;
        }
        case Op::APP: case Op::TAPP: case Op::ARGS_AP:
            out += " " + std::to_string(ins.a);
            break;
        case Op::SEL: case Op::SELR:
            if (depth_left > 0) {
                out += "\n";
                out.append(static_cast<std::size_t>(indent) * 2 + 2, ' ');
                out += "then:\n";
                disassemble_code(out, ins.code_true(), indent + 2, depth_left - 1);
                out.append(static_cast<std::size_t>(indent) * 2 + 2, ' ');
                out += "else:\n";
                disassemble_code(out, ins.code_false(), indent + 2, depth_left - 1);
                return;
            }
            out += " [then] [else]";
            break;
        default:
            break;
    }
    out += "\n";
}

static void disassemble_code(std::string& out, CodePtr code, int indent, int depth_left) {
    if (!code) return;
    for (std::size_t i = 0; i < code->ins.size(); ++i) {
        std::string num = "[" + std::to_string(i) + "] ";
        out.append(static_cast<std::size_t>(indent) * 2, ' ');
        out += num;
        std::string one;
        disassemble_ins(one, code->ins[i], 0, depth_left);
        // 2行目以降の字下げを揃える
        std::string pad(static_cast<std::size_t>(indent) * 2 + num.size(), ' ');
        for (std::size_t k = 0; k < one.size(); ++k) {
            out += one[k];
            if (one[k] == '\n' && k + 1 < one.size()) out += pad;
        }
    }
}

static std::string disassemble(CodePtr code, int depth_left = 8) {
    std::string out;
    disassemble_code(out, code, 0, depth_left);
    return out;
}

// ===========================================================================
// セクション 8. コンパイラ
// ===========================================================================
//
// **ファイル上ではセクション9（命令セット）の後ろに置いてある。**
// コンパイラは Op / Instruction / Template / GlobalCell を使うので、
// C++ の宣言順としてこちらが後になる。dev_memo.md §3 の並びは 8 → 9 だが、
// 実ファイルは 9 → 8。理由は §6 の5日目に記録した。
//
// 特殊形式の並びは scheme12 の comp() を踏襲する。**特殊形式の判定は
// マクロ展開より先**なので、`if` や `cond` と同名のユーザマクロは効かない。

using CompileFrame = GcVec<GcString>;
using CompileEnv   = GcVec<CompileFrame>;

// 局所変数の位置。見つからなければ大域。
static bool location_of(std::string_view name, const CompileEnv& env,
                        std::uint16_t& frame, std::uint16_t& index) {
    for (std::size_t i = 0; i < env.size(); ++i) {
        for (std::size_t j = 0; j < env[i].size(); ++j) {
            if (view_of(env[i][j]) == name) {
                frame = static_cast<std::uint16_t>(i);
                index = static_cast<std::uint16_t>(j);
                return true;
            }
        }
    }
    return false;
}

static void emit(CodePtr code, Instruction ins, const SourcePos& pos) {
    ins.pos = pos;
    code->ins.push_back(ins);
}

// --- マクロ展開の実況（原典の macro-print の後継。17日目の決定76〜78）------
//
// **`macroexpand` では代われない。** あれは最外のフォームを1段書き換えるだけで、
// 入れ子の展開は見えない（16日目の決定73）。`--expand` も代わりにならない。
// 評価しないので `define-macro` が効いておらず、利用者のマクロを知らない。
//
// ここが見せるのは**コンパイラが実際に行った書き換え**である。だから
// `comp()` が書き換えを行う2箇所の、両方から呼ぶ:
//   - `expand_form_1`（let / cond / quasiquote など、組み込みの特殊形式）
//   - `macro_expand_1_expr`（define-macro で定義された利用者のマクロ）
// 原典では前者も mlib7.scm のマクロだったので、両方見せて原典と同じ範囲になる。

static bool g_macro_print = false;

static void macro_print_step(const char* kind, ValuePtr from, ValuePtr to) {
    SourcePos pos = nearest_pos(from);
    std::string head = std::string("\n==== Expand (") + kind + ")";
    if (pos.known()) head += " " + pos_label(pos);
    std::printf("%s ====\n", head.c_str());
    std::printf("from: %s\n", to_string(from).c_str());
    std::printf("  to: %s\n", to_string(to).c_str());
}

// `inherited` は「自分では位置を持てない部分式」に使う囲みフォームの位置。
// シンボルはインターンされ fixnum は即値なので位置を持てない。これが無いと
// いちばん多い実行時エラー（unbound global）に位置が付かない。
static void comp(ValuePtr expr, const CompileEnv& env, CodePtr code, bool tail,
                 SourcePos inherited);
static void comp_body(ValuePtr body, const CompileEnv& env, CodePtr code, bool tail,
                      SourcePos inherited);

// セクション10（VM）で定義する。マクロ展開のために VM を1回まわす。
static ValuePtr apply_callable(ValuePtr proc, ValuePtr* argv, std::size_t argc);

// 先頭がマクロなら1段展開する。そうでなければ expr をそのまま返す。
static ValuePtr macro_expand_1_expr(ValuePtr expr) {
    if (!is_pair(expr)) return expr;
    ValuePtr head = as_pair(expr)->car;
    if (!is_symbol(head)) return expr;
    auto it = g_globals.find(view_of(as_symbol_name(head)));
    if (it == g_globals.end() || !it->second->macro) return expr;
    ValueVec args = list_to_vector(as_pair(expr)->cdr, "macro call");
    ValuePtr out = apply_callable(it->second->macro, args.data(), args.size());
    return with_pos_of(out, expr);
}

// 自己評価する値か（scheme12 と同じ判定。実数は19日目に足した）
static bool is_self_evaluating(ValuePtr v) {
    switch (tag_of(v)) {
        case Tag::Nil: case Tag::Boolean: case Tag::Fixnum:
        case Tag::Bignum: case Tag::Flonum: case Tag::String: case Tag::Vector:
            return true;
        default:
            return false;
    }
}

// lambda 本体をコンパイルして Template を作る。
//
// `inherited` は呼び出し側（comp）が既に解決した位置。**これを受け取るのが
// 肝心。** マクロや構文展開が作った lambda フォームは自分の位置を持たないので、
// ここで nearest_pos(whole) を引き直すと**継承の鎖が切れて本体全体が位置を
// 失う**（11日目の決定52）。
static Template* compile_lambda(ValuePtr params_expr, ValuePtr body,
                                const CompileEnv& env, ValuePtr whole,
                                SourcePos inherited) {
    GcVec<GcString>         fixed;
    std::optional<GcString> rest;
    if (!extract_params(params_expr, fixed, rest))
        syntax_error("lambda",
                     "parameter list must be symbols, e.g. (x y) or (x . rest)", whole);

    body = scan_out_defines(body);

    CompileEnv   env2 = env;
    CompileFrame frame = fixed;
    if (rest) frame.push_back(*rest);
    env2.insert(env2.begin(), frame);

    SourcePos body_pos = nearest_pos(whole);
    if (!body_pos.known()) body_pos = inherited;

    CodePtr body_code = new Code();
    comp_body(body, env2, body_code, true, body_pos);
    emit(body_code, Instruction(Op::RTN), body_pos);

    Template* t = new Template();
    t->params = fixed;
    t->rest   = rest;
    t->body   = body_code;
    return t;
}

// 直前に出した命令が LDF なら、その雛形に名前を付ける（逆アセンブル表示用）
static void name_last_closure(CodePtr code, const GcString& name) {
    if (!code->ins.empty() && code->ins.back().op == Op::LDF)
        code->ins.back().tmpl()->name = name;
}

static void comp(ValuePtr expr, const CompileEnv& env, CodePtr code, bool tail,
                 SourcePos inherited) {
    SourcePos pos = nearest_pos(expr);
    if (!pos.known()) pos = inherited;

    if (is_self_evaluating(expr)) {
        Instruction i(Op::LDC);
        i.p1 = expr;
        emit(code, i, pos);
        return;
    }

    if (is_symbol(expr)) {
        std::string_view name = view_of(as_symbol_name(expr));
        std::uint16_t f = 0, idx = 0;
        if (location_of(name, env, f, idx)) {
            Instruction i(Op::LD);
            i.a = f; i.b = idx;
            emit(code, i, pos);
        } else {
            Instruction i(Op::LDG);
            i.p1 = global_cell(name);
            emit(code, i, pos);
        }
        return;
    }

    if (!is_pair(expr)) error_at(pos, "cannot compile atom: " + to_string(expr));

    ValuePtr head = as_pair(expr)->car;
    ValuePtr rest = as_pair(expr)->cdr;
    std::string_view h = is_symbol(head) ? view_of(as_symbol_name(head)) : std::string_view();

    if (h == "quote") {
        check_arity("quote", expr, rest, 1, 1);
        Instruction i(Op::LDC);
        i.p1 = car(rest);
        emit(code, i, pos);
        return;
    }

    // 原典のトレース切り替えのうち、**後継が本当にあるものだけ**を無視して
    // #t を返す（scheme12 と同じ扱い）。16日目に実測して仕分けた（決定72）:
    //   trace-print   → trace-on / trace-off が埋めている
    //   compile-print → (compile expr) と重複が大きい。入れない
    // `macro-print` はここから外した。**後継が届いていなかった**ので
    // プリミティブとして復活させてある（決定73・76）。`test-start` /
    // `test-end` を 6日目に復活させたのと同じ扱い（決定29）。
    if (h == "trace-print" || h == "compile-print") {
        Instruction i(Op::LDC);
        i.p1 = g_true;
        emit(code, i, pos);
        return;
    }

    // 書き換えで済む特殊形式は expand_form_1 に任せて作り直す（決定20）
    if (h == "quasiquote" || h == "let" || h == "let*" || h == "letrec" ||
        h == "and" || h == "or" || h == "cond" || h == "case" || h == "do") {
        ValuePtr rewritten = expand_form_1(expr);
        if (g_macro_print) macro_print_step("special form", expr, rewritten);
        comp(rewritten, env, code, tail, pos);
        return;
    }

    if (h == "if") {
        check_arity("if", expr, rest, 2, 3);
        ValuePtr test   = car(rest);
        ValuePtr then_e = car(cdr(rest));
        ValuePtr else_e = is_nil(cdr(cdr(rest))) ? g_nil : car(cdr(cdr(rest)));

        comp(test, env, code, false, pos);
        Instruction sel(tail ? Op::SELR : Op::SEL);
        CodePtr ct = new Code();
        CodePtr cf = new Code();
        comp(then_e, env, ct, tail, pos);
        comp(else_e, env, cf, tail, pos);
        Op term = tail ? Op::RTN : Op::JOIN;
        emit(ct, Instruction(term), pos);
        emit(cf, Instruction(term), pos);
        sel.p1 = ct;
        sel.p2 = cf;
        emit(code, sel, pos);
        return;
    }

    if (h == "begin") {
        comp_body(rest, env, code, tail, pos);
        return;
    }

    if (h == "lambda") {
        check_arity("lambda", expr, rest, 1, 0);
        Instruction i(Op::LDF);
        i.p1 = compile_lambda(car(rest), cdr(rest), env, expr, pos);
        emit(code, i, pos);
        return;
    }

    if (h == "define" || h == "define-macro") {
        bool is_macro = (h == "define-macro");
        std::string_view form = is_macro ? "define-macro" : "define";
        check_arity(form, expr, rest, 1, 0);
        ValuePtr lhs      = car(rest);
        ValuePtr rhs_tail = cdr(rest);
        ValuePtr name;

        if (is_symbol(lhs)) {
            if (is_nil(rhs_tail))
                syntax_error(form, is_macro ? "macro definition needs a transformer expression"
                                            : "variable definition needs a value expression",
                             expr);
            if (!is_nil(cdr(rhs_tail)))
                syntax_error(form, is_macro ? "macro definition takes exactly one transformer"
                                            : "variable definition takes exactly one value",
                             expr);
            name = lhs;
            comp(car(rhs_tail), env, code, false, pos);
        } else if (is_pair(lhs) && is_symbol(car(lhs))) {
            name = car(lhs);
            Instruction i(Op::LDF);
            i.p1 = compile_lambda(cdr(lhs), rhs_tail, env, expr, pos);
            emit(code, i, pos);
        } else {
            syntax_error(form,
                         is_macro
                           ? "expected (define-macro name expr) or "
                             "(define-macro (name . params) body ...)"
                           : "expected (define name expr) or "
                             "(define (name . params) body ...)",
                         expr);
        }

        name_last_closure(code, as_symbol_name(name));
        Instruction d(is_macro ? Op::DEFM : Op::DEF);
        d.p1 = global_cell(view_of(as_symbol_name(name)));
        emit(code, d, pos);
        return;
    }

    if (h == "set!") {
        check_arity("set!", expr, rest, 2, 2);
        ValuePtr target = car(rest);
        if (!is_symbol(target))
            syntax_error("set!", expected_given("the assignment target to be a symbol",
                                                to_string(target)), expr);
        comp(car(cdr(rest)), env, code, false, pos);
        std::string_view name = view_of(as_symbol_name(target));
        std::uint16_t f = 0, idx = 0;
        if (location_of(name, env, f, idx)) {
            Instruction i(Op::LSET);
            i.a = f; i.b = idx;
            emit(code, i, pos);
        } else {
            Instruction i(Op::GSET);
            i.p1 = global_cell(name);
            emit(code, i, pos);
        }
        return;
    }

    // call-with-current-continuation は R5RS の正式名。call/cc と同じに扱う。
    if (h == "call/cc" || h == "call-with-current-continuation") {
        check_arity(h, expr, rest, 1, 1);
        comp(car(rest), env, code, false, pos);
        emit(code, Instruction(tail ? Op::TCALLCC : Op::CALLCC), pos);
        return;
    }

    // (apply f a b ... lst)。引数の個数がコンパイル時に決まらないので、
    // ここだけリストにまとめてから呼ぶ（§4.4.5）。
    if (h == "apply") {
        check_arity("apply", expr, rest, 2, 0);
        ValueVec xs = list_to_vector(rest, "apply");
        for (std::size_t i = 1; i < xs.size(); ++i) comp(xs[i], env, code, false, pos);
        Instruction pack(Op::ARGS_AP);
        pack.a = static_cast<std::uint16_t>(xs.size() - 1);
        emit(code, pack, pos);
        comp(xs[0], env, code, false, pos);
        emit(code, Instruction(tail ? Op::TAPPLY : Op::APPLY), pos);
        return;
    }

    ValuePtr expanded = macro_expand_1_expr(expr);
    if (expanded != expr) {
        if (g_macro_print) macro_print_step("macro", expr, expanded);
        comp(expanded, env, code, tail, pos);
        return;
    }

    // 通常の適用。**引数を左から順に評価してから演算子**（scheme12 と同じ順）。
    // スタックは下から arg0 .. arg_{n-1} callee になる。
    ValueVec args = list_to_vector(rest, "application");
    for (ValuePtr a : args) comp(a, env, code, false, pos);
    comp(head, env, code, false, pos);

    // **直前が LDF なら「作ってすぐ呼んで捨てる」閉包**である。演算子は最後に
    // 評価されるので、APP の直前の命令は必ず被呼び出しを作る命令であり、
    // それが LDF なら、その閉包はこの APP に消費されて即座に死ぬ。
    // let / let* / letrec / 名前つき let / do はすべて ((lambda ...) ...) に
    // 展開されるので、印を付けないと **let 1回につき閉包を1個確保する**
    // ことになる（12日目の決定54。実測で閉包確保の 99.9996% がこれだった）。
    if (!code->ins.empty() && code->ins.back().op == Op::LDF)
        code->ins.back().b = 1;

    Instruction call(tail ? Op::TAPP : Op::APP);
    call.a = static_cast<std::uint16_t>(args.size());
    emit(code, call, pos);
}

static void comp_body(ValuePtr body, const CompileEnv& env, CodePtr code, bool tail,
                      SourcePos inherited) {
    ValueVec forms = list_to_vector(body, "body");
    if (forms.empty()) {
        Instruction i(Op::LDC);
        i.p1 = g_nil;
        emit(code, i, inherited);
        return;
    }
    for (std::size_t i = 0; i < forms.size(); ++i) {
        bool last = (i + 1 == forms.size());
        SourcePos fpos = nearest_pos(forms[i]);
        if (!fpos.known()) fpos = inherited;
        comp(forms[i], env, code, last && tail, inherited);
        if (!last) emit(code, Instruction(Op::POP), fpos);
    }
}

static CodePtr compile_top(ValuePtr expr, SourcePos pos = SourcePos{}) {
    CodePtr code = new Code();
    if (!pos.known()) pos = nearest_pos(expr);
    comp(expr, CompileEnv{}, code, false, pos);
    emit(code, Instruction(Op::STOP), pos);
    return code;
}

// ===========================================================================
// セクション 10. VM
// ===========================================================================
//
// 機械の状態は dev_memo.md §4.4.2 のとおり:
//   S = 単一の連続スタック（呼び出しでコピーしない。床を base で覚える）
//   E = フレームの連結リスト（1呼び出し = 1確保）
//   C = Code* + pc
//   D = 連続配列（{c, pc, env, base} の POD。確保しない）
//
// scheme12 は呼び出しごとに s と e を丸ごとコピーしていた（環境の深さに比例）。
// ここが最大の違い。

static bool g_trace_mode = false;

// 引数の並び（スタック上の [argp, argp+n) 区間）から環境フレームを作る。
// エラー本文で手続きを名指しするときの呼び名。define で名前が付いていれば
// それを使い、無名なら表示形（#<closure:(x y)>）で代用する。表示形そのものは
// §2.1 で凍結されていて名前を含められないので、ここで別に持ち出す。
static std::string callee_name(const Closure* clo) {
    if (!clo->tmpl->name.empty()) return to_std(clo->tmpl->name);
    return to_string(const_cast<Closure*>(clo));
}

static Env* make_frame(Closure* clo, ValuePtr* argv, std::size_t n, const SourcePos& pos) {
    const Template* t = clo->tmpl;
    std::size_t fixed = t->params.size();

    if (!t->rest ? (n != fixed) : (n < fixed)) {
        error_at(pos, callee_name(clo) + ": wrong number of arguments" +
                      arity_detail(fixed, t->rest ? 0 : fixed, n));
    }

    // 余りのリストを先に作る（確保は GC を動かしうるが、argv はスタック上で生きている）
    ValuePtr rest_list = g_nil;
    if (t->rest) {
        for (std::size_t i = n; i > fixed; --i) rest_list = make_pair(argv[i - 1], rest_list);
    }

    Env* frame = env_extend(clo->env, fixed + (t->rest ? 1 : 0));
    for (std::size_t i = 0; i < fixed; ++i) frame->vals[i] = argv[i];
    if (t->rest) frame->vals[fixed] = rest_list;
    return frame;
}

struct VM {
    ValueVec         stack;
    GcVec<DumpEntry> dump;
    Env*             env  = nullptr;
    Closure*         scratch = new Closure(nullptr, nullptr);   // 決定54
    CodePtr          c    = nullptr;
    std::uint32_t    pc   = 0;
    std::uint32_t    base = 0;
    long             steps = 0;

    void trace_step(const Instruction& ins) {
        std::string out = "\n==== Step " + std::to_string(steps++) + " ====\n";
        out += "PC: " + std::to_string(pc - 1) + "\n";
        out += "Instruction: ";
        disassemble_ins(out, ins, 0, 0);
        out += "Stack: ";
        if (stack.size() <= base) {
            out += "(empty)\n";
        } else {
            out += "\n";
            std::size_t shown = 0;
            for (std::size_t i = stack.size(); i > base && shown < 5; --i, ++shown)
                out += "  [" + std::to_string(shown) + "] " + to_string(stack[i - 1]) + "\n";
            if (stack.size() - base > 5)
                out += "  ... (" + std::to_string(stack.size() - base - 5) + " more)\n";
        }
        out += "Environment: ";
        if (!env) {
            out += "(empty)\n";
        } else {
            std::size_t depth = 0;
            for (Env* e = env; e; e = e->next) ++depth;
            out += std::to_string(depth) + " frame(s)\n";
            std::size_t i = 0;
            for (Env* e = env; e && i < 3; e = e->next, ++i)
                out += "  Frame[" + std::to_string(i) + "]: " +
                       std::to_string(e->size) + " binding(s)\n";
        }
        out += "Dump: " + std::to_string(dump.size()) + " frame(s)\n";
        std::fputs(out.c_str(), stdout);
        std::fflush(stdout);
    }

    // callee はスタックから降ろし済み。引数は [argp, argp+n) にある。
    // 位置の無いエラーに、どこを指させるか（決定43）。
    //
    // 素直には「いま実行中の命令」だが、それが起動時ライブラリの中だと
    // `(sqrt -4)` が lib13.scm の 107 行目を指す。**利用者はその行を
    // 書いていないので直しようがない。** そこで、実行中の位置が
    // ライブラリの中なら、ダンプを内側から外へ辿って**最初に見つかる
    // ライブラリ外の呼び出し位置**を選ぶ。全部ライブラリなら諦めて
    // 実行中の位置を返す（ライブラリ同士の呼び出しなど）。
    //
    // ダンプの pc は「戻り先」なので、呼び出した命令は c->ins[pc-1]。
    SourcePos blame_pos(const SourcePos& current) const {
        if (!pos_in_library(current)) return current;
        for (std::size_t i = dump.size(); i > 0; --i) {
            const DumpEntry& d = dump[i - 1];
            if (!d.c || d.pc == 0 || d.pc > d.c->ins.size()) continue;
            const SourcePos& p = d.c->ins[d.pc - 1].pos;
            if (p.known() && !pos_in_library(p)) return p;
        }
        return current;
    }

    // いまの入れ子が継続の捕捉時と同じか（決定59）
    static bool winds_match(const GcVec<WindEntry>& want) {
        if (g_winds.size() != want.size()) return false;
        for (std::size_t i = 0; i < want.size(); ++i)
            if (g_winds[i].id != want[i].id) return false;
        return true;
    }

    // 継続を起動する前に走らせる命令列を組み立てる（決定59）。
    //
    //   出る枠の after を内側から、入る枠の before を外側から呼び、
    //   最後にこの継続をもう一度起動する。二度目は入れ子が一致しているので
    //   上の速い道に入る。**コンパイラは通さない。** 命令列は
    //   「定数を積んで呼んで捨てる」の繰り返しでしかないので直接組む。
    static CodePtr build_rewind_code(Continuation* k, ValuePtr v, const SourcePos& pos) {
        std::size_t common = 0;
        while (common < g_winds.size() && common < k->winds.size() &&
               g_winds[common].id == k->winds[common].id) ++common;

        CodePtr code = new Code();
        auto call_thunk = [&](ValuePtr thunk) {
            Instruction ldc(Op::LDC); ldc.p1 = thunk; emit(code, ldc, pos);
            Instruction app(Op::APP); app.a = 0;      emit(code, app, pos);
            emit(code, Instruction(Op::POP), pos);
        };
        for (std::size_t i = g_winds.size(); i > common; --i)   // 出る: 内側から
            call_thunk(g_winds[i - 1].after);
        for (std::size_t i = common; i < k->winds.size(); ++i)  // 入る: 外側から
            call_thunk(k->winds[i].before);

        // 入れ子は先に合わせておく。after / before の中でさらに脱出された
        // ときに、同じ枠をもう一度巻き戻さないため。
        g_winds.assign(k->winds.begin(), k->winds.end());

        Instruction lv(Op::LDC); lv.p1 = v; emit(code, lv, pos);
        Instruction lk(Op::LDC); lk.p1 = k; emit(code, lk, pos);
        Instruction ap(Op::APP); ap.a = 1;  emit(code, ap, pos);
        return code;
    }

    void do_call(ValuePtr callee, std::size_t argp, std::size_t n,
                 const Instruction& ins, bool tail) {
        switch (tag_of(callee)) {
            case Tag::Primitive: {
                ValuePtr out = static_cast<Primitive*>(callee)->fn(stack.data() + argp, n);
                stack.resize(argp);
                stack.push_back(out ? out : g_nil);
                return;
            }
            case Tag::Continuation: {
                ValuePtr v = (n == 0) ? g_nil : stack[argp];
                Continuation* k = static_cast<Continuation*>(callee);

                // dynamic-wind の入れ子が捕捉時と違うなら、**先に差分の
                // after / before を走らせる**（決定59）。走らせ終えたら
                // この継続をもう一度起動するだけの命令列へ跳ぶ。
                if (!winds_match(k->winds)) {
                    c  = build_rewind_code(k, v, ins.pos);
                    pc = 0;
                    return;
                }

                // 起動は機械の状態をまるごと差し替える。捕捉したスナップショットは
                // 何度でも起動できるよう、move ではなく copy する。
                stack = k->stack;
                dump  = k->dump;
                stack.push_back(v);
                env = k->env; c = k->c; pc = k->pc; base = k->base;
                return;
            }
            case Tag::Closure: {
                Closure* clo = static_cast<Closure*>(callee);
                Env* frame = make_frame(clo, stack.data() + argp, n, ins.pos);
                if (!tail) {
                    dump.push_back(DumpEntry{c, pc, env, base});
                    stack.resize(argp);
                    base = static_cast<std::uint32_t>(argp);
                } else {
                    stack.resize(base);       // 末尾呼び出し。自分の床まで捨てる
                }
                env = frame;
                c   = clo->tmpl->body;
                pc  = 0;
                return;
            }
            default:
                error_at(ins.pos, "attempt to call a non-procedure" +
                                  expected_given("a procedure", to_string(callee)));
        }
    }

    ValuePtr run() {
        for (;;) {
            if (!c || pc >= c->ins.size()) internal_error(SourcePos{}, "code exhausted without reaching STOP");
            const Instruction& ins = c->ins[pc++];
            if (g_trace_mode) trace_step(ins);

            // 位置を持たないエラー（プリミティブが投げたものなど）に、いま実行中の
            // 命令の位置を貼る。テーブル方式の例外なので、投げない限り実行時の
            // 負担は無い。§1.4 の優先順位3（ソース位置つきエラー）はここで完結する。
            try {
            switch (ins.op) {
                case Op::LD: {
                    Env* f = env_at(env, ins.a);
                    if (!f || ins.b >= f->size) internal_error(ins.pos, "LD: local variable index out of range");
                    stack.push_back(f->vals[ins.b]);
                    break;
                }
                case Op::LDC:
                    stack.push_back(ins.constant());
                    break;
                case Op::LDG: {
                    GlobalCell* cell = ins.cell();
                    if (!cell->value)
                        error_at(ins.pos, "unbound variable: " + to_std(cell->name) +
                                          detail("note", "it is referenced here but never "
                                                         "defined by define or set!"));
                    stack.push_back(cell->value);
                    break;
                }
                // b==1 は「この閉包は直後の APP に消費されて即座に死ぬ」印
                // （決定54）。**呼び出し規約のスクラッチであって Scheme の値では
                // ない。** argv がスタック上の区間を借りているのと同じ約束で、
                // 保持してはならない。LDF と APP の間では何も走らないので、
                // 捕捉も再入も起こり得ず、VM に1つあれば足りる。
                case Op::LDF:
                    if (ins.b) {
                        scratch->tmpl = ins.tmpl();
                        scratch->env  = env;
                        stack.push_back(scratch);
                    } else {
                        stack.push_back(new Closure(ins.tmpl(), env));
                    }
                    break;

                case Op::APP:
                case Op::TAPP: {
                    std::size_t n = ins.a;
                    if (stack.size() < n + 1) internal_error(ins.pos, "APP: operand stack underflow");
                    ValuePtr callee = stack.back();
                    stack.pop_back();
                    do_call(callee, stack.size() - n, n, ins, ins.op == Op::TAPP);
                    break;
                }

                // (apply f a b ... lst) の引数まとめ。ここだけリストを作る。
                case Op::ARGS_AP: {
                    std::size_t k = ins.a;
                    if (k == 0 || stack.size() < k) internal_error(ins.pos, "ARGS-AP: operand stack underflow");
                    ValuePtr tail = stack.back();
                    stack.pop_back();
                    ValueVec acc = list_to_vector(tail, "apply");
                    ValueVec head_args(stack.end() - static_cast<long>(k - 1), stack.end());
                    stack.resize(stack.size() - (k - 1));
                    head_args.insert(head_args.end(), acc.begin(), acc.end());
                    stack.push_back(list_from(head_args));
                    break;
                }
                case Op::APPLY:
                case Op::TAPPLY: {
                    if (stack.size() < 2) internal_error(ins.pos, "APPLY: operand stack underflow");
                    ValuePtr callee = stack.back(); stack.pop_back();
                    ValuePtr lst    = stack.back(); stack.pop_back();
                    ValueVec args = list_to_vector(lst, "apply");
                    std::size_t argp = stack.size();
                    for (ValuePtr a : args) stack.push_back(a);
                    do_call(callee, argp, args.size(), ins, ins.op == Op::TAPPLY);
                    break;
                }

                case Op::RTN: {
                    ValuePtr r = stack.empty() ? g_nil : stack.back();
                    if (dump.empty()) return r;
                    DumpEntry back = dump.back();
                    dump.pop_back();
                    stack.resize(base);
                    stack.push_back(r);
                    c = back.c; pc = back.pc; env = back.env; base = back.base;
                    break;
                }

                case Op::SEL:
                case Op::SELR: {
                    if (stack.empty()) internal_error(ins.pos, "SEL: operand stack underflow");
                    ValuePtr cond = stack.back();
                    stack.pop_back();
                    CodePtr next = is_true(cond) ? ins.code_true() : ins.code_false();
                    if (!next) internal_error(ins.pos, "SEL: missing branch");
                    if (ins.op == Op::SEL) dump.push_back(DumpEntry{c, pc, env, base});
                    c = next; pc = 0;
                    break;
                }
                case Op::JOIN: {
                    if (dump.empty()) internal_error(ins.pos, "JOIN: dump underflow");
                    DumpEntry back = dump.back();
                    dump.pop_back();
                    c = back.c; pc = back.pc;   // env と base は変わっていない
                    break;
                }

                case Op::POP:
                    if (stack.empty()) internal_error(ins.pos, "POP: operand stack underflow");
                    stack.pop_back();
                    break;

                case Op::DEF: {
                    if (stack.empty()) internal_error(ins.pos, "DEF: operand stack underflow");
                    GlobalCell* cell = ins.cell();
                    cell->value = stack.back();
                    stack.back() = make_symbol(view_of(cell->name));   // define はシンボルを返す
                    break;
                }
                case Op::DEFM: {
                    if (stack.empty()) internal_error(ins.pos, "DEFM: operand stack underflow");
                    GlobalCell* cell = ins.cell();
                    ValuePtr v = stack.back();
                    cell->macro = v;
                    cell->value = has_tag(v, Tag::Closure)
                                    ? static_cast<ValuePtr>(new Macro(static_cast<Closure*>(v)))
                                    : v;
                    stack.back() = make_symbol(view_of(cell->name));
                    break;
                }
                case Op::LSET: {
                    if (stack.empty()) internal_error(ins.pos, "LSET: operand stack underflow");
                    Env* f = env_at(env, ins.a);
                    if (!f || ins.b >= f->size) internal_error(ins.pos, "LSET: local variable index out of range");
                    f->vals[ins.b] = stack.back();   // set! は代入した値を返す
                    break;
                }
                case Op::GSET:
                    if (stack.empty()) internal_error(ins.pos, "GSET: operand stack underflow");
                    ins.cell()->value = stack.back();
                    break;

                case Op::CALLCC:
                case Op::TCALLCC: {
                    if (stack.empty()) internal_error(ins.pos, "call/cc: operand stack underflow");
                    ValuePtr proc = stack.back();
                    stack.pop_back();

                    Continuation* k = new Continuation();
                    k->stack = stack;      // コピー（何度でも起動できるように）
                    k->dump  = dump;
                    k->winds.assign(g_winds.begin(), g_winds.end());   // 決定59
                    k->c = c; k->pc = pc; k->env = env; k->base = base;

                    std::size_t argp = stack.size();
                    stack.push_back(k);
                    do_call(proc, argp, 1, ins, ins.op == Op::TCALLCC);
                    break;
                }

                case Op::STOP:
                    return stack.empty() ? g_nil : stack.back();
            }
            } catch (SchemeError& e) {
                if (!e.pos.known()) {
                    SourcePos p = blame_pos(ins.pos);
                    if (p.known()) throw SchemeError(e.what(), p);
                }
                throw;
            }
        }
    }
};

// マクロ変換子を1回まわす（コンパイラから呼ばれる）。
static ValuePtr apply_callable(ValuePtr proc, ValuePtr* argv, std::size_t argc) {
    if (has_tag(proc, Tag::Primitive)) {
        ValuePtr out = static_cast<Primitive*>(proc)->fn(argv, argc);
        return out ? out : g_nil;
    }
    if (!has_tag(proc, Tag::Closure))
        error_here("macro transformer is not callable" +
                   expected_given("a procedure", to_string(proc)));

    Closure* clo = static_cast<Closure*>(proc);
    VM vm;
    vm.env  = make_frame(clo, argv, argc, SourcePos{});
    vm.c    = clo->tmpl->body;
    vm.pc   = 0;
    vm.base = 0;
    return vm.run();
}

static ValuePtr eval_top(ValuePtr expr, SourcePos pos = SourcePos{}) {
    VM vm;
    vm.c  = compile_top(expr, pos);
    vm.pc = 0;
    return vm.run();
}

// ===========================================================================
// セクション 11. プリミティブ
// ===========================================================================
//
// プリミティブは関数ポインタ `ValuePtr(*)(ValuePtr* argv, std::size_t argc)`。
// argv は **VM のスタック上の区間をそのまま指す**（詰め替えない。§4.4）。
// したがってプリミティブは argv を書き換えてはならず、保持してもいけない。
//
// 整数は即値 fixnum とヒープ Bignum の2表現。**bignum 演算の結果が fixnum に
// 収まったら必ず fixnum に落とす**（make_int がやる）。これを破ると §2.2 の
// 「数値は値比較」が表現によってぶれる（dev_memo.md §9）。

// プリミティブのエラーは3種類しかない。それぞれ専用の入口を持たせ、
// 文面を各プリミティブに組み立てさせない（§4.2 / 決定33）。
//
//   prim_error       見出しだけで足りるもの（division by zero など）
//   prim_type_error  型が違う      → expected: / given:
//   prim_range_error 範囲外の添字  → expected: / given:
//
// 位置は付けない。VM が実行中の命令の位置を後から埋める（セクション10 の
// catch）。プリミティブ側は「誰が何を期待したか」だけを知っていればよい。

[[noreturn]] static void prim_error(std::string_view who, std::string_view what) {
    error_here(std::string(who) + ": " + std::string(what));
}

[[noreturn]] static void prim_type_error(std::string_view who, std::string_view expected,
                                         ValuePtr got) {
    error_here(std::string(who) + ": wrong type of argument" +
               expected_given(expected, to_string(got)));
}

// 添字が [0, limit) に入らなかった。what は冠詞込みの語（"an element index"）、
// subject は入れ物の呼び名（"vector"）。limit == 0（空の入れ物）に
// 「0 から -1 まで」と言わせないために、空のときは別の文にする。
[[noreturn]] static void prim_range_error(std::string_view who, std::string_view what,
                                          std::string_view subject,
                                          long long got, long long limit) {
    std::string want = (limit <= 0)
        ? (std::string(what) + ", but the " + std::string(subject) + " is empty")
        : (std::string(what) + " from 0 to " + std::to_string(limit - 1));
    error_here(std::string(who) + ": index out of range" +
               expected_given(want, std::to_string(got)));
}

static void need_args(const char* who, std::size_t argc, std::size_t lo, std::size_t hi) {
    if (argc < lo || (hi != 0 && argc > hi))
        error_here(std::string(who) + ": wrong number of arguments" +
                   arity_detail(lo, hi, argc));
}

static BigInt num_of(ValuePtr v, const char* who) {
    if (is_fixnum(v)) return BigInt(static_cast<long long>(fixnum_value(v)));
    if (has_tag(v, Tag::Bignum)) return static_cast<Bignum*>(v)->v;
    prim_type_error(who, "an integer", v);
}

// 数を倍精度にする。**整数から実数への変換はここ1箇所だけ**（20日目の決定101）。
// 大きすぎる整数は ±inf になる。例外にはしない（決定88 で「桁は落ちる」と
// 書いたのと同じ性質で、Boost の convert_to<double> がそう振る舞う。実測）。
static double to_double(ValuePtr v, const char* who) {
    if (is_fixnum(v)) return static_cast<double>(fixnum_value(v));
    if (is_flonum(v)) return static_cast<Flonum*>(v)->v;
    if (has_tag(v, Tag::Bignum)) return static_cast<Bignum*>(v)->v.convert_to<double>();
    prim_type_error(who, "a number", v);
}

// 引数のどれかが不正確か。**速い道（全部 fixnum）はここを通らない**（決定91）。
// 落ちた先で1度だけ呼び、bignum の道と double の道を選び分ける。
//
// **数でないものはこの1回の走査で弾く。** そうしないと、選ばれた先の
// num_of が `expected: an integer` と言ってしまう。算術は実数も受けるので、
// それは嘘になる（20日目の決定102）。
static bool any_inexact(ValuePtr* a, std::size_t from, std::size_t n, const char* who) {
    bool inexact = false;
    for (std::size_t i = from; i < n; ++i) {
        if (is_flonum(a[i]))         { inexact = true; continue; }
        if (!is_exact_int(a[i]))     prim_type_error(who, "a number", a[i]);
    }
    return inexact;
}

static long long ll_of(ValuePtr v, const char* who) {
    if (is_fixnum(v)) return static_cast<long long>(fixnum_value(v));
    BigInt n = num_of(v, who);
    if (n > BigInt(LLONG_MAX) || n < BigInt(LLONG_MIN))
        prim_error(who, "integer too large to be used here" +
                        detail("given", to_string(v)));
    return static_cast<long long>(n);
}

static GcString& str_of(ValuePtr v, const char* who) {
    if (!is_string(v)) prim_type_error(who, "a string", v);
    return static_cast<Str*>(v)->s;
}

static Vector* vec_of(ValuePtr v, const char* who) {
    if (!is_vector(v)) prim_type_error(who, "a vector", v);
    return static_cast<Vector*>(v);
}

static Port* port_of(ValuePtr v, const char* who, bool want_input) {
    if (!has_tag(v, Tag::Port)) prim_type_error(who, "a port", v);
    Port* p = static_cast<Port*>(v);
    if (p->is_closed || !p->fp || p->is_input != want_input)
        prim_type_error(who, want_input ? "an open input port" : "an open output port", v);
    return p;
}

// --- 算術（fixnum の速い道と bignum の遅い道） -----------------------------

static ValuePtr prim_add(ValuePtr* a, std::size_t n) {
    std::intptr_t acc = 0;
    std::size_t i = 0;
    for (; i < n; ++i) {
        if (!is_fixnum(a[i])) break;
        std::intptr_t r;
        if (__builtin_add_overflow(acc, fixnum_value(a[i]), &r)) break;
        if (r > FIXNUM_MAX || r < FIXNUM_MIN) break;
        acc = r;
    }
    if (i == n) return make_fixnum(acc);
    if (any_inexact(a, i, n, "+")) {             // 不正確が混ざる（決定91）
        double d = static_cast<double>(acc);
        for (; i < n; ++i) d += to_double(a[i], "+");
        return make_flonum(d);
    }
    BigInt big(static_cast<long long>(acc));
    for (; i < n; ++i) big += num_of(a[i], "+");
    return make_int(big);
}

static ValuePtr prim_sub(ValuePtr* a, std::size_t n) {
    need_args("-", n, 1, 0);
    if (n == 1) {
        if (is_fixnum(a[0])) {
            std::intptr_t v = fixnum_value(a[0]);
            if (v != FIXNUM_MIN) return make_fixnum(-v);
        }
        if (is_flonum(a[0])) return make_flonum(-static_cast<Flonum*>(a[0])->v);
        return make_int(BigInt(-num_of(a[0], "-")));
    }
    if (is_fixnum(a[0])) {
        std::intptr_t acc = fixnum_value(a[0]);
        std::size_t i = 1;
        for (; i < n; ++i) {
            if (!is_fixnum(a[i])) break;
            std::intptr_t r;
            if (__builtin_sub_overflow(acc, fixnum_value(a[i]), &r)) break;
            if (r > FIXNUM_MAX || r < FIXNUM_MIN) break;
            acc = r;
        }
        if (i == n) return make_fixnum(acc);
        if (any_inexact(a, i, n, "-")) {         // 不正確が混ざる（決定91）
            double d = static_cast<double>(acc);
            for (; i < n; ++i) d -= to_double(a[i], "-");
            return make_flonum(d);
        }
        BigInt big(static_cast<long long>(acc));
        for (; i < n; ++i) big -= num_of(a[i], "-");
        return make_int(big);
    }
    if (any_inexact(a, 0, n, "-")) {
        double d = to_double(a[0], "-");
        for (std::size_t i = 1; i < n; ++i) d -= to_double(a[i], "-");
        return make_flonum(d);
    }
    BigInt big = num_of(a[0], "-");
    for (std::size_t i = 1; i < n; ++i) big -= num_of(a[i], "-");
    return make_int(big);
}

static ValuePtr prim_mul(ValuePtr* a, std::size_t n) {
    std::intptr_t acc = 1;
    std::size_t i = 0;
    for (; i < n; ++i) {
        if (!is_fixnum(a[i])) break;
        std::intptr_t r;
        if (__builtin_mul_overflow(acc, fixnum_value(a[i]), &r)) break;
        if (r > FIXNUM_MAX || r < FIXNUM_MIN) break;
        acc = r;
    }
    if (i == n) return make_fixnum(acc);
    if (any_inexact(a, i, n, "*")) {             // 不正確が混ざる（決定91）
        double d = static_cast<double>(acc);
        for (; i < n; ++i) d *= to_double(a[i], "*");
        return make_flonum(d);
    }
    BigInt big(static_cast<long long>(acc));
    for (; i < n; ++i) big *= num_of(a[i], "*");
    return make_int(big);
}

// (/ x) は**引数の型によらずエラー**（型で arity を変えない。§2.3）。
//
// **引数がすべて正確な整数なら0方向への切り捨て**（quotient 相当）。これは
// 18日目に利用者が3案から選んだ仕様で、R5RS から最も遠い1点である（決定82）。
// 実数が一つでも混ざれば実数除算になり、0除算も IEEE 754 に従って ±inf / nan を
// 返す（例外にしない。§2.3）。**`(/ 1 3)` は 0、`(/ 1.0 3)` は 0.333...**。
static ValuePtr prim_div(ValuePtr* a, std::size_t n) {
    if (n < 2)
        prim_error("/", "requires at least 2 arguments (single-argument reciprocal is not "
                        "supported; use (/ 1 x) instead)");
    if (any_inexact(a, 0, n, "/")) {
        double d = to_double(a[0], "/");
        for (std::size_t i = 1; i < n; ++i) d /= to_double(a[i], "/");
        return make_flonum(d);
    }
    BigInt acc = num_of(a[0], "/");
    for (std::size_t i = 1; i < n; ++i) {
        BigInt d = num_of(a[i], "/");
        if (d == 0) prim_error("/", "division by zero" + detail("given", to_string(a[i])));
        acc /= d;
    }
    return make_int(acc);
}

// 剰余の符号は除数に一致する（§2.3）
static ValuePtr prim_modulo(ValuePtr* a, std::size_t n) {
    need_args("modulo", n, 2, 2);
    BigInt x = num_of(a[0], "modulo");
    BigInt y = num_of(a[1], "modulo");
    if (y == 0) prim_error("modulo", "division by zero" + detail("given", to_string(a[1])));
    BigInt r = x % y;
    if ((r < 0 && y > 0) || (r > 0 && y < 0)) r += y;
    return make_int(r);
}

// 比較の結果は**4状態**（18日目の決定87）。NaN は「どの比較も偽」でなければ
// ならないが、-1 / 0 / 1 の3状態ではそれを表せない（`c == 0` と `c < 0` と
// `c > 0` を同時に偽にする整数は存在しない）。**これは実装の都合ではなく仕様**で、
// `(< +nan.0 1)` も `(>= +nan.0 1)` も FALSE になる。
enum class Cmp { LT, EQ, GT, Unordered };

static Cmp num_cmp(ValuePtr x, ValuePtr y, const char* who) {
    if (is_fixnum(x) && is_fixnum(y)) {          // 速い道。ここは触らない（決定91）
        std::intptr_t a = fixnum_value(x), b = fixnum_value(y);
        return (a < b) ? Cmp::LT : (a > b) ? Cmp::GT : Cmp::EQ;
    }
    if (is_flonum(x) || is_flonum(y)) {          // 混合比較は倍精度に寄せる（決定88）
        double a = to_double(x, who), b = to_double(y, who);
        if (a < b) return Cmp::LT;
        if (a > b) return Cmp::GT;
        if (a == b) return Cmp::EQ;
        return Cmp::Unordered;                   // NaN が混ざった
    }
    BigInt a = num_of(x, who), b = num_of(y, who);
    return (a < b) ? Cmp::LT : (a > b) ? Cmp::GT : Cmp::EQ;
}

// 引数が2個未満なら TRUE（scheme12 と同じ）。
// **`<=` を「`<` の否定」で書かないこと**（NaN でひっくり返る。決定87）。
#define DEFINE_NUM_CMP(fn, name, test)                                      \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {                        \
        if (n < 2) return g_true;                                           \
        for (std::size_t i = 1; i < n; ++i) {                               \
            Cmp c = num_cmp(a[i - 1], a[i], name);                          \
            if (!(test)) return g_false;                                    \
        }                                                                   \
        return g_true;                                                      \
    }
DEFINE_NUM_CMP(prim_num_eq, "=",  c == Cmp::EQ)
DEFINE_NUM_CMP(prim_lt,     "<",  c == Cmp::LT)
DEFINE_NUM_CMP(prim_gt,     ">",  c == Cmp::GT)
DEFINE_NUM_CMP(prim_le,     "<=", c == Cmp::LT || c == Cmp::EQ)
DEFINE_NUM_CMP(prim_ge,     ">=", c == Cmp::GT || c == Cmp::EQ)
#undef DEFINE_NUM_CMP

// --- 正確さと丸め（20日目。決定93 の表のうち double が要るもの）------------
//
// どれも値の**表現**を見るので Scheme では書けない。`lib13.scm` にあった
// 同名の定義（「整数しか無いので」を前提にしたもの）は消した。**横に足さない。**

static ValuePtr prim_exactp(ValuePtr* a, std::size_t n) {
    need_args("exact?", n, 1, 1);
    if (!is_number(a[0])) prim_type_error("exact?", "a number", a[0]);
    return make_bool(is_exact_int(a[0]));
}
static ValuePtr prim_inexactp(ValuePtr* a, std::size_t n) {
    need_args("inexact?", n, 1, 1);
    if (!is_number(a[0])) prim_type_error("inexact?", "a number", a[0]);
    return make_bool(is_flonum(a[0]));
}

// 実数が整数かどうか。**+inf.0 と +nan.0 は整数ではない**（floor が自分自身に
// 等しくなってしまうので、有限かどうかを先に見る）。
static bool flonum_is_integer(double d) { return std::isfinite(d) && d == std::floor(d); }

// R5RS の型述語。**数でなければ偽**（エラーにしない。型述語だから）。
static ValuePtr prim_integerp(ValuePtr* a, std::size_t n) {
    need_args("integer?", n, 1, 1);
    if (is_exact_int(a[0])) return g_true;
    if (is_flonum(a[0])) return make_bool(flonum_is_integer(static_cast<Flonum*>(a[0])->v));
    return g_false;
}
// 有限な実数はすべて有理数（2進小数だから）。無限大と非数はそうではない。
static ValuePtr prim_rationalp(ValuePtr* a, std::size_t n) {
    need_args("rational?", n, 1, 1);
    if (is_exact_int(a[0])) return g_true;
    if (is_flonum(a[0])) return make_bool(std::isfinite(static_cast<Flonum*>(a[0])->v));
    return g_false;
}
// 複素数は無いので、数ならば実数であり複素数でもある（§2.2）
static ValuePtr prim_realp(ValuePtr* a, std::size_t n) {
    need_args("real?", n, 1, 1);
    return make_bool(is_number(a[0]));
}
static ValuePtr prim_complexp(ValuePtr* a, std::size_t n) {
    need_args("complex?", n, 1, 1);
    return make_bool(is_number(a[0]));
}

static ValuePtr prim_exact_to_inexact(ValuePtr* a, std::size_t n) {
    need_args("exact->inexact", n, 1, 1);
    if (!is_number(a[0])) prim_type_error("exact->inexact", "a number", a[0]);
    if (is_flonum(a[0])) return a[0];
    return make_flonum(to_double(a[0], "exact->inexact"));
}

// **有理数が無いので、整数値でない実数は正確な数にできない**（決定93）。
// 黙って切り捨てず、値そのものの範囲の誤りとして知らせる（§4.2 の見出し）。
static ValuePtr prim_inexact_to_exact(ValuePtr* a, std::size_t n) {
    need_args("inexact->exact", n, 1, 1);
    if (!is_number(a[0])) prim_type_error("inexact->exact", "a number", a[0]);
    if (is_exact_int(a[0])) return a[0];
    double d = static_cast<Flonum*>(a[0])->v;
    if (!flonum_is_integer(d))
        prim_error("inexact->exact",
                   "argument out of range" +
                   expected_given("a real with no fractional part (there are no rationals)",
                                  to_string(a[0])));
    return make_int(BigInt(d));
}

// R5RS: 正確な整数はそのまま、実数は**実数のまま**返す（決定85。正確さを
// またいで正規化しない）。`round` は**偶数丸め**で、(round 2.5) は 2.0、
// (round 3.5) は 4.0 になる（std::nearbyint の既定の丸めがそれ）。
#define DEFINE_ROUND(fn, name, op)                                          \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {                        \
        need_args(name, n, 1, 1);                                           \
        if (is_exact_int(a[0])) return a[0];                                \
        if (!is_flonum(a[0])) prim_type_error(name, "a number", a[0]);      \
        return make_flonum(op(static_cast<Flonum*>(a[0])->v));              \
    }
DEFINE_ROUND(prim_floor,    "floor",    std::floor)
DEFINE_ROUND(prim_ceiling,  "ceiling",  std::ceil)
DEFINE_ROUND(prim_truncate, "truncate", std::trunc)
DEFINE_ROUND(prim_round,    "round",    std::nearbyint)
#undef DEFINE_ROUND

// --- 超越関数（21日目。決定93 の表の残り）----------------------------------
//
// 倍精度でしか意味を持たないので C++ に置く。**引数は数なら何でも受け、
// 結果は必ず不正確**（R5RS は正確な答えが出る場合でも不正確を返すことを許す）。
//
// **定義域の外でも例外にしない。** IEEE 754 に従って `+nan.0` / `-inf.0` を返す
// （`(/ 1.0 0.0)` を `+inf.0` にしたのと同じ扱い。§2.3）。
//   (log 0) → -inf.0   (log -1) → +nan.0   (asin 2) → +nan.0
//
// `%sqrt` と `%expt` は**内部用**（決定60 の `%`）。`lib13.scm` の
// `sqrt` / `expt` が「正確な道」を先に試し、外れたときだけここへ落とす。
#define DEFINE_MATH1(fn, name, op)                                          \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {                        \
        need_args(name, n, 1, 1);                                           \
        return make_flonum(op(to_double(a[0], name)));                      \
    }
DEFINE_MATH1(prim_sqrt_raw, "%sqrt", std::sqrt)
DEFINE_MATH1(prim_exp,      "exp",   std::exp)
DEFINE_MATH1(prim_log,      "log",   std::log)
DEFINE_MATH1(prim_sin,      "sin",   std::sin)
DEFINE_MATH1(prim_cos,      "cos",   std::cos)
DEFINE_MATH1(prim_tan,      "tan",   std::tan)
DEFINE_MATH1(prim_asin,     "asin",  std::asin)
DEFINE_MATH1(prim_acos,     "acos",  std::acos)
#undef DEFINE_MATH1

static ValuePtr prim_expt_raw(ValuePtr* a, std::size_t n) {
    need_args("%expt", n, 2, 2);
    return make_flonum(std::pow(to_double(a[0], "%expt"), to_double(a[1], "%expt")));
}

// R5RS の atan は1引数と2引数の両方を持つ。2引数のほうは象限を保つ atan2。
static ValuePtr prim_atan(ValuePtr* a, std::size_t n) {
    need_args("atan", n, 1, 2);
    double y = to_double(a[0], "atan");
    if (n == 1) return make_flonum(std::atan(y));
    return make_flonum(std::atan2(y, to_double(a[1], "atan")));
}

// --- ペアとリスト ----------------------------------------------------------

static ValuePtr prim_cons(ValuePtr* a, std::size_t n) {
    need_args("cons", n, 2, 2);
    return make_pair(a[0], a[1]);
}
static ValuePtr prim_car(ValuePtr* a, std::size_t n) {
    need_args("car", n, 1, 1);
    if (!is_pair(a[0])) prim_type_error("car", "a pair", a[0]);
    return as_pair(a[0])->car;
}
static ValuePtr prim_cdr(ValuePtr* a, std::size_t n) {
    need_args("cdr", n, 1, 1);
    if (!is_pair(a[0])) prim_type_error("cdr", "a pair", a[0]);
    return as_pair(a[0])->cdr;
}
static ValuePtr prim_set_car(ValuePtr* a, std::size_t n) {
    need_args("set-car!", n, 2, 2);
    if (!is_pair(a[0])) prim_type_error("set-car!", "a pair", a[0]);
    as_pair(a[0])->car = a[1];
    return a[1];
}
static ValuePtr prim_set_cdr(ValuePtr* a, std::size_t n) {
    need_args("set-cdr!", n, 2, 2);
    if (!is_pair(a[0])) prim_type_error("set-cdr!", "a pair", a[0]);
    as_pair(a[0])->cdr = a[1];
    return a[1];
}

// c[ad]+r の合成。path は内側から適用する順（"ad" なら (car (cdr x))）
static ValuePtr cxr(ValuePtr v, const char* path, const char* who) {
    for (const char* p = path + std::strlen(path); p != path; --p) {
        char op = *(p - 1);
        if (!is_pair(v)) prim_type_error(who, "a pair", v);
        v = (op == 'a') ? as_pair(v)->car : as_pair(v)->cdr;
    }
    return v;
}
#define DEFINE_CXR(fn, name, path)                                    \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {                  \
        need_args(name, n, 1, 1);                                     \
        return cxr(a[0], path, name);                                 \
    }
DEFINE_CXR(prim_caar,  "caar",  "aa")
DEFINE_CXR(prim_cadr,  "cadr",  "ad")
DEFINE_CXR(prim_cdar,  "cdar",  "da")
DEFINE_CXR(prim_cddr,  "cddr",  "dd")
DEFINE_CXR(prim_caddr, "caddr", "add")
DEFINE_CXR(prim_cdddr, "cdddr", "ddd")
#undef DEFINE_CXR

// 真リストか（Floyd の2ポインタ法。循環していれば偽）
static bool is_proper_list(ValuePtr v) {
    ValuePtr slow = v, fast = v;
    for (;;) {
        if (is_nil(fast)) return true;
        if (!is_pair(fast)) return false;
        fast = as_pair(fast)->cdr;
        if (is_nil(fast)) return true;
        if (!is_pair(fast)) return false;
        fast = as_pair(fast)->cdr;
        slow = as_pair(slow)->cdr;
        if (slow == fast) return false;
    }
}

static ValuePtr prim_list(ValuePtr* a, std::size_t n) {
    ValuePtr out = g_nil;
    for (std::size_t i = n; i > 0; --i) out = make_pair(a[i - 1], out);
    return out;
}
static ValuePtr prim_length(ValuePtr* a, std::size_t n) {
    need_args("length", n, 1, 1);
    if (!is_proper_list(a[0])) prim_type_error("length", "a proper list", a[0]);
    long long k = 0;
    for (ValuePtr ls = a[0]; !is_nil(ls); ls = as_pair(ls)->cdr) ++k;
    return make_int(k);
}
static ValuePtr prim_listp(ValuePtr* a, std::size_t n) {
    need_args("list?", n, 1, 1);
    return make_bool(is_proper_list(a[0]));
}
static ValuePtr prim_append(ValuePtr* a, std::size_t n) {
    if (n == 0) return g_nil;
    ValueVec elems;
    for (std::size_t i = 0; i + 1 < n; ++i) {          // 最後の1つ以外を平らに集める
        for (ValuePtr ls = a[i]; !is_nil(ls); ls = as_pair(ls)->cdr) {
            if (!is_pair(ls)) prim_type_error("append", "a proper list", a[i]);
            elems.push_back(as_pair(ls)->car);
        }
    }
    ValuePtr out = a[n - 1];                            // 最後はそのまま尻尾になる
    for (std::size_t i = elems.size(); i > 0; --i) out = make_pair(elems[i - 1], out);
    return out;
}

// 数の eqv?。**正確さが一致して初めて真**（18日目の決定86）。
// (= 1 1.0) は真だが (eqv? 1 1.0) は偽。実数どうしはビット列で比べるので
// (eqv? 0.0 -0.0) は偽、(eqv? +nan.0 +nan.0) は真になる（`=` はどちらも逆）。
//
// **`=` のほうを直すのは20日目**（決定95）。ここを19日目に入れたのは、
// is_number() に実数が入った時点で num_cmp が実数を型エラーで弾いてしまい、
// (eqv? 1.5 1.5) が真偽ではなくエラーになるため（決定97）。
static bool eqv_number(ValuePtr x, ValuePtr y) {
    if (is_flonum(x) || is_flonum(y)) {
        if (!is_flonum(x) || !is_flonum(y)) return false;      // 正確さが違う
        double a = static_cast<Flonum*>(x)->v;
        double b = static_cast<Flonum*>(y)->v;
        return std::memcmp(&a, &b, sizeof a) == 0;
    }
    return num_cmp(x, y, "eqv?") == Cmp::EQ;
}

// eq? / eqv?: 数値は値比較、シンボルは名前比較、それ以外はポインタ比較（§2.2）。
// scheme13 ではシンボルはインターンされ fixnum は即値なので、多くはポインタ比較で済む。
static bool eqv_values(ValuePtr x, ValuePtr y) {
    if (x == y) return true;
    if (is_number(x) && is_number(y)) return eqv_number(x, y);
    return false;
}
static ValuePtr prim_eq(ValuePtr* a, std::size_t n) {
    if (n != 2) return g_false;
    return make_bool(eqv_values(a[0], a[1]));
}

// equal?: cdr 方向はループ、car 方向のみ再帰（§4.3）。
// 循環は「対応関係の記録」で扱い、走査後にバックトラックで外す。
using PairMap = std::unordered_map<const void*, const void*, std::hash<const void*>,
                                   std::equal_to<const void*>,
                                   gc_allocator<std::pair<const void* const, const void*> > >;

static bool equal_values(ValuePtr a, ValuePtr b, PairMap& seen) {
    if (a == b) return true;
    if (is_number(a) && is_number(b)) return eqv_number(a, b);   // 数は eqv? と同じ（R5RS）
    if (tag_of(a) != tag_of(b)) return false;

    switch (tag_of(a)) {
        case Tag::String:
            return static_cast<Str*>(a)->s == static_cast<Str*>(b)->s;
        case Tag::Vector: {
            Vector* va = static_cast<Vector*>(a);
            Vector* vb = static_cast<Vector*>(b);
            auto it = seen.find(va);
            if (it != seen.end()) return it->second == vb;
            if (va->elems.size() != vb->elems.size()) return false;
            seen[va] = vb;
            for (std::size_t i = 0; i < va->elems.size(); ++i) {
                if (!equal_values(va->elems[i], vb->elems[i], seen)) { seen.erase(va); return false; }
            }
            seen.erase(va);
            return true;
        }
        case Tag::Pair: {
            GcVec<const void*> path;
            bool result;
            for (;;) {
                auto it = seen.find(a);
                if (it != seen.end()) { result = (it->second == b); break; }
                seen[a] = b;
                path.push_back(a);
                if (!equal_values(as_pair(a)->car, as_pair(b)->car, seen)) { result = false; break; }
                a = as_pair(a)->cdr;
                b = as_pair(b)->cdr;
                if (a == b)                 { result = true;  break; }
                if (is_pair(a) != is_pair(b)) { result = false; break; }
                if (!is_pair(a))            { result = equal_values(a, b, seen); break; }
            }
            for (const void* k : path) seen.erase(k);
            return result;
        }
        default:
            return false;
    }
}
static ValuePtr prim_equal(ValuePtr* a, std::size_t n) {
    if (n != 2) return g_false;
    PairMap seen;
    return make_bool(equal_values(a[0], a[1], seen));
}

static ValuePtr prim_memq(ValuePtr* a, std::size_t n) {
    need_args("memq", n, 2, 2);
    for (ValuePtr ls = a[1]; !is_nil(ls); ls = as_pair(ls)->cdr) {
        if (!is_pair(ls)) prim_type_error("memq", "a proper list", a[1]);
        if (eqv_values(as_pair(ls)->car, a[0])) return ls;
    }
    return g_false;
}
static ValuePtr prim_assq(ValuePtr* a, std::size_t n) {
    need_args("assq", n, 2, 2);
    for (ValuePtr ls = a[1]; !is_nil(ls); ls = as_pair(ls)->cdr) {
        if (!is_pair(ls)) prim_type_error("assq", "a proper association list", a[1]);
        ValuePtr e = as_pair(ls)->car;
        if (is_pair(e) && eqv_values(as_pair(e)->car, a[0])) return e;
    }
    return g_false;
}

// --- 述語 ------------------------------------------------------------------

#define DEFINE_PRED(fn, name, expr)                          \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {         \
        need_args(name, n, 1, 1);                            \
        ValuePtr v = a[0]; (void)v;                          \
        return make_bool(expr);                              \
    }
DEFINE_PRED(prim_nullp,    "null?",     is_nil(v))
DEFINE_PRED(prim_pairp,    "pair?",     is_pair(v))
DEFINE_PRED(prim_atomp,    "atom?",     !is_pair(v))
DEFINE_PRED(prim_numberp,  "number?",   is_number(v))
DEFINE_PRED(prim_stringp,  "string?",   is_string(v))
DEFINE_PRED(prim_symbolp,  "symbol?",   is_symbol(v))
DEFINE_PRED(prim_vectorp,  "vector?",   is_vector(v))
DEFINE_PRED(prim_booleanp, "boolean?",  has_tag(v, Tag::Boolean))
DEFINE_PRED(prim_eofp,     "eof-object?", v == g_eof)
DEFINE_PRED(prim_not,      "not",       is_false(v))
DEFINE_PRED(prim_procedurep, "procedure?",
            has_tag(v, Tag::Primitive) || has_tag(v, Tag::Closure) ||
            has_tag(v, Tag::Continuation))
// 閉じたポートもポートである（R5RS）。向きは閉じても変わらない。
DEFINE_PRED(prim_input_portp,  "input-port?",
            has_tag(v, Tag::Port) && static_cast<Port*>(v)->is_input)
DEFINE_PRED(prim_output_portp, "output-port?",
            has_tag(v, Tag::Port) && !static_cast<Port*>(v)->is_input)
#undef DEFINE_PRED

// --- 文字列（文字型は無い。文字は長さ1の文字列。§2.2） --------------------

static ValuePtr prim_string_length(ValuePtr* a, std::size_t n) {
    need_args("string-length", n, 1, 1);
    return make_int(static_cast<long long>(str_of(a[0], "string-length").size()));
}
static ValuePtr prim_string_ref(ValuePtr* a, std::size_t n) {
    need_args("string-ref", n, 2, 2);
    GcString& s = str_of(a[0], "string-ref");
    long long i = ll_of(a[1], "string-ref");
    if (i < 0 || static_cast<std::size_t>(i) >= s.size())
        prim_range_error("string-ref", "a character index", "string", i,
                         static_cast<long long>(s.size()));
    return make_string(std::string_view(&s[static_cast<std::size_t>(i)], 1));
}
static ValuePtr prim_string_set(ValuePtr* a, std::size_t n) {
    need_args("string-set!", n, 3, 3);
    GcString& s  = str_of(a[0], "string-set!");
    GcString& ch = str_of(a[2], "string-set!");
    if (ch.empty()) prim_type_error("string-set!", "a character (a string of length 1)", a[2]);
    long long i = ll_of(a[1], "string-set!");
    if (i < 0 || static_cast<std::size_t>(i) >= s.size())
        prim_range_error("string-set!", "a character index", "string", i,
                         static_cast<long long>(s.size()));
    s[static_cast<std::size_t>(i)] = ch[0];
    return make_symbol(":undef");
}
static ValuePtr prim_make_string(ValuePtr* a, std::size_t n) {
    need_args("make-string", n, 1, 2);
    long long len = ll_of(a[0], "make-string");
    if (len < 0 || len > 1000000)
        prim_error("make-string", "argument out of range" +
                   expected_given("a length from 0 to 1000000", std::to_string(len)));
    char fill = ' ';
    if (n == 2) {
        GcString& f = str_of(a[1], "make-string");
        if (f.empty()) prim_type_error("make-string", "a character (a string of length 1)", a[1]);
        fill = f[0];
    }
    return make_string(std::string(static_cast<std::size_t>(len), fill));
}
static ValuePtr prim_string_append(ValuePtr* a, std::size_t n) {
    GcString out;
    for (std::size_t i = 0; i < n; ++i) out += str_of(a[i], "string-append");
    return new Str(out);
}
static ValuePtr prim_substring(ValuePtr* a, std::size_t n) {
    need_args("substring", n, 2, 3);
    GcString& s = str_of(a[0], "substring");
    long long from = ll_of(a[1], "substring");
    if (from < 0 || static_cast<std::size_t>(from) > s.size())
        prim_error("substring", "index out of range" +
                   expected_given("a start index from 0 to " + std::to_string(s.size()),
                                  std::to_string(from)));
    long long to = static_cast<long long>(s.size());
    if (n == 3) {
        to = ll_of(a[2], "substring");
        if (to < from || static_cast<std::size_t>(to) > s.size())
            prim_error("substring", "index out of range" +
                       expected_given("an end index from " + std::to_string(from) +
                                      " to " + std::to_string(s.size()),
                                      std::to_string(to)));
    }
    return new Str(s.substr(static_cast<std::size_t>(from),
                            static_cast<std::size_t>(to - from)));
}
#define DEFINE_STRCMP(fn, name, test)                                  \
    static ValuePtr fn(ValuePtr* a, std::size_t n) {                   \
        need_args(name, n, 2, 2);                                      \
        int c = str_of(a[0], name).compare(str_of(a[1], name));        \
        return make_bool(test);                                        \
    }
DEFINE_STRCMP(prim_string_eq, "string=?",  c == 0)
DEFINE_STRCMP(prim_string_lt, "string<?",  c <  0)
DEFINE_STRCMP(prim_string_gt, "string>?",  c >  0)
DEFINE_STRCMP(prim_string_le, "string<=?", c <= 0)
DEFINE_STRCMP(prim_string_ge, "string>=?", c >= 0)
#undef DEFINE_STRCMP

static ValuePtr prim_char_to_integer(ValuePtr* a, std::size_t n) {
    need_args("char->integer", n, 1, 1);
    GcString& s = str_of(a[0], "char->integer");
    if (s.empty()) prim_type_error("char->integer", "a character (a string of length 1)", a[0]);
    return make_int(static_cast<long long>(static_cast<unsigned char>(s[0])));
}
static ValuePtr prim_integer_to_char(ValuePtr* a, std::size_t n) {
    need_args("integer->char", n, 1, 1);
    long long v = ll_of(a[0], "integer->char");
    if (v < 0 || v > 127)
        prim_error("integer->char", "argument out of range" +
                   expected_given("an ASCII code from 0 to 127", std::to_string(v)));
    char c = static_cast<char>(v);
    return make_string(std::string_view(&c, 1));
}
static ValuePtr prim_string_to_list(ValuePtr* a, std::size_t n) {
    need_args("string->list", n, 1, 1);
    GcString& s = str_of(a[0], "string->list");
    ValuePtr out = g_nil;
    for (std::size_t i = s.size(); i > 0; --i)
        out = make_pair(make_string(std::string_view(&s[i - 1], 1)), out);
    return out;
}
static ValuePtr prim_list_to_string(ValuePtr* a, std::size_t n) {
    need_args("list->string", n, 1, 1);
    GcString out;
    for (ValuePtr ls = a[0]; !is_nil(ls); ls = as_pair(ls)->cdr) {
        if (!is_pair(ls)) prim_type_error("list->string", "a proper list", a[0]);
        GcString& ch = str_of(as_pair(ls)->car, "list->string");
        if (!ch.empty()) out += ch[0];
    }
    return new Str(out);
}
static ValuePtr prim_symbol_to_string(ValuePtr* a, std::size_t n) {
    need_args("symbol->string", n, 1, 1);
    return new Str(as_symbol_name(a[0]));
}
static ValuePtr prim_string_to_symbol(ValuePtr* a, std::size_t n) {
    need_args("string->symbol", n, 1, 1);
    return make_symbol(view_of(str_of(a[0], "string->symbol")));
}
// write と同じ関数で書く（書式を2つ持たない。18日目の決定90）
static ValuePtr prim_number_to_string(ValuePtr* a, std::size_t n) {
    need_args("number->string", n, 1, 1);
    if (!is_number(a[0])) prim_type_error("number->string", "a number", a[0]);
    return make_string(to_string(a[0]));
}
// リーダと同じ判定を使う（数の文法を2つ持たない。決定89）
static ValuePtr prim_string_to_number(ValuePtr* a, std::size_t n) {
    need_args("string->number", n, 1, 1);
    ValuePtr num = nullptr;
    if (!parse_number(view_of(str_of(a[0], "string->number")), &num)) return g_false;
    return num;
}

// --- ベクタ ----------------------------------------------------------------

static ValuePtr prim_make_vector(ValuePtr* a, std::size_t n) {
    need_args("make-vector", n, 1, 2);
    long long len = ll_of(a[0], "make-vector");
    if (len < 0)
        prim_error("make-vector", "argument out of range" +
                   expected_given("a length of 0 or more", std::to_string(len)));
    return make_vector(static_cast<std::size_t>(len), n == 2 ? a[1] : g_nil);
}
static ValuePtr prim_vector(ValuePtr* a, std::size_t n) {
    Vector* v = new Vector();
    v->elems.assign(a, a + n);
    return v;
}
static ValuePtr prim_vector_length(ValuePtr* a, std::size_t n) {
    need_args("vector-length", n, 1, 1);
    return make_int(static_cast<long long>(vec_of(a[0], "vector-length")->elems.size()));
}
static ValuePtr prim_vector_ref(ValuePtr* a, std::size_t n) {
    need_args("vector-ref", n, 2, 2);
    Vector* v = vec_of(a[0], "vector-ref");
    long long i = ll_of(a[1], "vector-ref");
    if (i < 0 || static_cast<std::size_t>(i) >= v->elems.size())
        prim_range_error("vector-ref", "an element index", "vector", i,
                         static_cast<long long>(v->elems.size()));
    return v->elems[static_cast<std::size_t>(i)];
}
static ValuePtr prim_vector_set(ValuePtr* a, std::size_t n) {
    need_args("vector-set!", n, 3, 3);
    Vector* v = vec_of(a[0], "vector-set!");
    long long i = ll_of(a[1], "vector-set!");
    if (i < 0 || static_cast<std::size_t>(i) >= v->elems.size())
        prim_range_error("vector-set!", "an element index", "vector", i,
                         static_cast<long long>(v->elems.size()));
    v->elems[static_cast<std::size_t>(i)] = a[2];
    return make_symbol(":undef");
}
static ValuePtr prim_vector_to_list(ValuePtr* a, std::size_t n) {
    need_args("vector->list", n, 1, 1);
    Vector* v = vec_of(a[0], "vector->list");
    ValuePtr out = g_nil;
    for (std::size_t i = v->elems.size(); i > 0; --i) out = make_pair(v->elems[i - 1], out);
    return out;
}
static ValuePtr prim_list_to_vector(ValuePtr* a, std::size_t n) {
    need_args("list->vector", n, 1, 1);
    Vector* v = new Vector();
    v->elems = list_to_vector(a[0], "list->vector");
    return v;
}

// --- 入出力 ----------------------------------------------------------------
//
// ファイルを開く関数は EMFILE/ENFILE で GC してから1回だけやり直す。
// GC_gcollect() だけではファイナライザがキューに積まれるだけで実行されない
// ので、GC_invoke_finalizers() まで呼ぶ（§1.6-5）。

static std::FILE* fopen_with_gc_retry(const char* path, const char* mode) {
    errno = 0;
    std::FILE* fp = std::fopen(path, mode);
    if (fp) return fp;
    if (errno != EMFILE && errno != ENFILE) return nullptr;
    GC_gcollect();
    GC_invoke_finalizers();
    return std::fopen(path, mode);
}

// 省略された port 引数は標準ポートで埋める。**stdout を直に書かず、
// (current-output-port) が返すのと同じ値から取る**（10日目の決定48）。
static std::FILE* out_port_or_default(ValuePtr* a, std::size_t n, std::size_t idx,
                                      const char* who) {
    if (n <= idx) return static_cast<Port*>(g_stdout_port)->fp;
    return port_of(a[idx], who, false)->fp;
}
static Port* in_port_or_default(ValuePtr* a, std::size_t n, std::size_t idx,
                                const char* who) {
    if (n <= idx) return static_cast<Port*>(g_stdin_port);
    return port_of(a[idx], who, true);
}

// 「いま読んでも待たされないか」。R5RS の契約は「TRUE なら次の read-char は
// 待たない」の一方向だけなので、判断が付かないときは FALSE 側へ倒すのが安全。
#if defined(_WIN32)
static bool fp_has_input(std::FILE*) { return true; }
#else
static bool fp_has_input(std::FILE* fp) {
    if (!fp) return false;
    struct pollfd pfd;
    pfd.fd      = fileno(fp);
    pfd.events  = POLLIN;
    pfd.revents = 0;
    return ::poll(&pfd, 1, 0) > 0;   // 通常ファイルは常に読める（EOF も「待たない」）
}
#endif

static ValuePtr prim_display(ValuePtr* a, std::size_t n) {
    need_args("display", n, 1, 2);
    std::FILE* out = out_port_or_default(a, n, 1, "display");
    std::string t = to_display_string(a[0]);
    std::fwrite(t.data(), 1, t.size(), out);
    return a[0];
}
static ValuePtr prim_write(ValuePtr* a, std::size_t n) {
    need_args("write", n, 1, 2);
    std::FILE* out = out_port_or_default(a, n, 1, "write");
    std::string t = to_string(a[0]);
    std::fwrite(t.data(), 1, t.size(), out);
    return a[0];
}
static ValuePtr prim_newline(ValuePtr* a, std::size_t n) {
    need_args("newline", n, 0, 1);
    std::FILE* out = out_port_or_default(a, n, 0, "newline");
    std::fputc('\n', out);
    return g_nil;
}
static ValuePtr prim_write_char(ValuePtr* a, std::size_t n) {
    need_args("write-char", n, 1, 2);
    GcString& s = str_of(a[0], "write-char");
    if (s.empty()) prim_type_error("write-char", "a character (a string of length 1)", a[0]);
    std::FILE* out = out_port_or_default(a, n, 1, "write-char");
    std::fputc(s[0], out);
    return a[0];
}
static ValuePtr prim_open_input_file(ValuePtr* a, std::size_t n) {
    need_args("open-input-file", n, 1, 1);
    std::string path = to_std(str_of(a[0], "open-input-file"));
    std::FILE* fp = fopen_with_gc_retry(path.c_str(), "rb");
    if (!fp) prim_error("open-input-file", "cannot open file for reading" +
                        detail("given", path));
    return make_port(fp, true);
}
static ValuePtr prim_open_output_file(ValuePtr* a, std::size_t n) {
    need_args("open-output-file", n, 1, 1);
    std::string path = to_std(str_of(a[0], "open-output-file"));
    std::FILE* fp = fopen_with_gc_retry(path.c_str(), "wb");
    if (!fp) prim_error("open-output-file", "cannot open file for writing" +
                        detail("given", path));
    return make_port(fp, false);
}
static ValuePtr prim_close_port(ValuePtr* a, std::size_t n) {
    need_args("close-port", n, 1, 1);
    if (!has_tag(a[0], Tag::Port)) prim_type_error("close-port", "a port", a[0]);
    static_cast<Port*>(a[0])->close();
    return g_true;
}
static ValuePtr prim_read_char(ValuePtr* a, std::size_t n) {
    need_args("read-char", n, 0, 1);
    int c = in_port_or_default(a, n, 0, "read-char")->get_char();
    if (c == EOF) return g_eof;
    char ch = static_cast<char>(c);
    return make_string(std::string_view(&ch, 1));
}
static ValuePtr prim_peek_char(ValuePtr* a, std::size_t n) {
    need_args("peek-char", n, 0, 1);
    int c = in_port_or_default(a, n, 0, "peek-char")->peek_char();
    if (c == EOF) return g_eof;
    char ch = static_cast<char>(c);
    return make_string(std::string_view(&ch, 1));
}
static ValuePtr prim_char_readyp(ValuePtr* a, std::size_t n) {
    need_args("char-ready?", n, 0, 1);
    Port* p = in_port_or_default(a, n, 0, "char-ready?");
    if (p->has_peek) return g_true;             // 先読み済みなら確実に待たない
    return make_bool(fp_has_input(p->fp));
}
static ValuePtr prim_read_line(ValuePtr* a, std::size_t n) {
    need_args("read-line", n, 0, 1);
    Port* p = in_port_or_default(a, n, 0, "read-line");
    std::string line;
    int c;
    while ((c = p->get_char()) != EOF) {
        if (c == '\n') break;
        if (c == '\r') {
            int next = p->get_char();
            if (next != '\n' && next != EOF) p->unget_char(next);
            break;
        }
        line.push_back(static_cast<char>(c));
    }
    if (c == EOF && line.empty()) return g_eof;
    return make_string(line);
}

// ポートから S 式を1つ読む。括弧の対応で切り出してからリーダに渡す。
static ValuePtr read_one_from_port(Port* p, const char* who) {
    std::string buf;
    int depth = 0;
    bool in_string = false, in_comment = false, seen = false;
    for (;;) {
        int c = p->get_char();
        if (c == EOF) {
            if (!seen) return g_eof;
            break;
        }
        char ch = static_cast<char>(c);
        if (ch == ';' && !in_string) in_comment = true;
        if (ch == '\n') in_comment = false;
        if (in_comment) { buf.push_back(ch); continue; }
        if (ch == '"' && (buf.empty() || buf.back() != '\\')) in_string = !in_string;
        if (!in_string) {
            if (ch == '(')      { ++depth; seen = true; }
            else if (ch == ')') { --depth; }
            else if (!std::isspace(static_cast<unsigned char>(ch))) seen = true;
        }
        buf.push_back(ch);
        if (seen && depth == 0 && !in_string) break;
    }
    std::uint16_t id = source_intern(who, buf);
    Reader r(id);
    ValuePtr v = r.read_expr();
    return v ? v : g_eof;
}

static ValuePtr prim_read_expr(ValuePtr* a, std::size_t n) {
    need_args("read-expr", n, 0, 1);
    return read_one_from_port(in_port_or_default(a, n, 0, "read-expr"), "<read-expr>");
}
static ValuePtr prim_read_from_stdin(ValuePtr* a, std::size_t n) {
    need_args("read", n, 0, 1);
    return read_one_from_port(in_port_or_default(a, n, 0, "read"),
                              n == 1 ? "<read>" : "<stdin>");
}

// (current-input-port) / (current-output-port)。R5RS では**手続き**であって
// 変数ではない。いまはどちらも固定で、with-output-to-file のような
// 差し替えは無い（10日目の決定46）。
static ValuePtr prim_current_input_port(ValuePtr*, std::size_t n) {
    need_args("current-input-port", n, 0, 0);
    return g_stdin_port;
}
static ValuePtr prim_current_output_port(ValuePtr*, std::size_t n) {
    need_args("current-output-port", n, 0, 0);
    return g_stdout_port;
}

// --- 多値と dynamic-wind ---------------------------------------------------
//
// **多値は「1個なら値そのもの、それ以外は Values オブジェクト」**（決定58）。
// VM が返り値を複数運ぶ設計にはしない。call-with-values はこの箱を開けて
// apply するだけなので、lib13.scm 側に Scheme で書ける。
//
// dynamic-wind は lib13.scm に Scheme で書き、C++ 側は入れ子の記録
// （%wind-push / %wind-pop）だけを持つ。巻き戻しは継続の起動側（セクション10）。

static ValuePtr prim_values(ValuePtr* a, std::size_t n) {
    if (n == 1) return a[0];              // 1個なら箱に入れない
    Values* mv = new Values();
    mv->vals.assign(a, a + n);
    return mv;
}
static ValuePtr prim_values_to_list(ValuePtr* a, std::size_t n) {
    need_args("%values->list", n, 1, 1);
    if (!has_tag(a[0], Tag::Values)) return make_pair(a[0], g_nil);   // 1値
    Values* mv = static_cast<Values*>(a[0]);
    ValuePtr out = g_nil;
    for (std::size_t i = mv->vals.size(); i > 0; --i) out = make_pair(mv->vals[i - 1], out);
    return out;
}
static ValuePtr prim_wind_push(ValuePtr* a, std::size_t n) {
    need_args("%wind-push", n, 2, 2);
    g_winds.push_back(WindEntry{a[0], a[1], g_wind_next_id++});
    return g_nil;
}
static ValuePtr prim_wind_pop(ValuePtr*, std::size_t n) {
    need_args("%wind-pop", n, 0, 0);
    if (!g_winds.empty()) g_winds.pop_back();
    return g_nil;
}
// いちばん内側の枠の after。枠が無ければ #f（15日目の決定64）。
// exit が「外へ出る after を内側から順に呼ぶ」ために使う。**呼ぶのは
// Scheme 側**。プリミティブから VM へ再入する経路は作らない（決定59）。
static ValuePtr prim_wind_top_after(ValuePtr*, std::size_t n) {
    need_args("%wind-top-after", n, 0, 0);
    if (g_winds.empty()) return g_false;
    return g_winds.back().after;
}

// --- その他 ----------------------------------------------------------------

// (error message irritant ...) — SRFI-23。**Scheme で書いたライブラリが
// §4.2 の形で報告するための唯一の口。** これが無いと lib13.scm は
// 「car: expected a pair」のような、呼ばれた側の名前が出ないエラーしか
// 出せない（8日目の決定41）。
//
// 見出しは呼ぶ側が決める（`"sqrt: wrong type of argument"` のように
// §4.2 の語彙で書くこと）。irritant は `given:` の詳細行になる。
// 位置は VM が呼び出し命令のものを埋める。
// 名前は prim_raise_error。上の内部ヘルパ prim_error(who, what) と
// 紛らわしくならないよう、あえて命名規則（prim_<名前>）を外している。
static ValuePtr prim_raise_error(ValuePtr* a, std::size_t n) {
    need_args("error", n, 1, 0);
    // 第1引数が文字列なら中身をそのまま見出しにする（引用符を付けない）
    std::string msg = is_string(a[0]) ? to_std(static_cast<Str*>(a[0])->s)
                                      : to_string(a[0]);
    for (std::size_t i = 1; i < n; ++i) msg += detail("given", to_string(a[i]));
    error_here(msg);
}

// (%exit obj) — 終了要求を投げる。**外へ出る dynamic-wind の after は
// lib13.scm の exit が先に走らせてある**ので、ここは終了コードを決めるだけ
// （15日目の決定64）。
//
// 終了コードは R7RS 6.14 に倣う: 引数なしと #t は 0、#f は 1、整数はその値、
// それ以外は 0（R7RS が実装依存としている側）。
//
// 下位8ビットに畳むのは、**親プロセスにはどのみち下位8ビットしか届かない**
// から。畳まずに int へ落とすと C++ 側の値と実際の終了コードが食い違い、
// (exit 256) が 0、(exit -1) が 255 になる理由を追えなくなる。畳んでおけば
// この関数が返す値がそのまま観測される値になる。
static ValuePtr prim_exit_now(ValuePtr* a, std::size_t n) {
    need_args("%exit", n, 0, 1);
    int code = 0;
    if (n == 1) {
        if (is_false(a[0]))       code = 1;
        else if (is_number(a[0])) code = static_cast<int>(ll_of(a[0], "exit") & 0xFF);
    }
    throw SchemeExit{code};
}

static ValuePtr prim_gensym(ValuePtr* a, std::size_t n) {
    if (n >= 1 && is_string(a[0])) return make_gensym(view_of(str_of(a[0], "gensym")));
    return make_gensym("g");
}

static std::mt19937_64 g_random_engine;
static bool            g_random_ready = false;
static void random_init() {
    if (g_random_ready) return;
    std::random_device rd;
    g_random_engine.seed(rd());
    g_random_ready = true;
}
static ValuePtr prim_random(ValuePtr* a, std::size_t n) {
    need_args("random", n, 1, 1);
    random_init();
    long long hi = ll_of(a[0], "random");
    if (hi <= 0)
        prim_error("random", "argument out of range" +
                   expected_given("a positive upper bound", std::to_string(hi)));
    std::uniform_int_distribution<long long> dist(0, hi - 1);
    return make_int(dist(g_random_engine));
}
static ValuePtr prim_random_seed(ValuePtr* a, std::size_t n) {
    need_args("random-seed", n, 1, 1);
    g_random_engine.seed(static_cast<std::uint64_t>(ll_of(a[0], "random-seed")));
    g_random_ready = true;
    return g_nil;
}

// --- 原典のテスト機構（test-start / test-end） -----------------------------
//
// 原典 micro_Scheme8.lisp の REPL は、この2つに挟まれた区間で **式を1つ評価する
// ごとに次の S 式を期待値として読み、照合する**（micro_scheme8_notes.md §6.1）。
// scheme12 はこれを `LDC #t` にする無視扱いにしたため機構が失われ、
// test-case6.scm は「裸の A で必ず落ちるファイル」になっていた。
//
// 照合そのものはファイルを読み進める側（セクション12 の load_from_path）が行う。
// ここはスイッチと集計だけを持つ。

static bool g_test_mode  = false;
static long g_test_total = 0;
static long g_test_pass  = 0;
static long g_test_ng    = 0;

static ValuePtr prim_test_start(ValuePtr*, std::size_t) {
    g_test_mode  = true;
    g_test_total = g_test_pass = g_test_ng = 0;
    return g_true;      // 原典は ldc *test-mode-flag*（= T）を積む
}
static ValuePtr prim_test_end(ValuePtr*, std::size_t) {
    g_test_mode = false;
    std::printf("\n( total: %ld  pass: %ld  NG: %ld )\n",
                g_test_total, g_test_pass, g_test_ng);
    return g_nil;       // 原典は ldc *test-mode-flag*（= NIL）を積む
}

static ValuePtr prim_gc_collect(ValuePtr*, std::size_t) {
    GC_gcollect();
    return g_nil;
}
static ValuePtr prim_gc_heap_size(ValuePtr*, std::size_t) {
    return make_int(static_cast<long long>(GC_get_heap_size()));
}
static ValuePtr prim_gc_free_bytes(ValuePtr*, std::size_t) {
    return make_int(static_cast<long long>(GC_get_free_bytes()));
}

// --- デバッグ機能（§1.5: 一級市民） ---------------------------------------

static ValuePtr prim_trace_on(ValuePtr*, std::size_t) {
    g_trace_mode = true;
    std::printf("Trace mode: ON\n");
    return make_symbol(":trace-on");
}
// (macro-print) — 原典と同じ**切り替え**で、切り替えた後の値を返す
// （原典は `(list* 'ldc *macro-print-flag* code)`）。名前も返り値も原典に
// 合わせるのは、`test-start` / `test-end` を復活させたときと同じ判断
// （決定29・77）。scheme13 流の `-on` / `-off` の対にはしない。
static ValuePtr prim_macro_print(ValuePtr*, std::size_t n) {
    need_args("macro-print", n, 0, 0);
    g_macro_print = !g_macro_print;
    std::printf("Macro expansion trace: %s\n", g_macro_print ? "ON" : "OFF");
    return make_bool(g_macro_print);
}
static ValuePtr prim_trace_off(ValuePtr*, std::size_t) {
    g_trace_mode = false;
    std::printf("Trace mode: OFF\n");
    return make_symbol(":trace-off");
}
static ValuePtr prim_compile_show(ValuePtr* a, std::size_t n) {
    need_args("compile", n, 1, 1);
    std::printf("\n=== Compiled Code ===\n%s=====================\n",
                disassemble(compile_top(a[0])).c_str());
    return make_symbol(":compiled");
}
static ValuePtr prim_disassemble(ValuePtr* a, std::size_t n) {
    need_args("disassemble", n, 1, 1);
    ValuePtr v = a[0];
    if (has_tag(v, Tag::Macro)) {
        std::printf("\n=== Macro Transformer ===\n");
        v = static_cast<Macro*>(v)->transformer;
    }
    if (!has_tag(v, Tag::Closure)) {
        std::printf("Not a closure or macro: %s\n", to_string(v).c_str());
        return make_symbol(":not-disassemblable");
    }
    Closure* clo = static_cast<Closure*>(v);
    std::string params;
    write_params(params, clo->tmpl);
    std::size_t depth = 0;
    for (Env* e = clo->env; e; e = e->next) ++depth;
    std::printf("\n=== Disassembly ===\nParameters: %s\nBody:\n%sEnvironment: %zu frame(s)\n"
                "===================\n",
                params.c_str(), disassemble(clo->tmpl->body).c_str(), depth);
    return make_symbol(":disassembled");
}
// --- 展開の観察（7日目。§8 の4番目 / micro_scheme8_notes.md §6.2）-----------
//
// 原典 micro_Scheme8.lisp にあって scheme12 で失われていた道具。展開器と
// コンパイラは既に持っているので、**外に出すだけ**で入る。
//
// 1段の順序は **コンパイラと同じ**にする（セクション8 の comp を参照）。
// 特殊形式の書き換えが先、ユーザマクロが後。ここを違えると、この道具で
// 見た展開と実際にコンパイルされる展開がずれて、道具の意味が無くなる。
static ValuePtr expand_one_step(ValuePtr form) {
    ValuePtr out = expand_form_1(form);
    if (out != form) return out;
    return macro_expand_1_expr(form);
}

static ValuePtr prim_macroexpand_1(ValuePtr* a, std::size_t n) {
    need_args("macroexpand-1", n, 1, 1);
    return expand_one_step(a[0]);
}

// 動かなくなるまで**外側だけ**を繰り返し展開する（CL の macroexpand と同じ。
// 部分式へは降りない）。自分自身を作り直すマクロで止まらなくなるのを防ぐため
// 上限を置く。上限は「人が書いた展開の段数」としては十分に大きく、
// 暴走を見つけるには十分に小さい値。
static ValuePtr prim_macroexpand(ValuePtr* a, std::size_t n) {
    need_args("macroexpand", n, 1, 1);
    ValuePtr form = a[0];
    for (int steps = 0; steps < 1000; ++steps) {
        ValuePtr out = expand_one_step(form);
        if (out == form) return form;
        form = out;
    }
    prim_error("macroexpand", "expansion did not terminate" +
               detail("note", "the outermost form still expands after 1000 steps; "
                              "a macro is probably expanding into itself"));
}

static ValuePtr prim_globals(ValuePtr*, std::size_t) {
    RootVec<std::string_view> names;
    for (auto& kv : g_globals) if (kv.second->value) names.push_back(kv.first);
    std::sort(names.begin(), names.end());
    std::printf("\n=== Global Variables ===\n");
    for (std::string_view nm : names) {
        ValuePtr val = g_globals[nm]->value;
        std::string shown;
        switch (tag_of(val)) {
            case Tag::Closure: shown = "#<closure>"; break;
            case Tag::Macro:   shown = "#<macro>";   break;
            default:           shown = to_string(val); break;
        }
        std::printf("%.*s : %s\n", static_cast<int>(nm.size()), nm.data(), shown.c_str());
    }
    std::printf("========================\n");
    return make_symbol(":globals-listed");
}
static ValuePtr prim_macros(ValuePtr*, std::size_t) {
    RootVec<std::string_view> names;
    for (auto& kv : g_globals) if (kv.second->macro) names.push_back(kv.first);
    std::sort(names.begin(), names.end());
    std::printf("\n=== Macros ===\n");
    for (std::string_view nm : names)
        std::printf("%.*s\n", static_cast<int>(nm.size()), nm.data());
    std::printf("==============\n");
    return make_symbol(":macros-listed");
}
static ValuePtr prim_help(ValuePtr*, std::size_t) {
    std::printf(R"(
=== scheme13 Debug Commands ===

NOTE: This implementation notes:
  - (/ x) single-argument division is NOT supported (use (/ 1 x) or avoid)
  - eq? and eqv? both perform value comparison on numbers
  - Square brackets [] are NOT supported (use parentheses only)
  - Characters are represented as length-1 strings
  - EOF is a dedicated object type (not a symbol)

Basic evaluation:
  expr                    Evaluate expression

Inspection:
  (globals)              List all global variables
  (macros)               List all macros

Compilation:
  (compile expr)         Compile and show bytecode
  (disassemble closure)  Show closure internals

Expansion:
  (macroexpand-1 'form)  Expand the form one step, as the compiler would
  (macroexpand 'form)    Expand the outermost form until it stops changing

Tracing:
  (trace-on)            Enable VM step-by-step trace
  (trace-off)           Disable trace
  (macro-print)         Toggle tracing of macro/special-form expansion

Leaving:
  (exit)                Quit; (exit n) sets the exit status
  (quit)                Same as (exit)
  Ctrl-D                Quit (end of input)

================================
)");
    return make_symbol(":help");
}

static ValuePtr load_from_path(const std::string& path);
static ValuePtr prim_load(ValuePtr* a, std::size_t n) {
    need_args("load", n, 1, 1);
    return load_from_path(to_std(str_of(a[0], "load")));
}

// --- 登録 ------------------------------------------------------------------

static void init_globals() {
    global_define("true",  g_true);
    global_define("false", g_false);
    global_define("nil",   g_nil);
    global_define("TRUE",  g_true);
    global_define("FALSE", g_false);
    global_define("NIL",   g_nil);
    global_define("T",     g_true);
    global_define(":undef", make_symbol(":undef"));
    global_define("eof-object", g_eof);

    // 特殊形式は「値としては特殊形式オブジェクト」。(procedure? call/cc) は FALSE（§2.7）
    for (const char* nm : {"quote", "if", "lambda", "define", "define-macro", "set!",
                           "call/cc", "call-with-current-continuation", "apply", "begin",
                           "let", "let*", "letrec", "and", "or", "cond", "case", "do",
                           "quasiquote"})
        global_define(nm, make_special_form(nm));

    struct Entry { const char* name; PrimitiveFn fn; };
    static const Entry table[] = {
        {"+", prim_add}, {"-", prim_sub}, {"*", prim_mul}, {"/", prim_div},
        {"modulo", prim_modulo},
        {"=", prim_num_eq}, {"<", prim_lt}, {">", prim_gt},
        {"<=", prim_le}, {">=", prim_ge},

        {"exact?", prim_exactp}, {"inexact?", prim_inexactp},
        {"integer?", prim_integerp}, {"rational?", prim_rationalp},
        {"real?", prim_realp}, {"complex?", prim_complexp},
        {"exact->inexact", prim_exact_to_inexact},
        {"inexact->exact", prim_inexact_to_exact},
        {"floor", prim_floor}, {"ceiling", prim_ceiling},
        {"truncate", prim_truncate}, {"round", prim_round},
        {"%sqrt", prim_sqrt_raw}, {"%expt", prim_expt_raw},
        {"exp", prim_exp}, {"log", prim_log},
        {"sin", prim_sin}, {"cos", prim_cos}, {"tan", prim_tan},
        {"asin", prim_asin}, {"acos", prim_acos}, {"atan", prim_atan},

        {"cons", prim_cons}, {"car", prim_car}, {"cdr", prim_cdr},
        {"set-car!", prim_set_car}, {"set-cdr!", prim_set_cdr},
        {"caar", prim_caar}, {"cadr", prim_cadr}, {"cdar", prim_cdar},
        {"cddr", prim_cddr}, {"caddr", prim_caddr}, {"cdddr", prim_cdddr},
        {"list", prim_list}, {"length", prim_length}, {"append", prim_append},
        {"list?", prim_listp}, {"memq", prim_memq}, {"memv", prim_memq},
        {"assq", prim_assq},

        {"eq?", prim_eq}, {"eqv?", prim_eq}, {"equal?", prim_equal},
        {"null?", prim_nullp}, {"pair?", prim_pairp}, {"atom?", prim_atomp},
        {"number?", prim_numberp}, {"string?", prim_stringp},
        {"symbol?", prim_symbolp}, {"vector?", prim_vectorp},
        {"boolean?", prim_booleanp}, {"procedure?", prim_procedurep},
        {"eof-object?", prim_eofp}, {"not", prim_not},

        {"string-length", prim_string_length}, {"string-ref", prim_string_ref},
        {"string-set!", prim_string_set}, {"make-string", prim_make_string},
        {"string-append", prim_string_append}, {"substring", prim_substring},
        {"string=?", prim_string_eq}, {"string<?", prim_string_lt},
        {"string>?", prim_string_gt}, {"string<=?", prim_string_le},
        {"string>=?", prim_string_ge},
        {"char->integer", prim_char_to_integer}, {"integer->char", prim_integer_to_char},
        {"string->list", prim_string_to_list}, {"list->string", prim_list_to_string},
        {"symbol->string", prim_symbol_to_string}, {"string->symbol", prim_string_to_symbol},
        {"number->string", prim_number_to_string}, {"string->number", prim_string_to_number},

        {"make-vector", prim_make_vector}, {"vector", prim_vector},
        {"vector-length", prim_vector_length}, {"vector-ref", prim_vector_ref},
        {"vector-set!", prim_vector_set}, {"vector->list", prim_vector_to_list},
        {"list->vector", prim_list_to_vector},

        {"display", prim_display}, {"write", prim_write}, {"newline", prim_newline},
        {"write_newline", prim_newline},   // scheme12 が残していた旧 API 名
        {"write-char", prim_write_char},
        {"open-input-file", prim_open_input_file},
        {"open-output-file", prim_open_output_file},
        {"close-input-port", prim_close_port}, {"close-output-port", prim_close_port},
        {"read", prim_read_from_stdin}, {"read-char", prim_read_char},
        {"peek-char", prim_peek_char}, {"char-ready?", prim_char_readyp},
        {"read-line", prim_read_line}, {"read-expr", prim_read_expr},
        {"current-input-port", prim_current_input_port},
        {"current-output-port", prim_current_output_port},
        {"input-port?", prim_input_portp}, {"output-port?", prim_output_portp},
        {"load", prim_load},

        {"values", prim_values}, {"%values->list", prim_values_to_list},
        {"%wind-push", prim_wind_push}, {"%wind-pop", prim_wind_pop},
        {"%wind-top-after", prim_wind_top_after},

        {"error", prim_raise_error}, {"%exit", prim_exit_now},
        {"gensym", prim_gensym}, {"random", prim_random}, {"random-seed", prim_random_seed},
        {"gc-collect", prim_gc_collect}, {"gc-heap-size", prim_gc_heap_size},
        {"gc-free-bytes", prim_gc_free_bytes},

        {"test-start", prim_test_start}, {"test-end", prim_test_end},

        {"compile", prim_compile_show}, {"disassemble", prim_disassemble},
        {"trace-on", prim_trace_on}, {"trace-off", prim_trace_off},
        {"macro-print", prim_macro_print},
        {"globals", prim_globals}, {"macros", prim_macros}, {"help", prim_help},
        {"macroexpand-1", prim_macroexpand_1}, {"macroexpand", prim_macroexpand},
    };
    for (const Entry& e : table) global_define(e.name, make_primitive(e.name, e.fn));
}

// ===========================================================================
// セクション 12. 起動
// ===========================================================================

static std::string slurp_file(const std::string& path) {
    std::FILE* in = fopen_with_gc_retry(path.c_str(), "rb");
    if (!in) error_here("cannot open file for reading" + detail("given", path));
    std::string out;
    char buf[65536];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, in)) > 0) out.append(buf, n);
    bool bad = std::ferror(in) != 0;
    std::fclose(in);
    if (bad) error_here("cannot read file" + detail("given", path));
    return out;
}

// (define name ...) / (define (name ...) ...) / define-macro から名前を取り出す
static bool definition_name(ValuePtr expr, GcString& name, bool& is_macro) {
    if (!is_pair(expr)) return false;
    ValuePtr head = as_pair(expr)->car;
    if (!is_symbol(head)) return false;
    std::string_view h = view_of(as_symbol_name(head));
    if (h != "define" && h != "define-macro") return false;
    is_macro = (h == "define-macro");
    ValuePtr rest = as_pair(expr)->cdr;
    if (!is_pair(rest)) return false;
    ValuePtr lhs = as_pair(rest)->car;
    if (is_symbol(lhs))                                  { name = as_symbol_name(lhs); return true; }
    if (is_pair(lhs) && is_symbol(as_pair(lhs)->car))    { name = as_symbol_name(as_pair(lhs)->car); return true; }
    return false;
}

// 期待値の照合（原典のテスト機構。プリミティブ側は test-start / test-end）。
//
// **期待値は Common Lisp のリーダを通った綴りなので、すべて大文字**
// （`(quote a)` の期待値が `A`、`true` の期待値が `TRUE`）。scheme13 のリーダは
// 大小文字を保存するので、値そのものの equal? では一致しない。
// 転写の意図は「表示がこうなる」なので、**write 表現を大小文字を無視して
// 比べる**ことにした。これで symbol / TRUE / FALSE / NIL が素直に通る。
static bool test_matches(ValuePtr actual, ValuePtr expected) {
    std::string a = to_string(actual);
    std::string b = to_string(expected);
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(a[i])) !=
            std::tolower(static_cast<unsigned char>(b[i]))) return false;
    }
    return true;
}

// 出力の形は原典に合わせる: 値 + 空白、50桁目まで詰めて " pass" か
// "  NG  ( expected: ... )"（原典の ~S と ~50T に対応）。
static void report_test_result(ValuePtr actual, ValuePtr expected) {
    ++g_test_total;
    std::string line = to_string(actual) + " ";
    while (line.size() < 50) line += ' ';
    if (test_matches(actual, expected)) {
        ++g_test_pass;
        line += " pass";
    } else {
        ++g_test_ng;
        line += "  NG  ( expected: " + to_string(expected) + " )";
    }
    std::printf("%s\n", line.c_str());
}

static ValuePtr load_from_path(const std::string& path) {
    std::uint16_t id = source_intern(path, slurp_file(path));
    GcVec<TopForm> forms = read_all(id);
    ValuePtr last = g_nil;
    for (std::size_t i = 0; i < forms.size(); ++i) {
        last = eval_top(forms[i].expr, forms[i].pos);
        // テストモード中は、次の S 式が「いま評価した式の期待値」。
        // (test-start) 自身の評価でモードが立つので、その次の T から照合が始まり、
        // (test-end) の評価でモードが降りるのでそこで止まる。原典と同じ。
        if (!g_test_mode || i + 1 >= forms.size()) continue;
        report_test_result(last, forms[++i].expr);
    }
    return last;
}

// 起動時のライブラリ読み込み。**既に定義済みの名前は上書きしない**
// （組み込みをライブラリ側の同名定義で潰さないため。scheme12 と同じ）。
static ValuePtr load_library_dedup(const std::string& path) {
    std::uint16_t id = source_intern(path, slurp_file(path), /*is_library=*/true);
    ValuePtr last = g_nil;
    for (const TopForm& f : read_all(id)) {
        ValuePtr e = f.expr;
        GcString name;
        bool is_macro = false;
        if (definition_name(e, name, is_macro)) {
            auto it = g_globals.find(view_of(name));
            if (it != g_globals.end()) {
                if (is_macro ? (it->second->macro != nullptr)
                             : (it->second->value != nullptr)) continue;
            }
        }
        last = eval_top(e, f.pos);
    }
    return last;
}

// 起動時ライブラリを探す候補を、実行ファイルの位置と cwd から組み立てる。
//
// **これが見つからないと reverse / map / append など約60個が丸ごと消える。**
// scheme12 は実行ファイルがリポジトリのルート（system_lib.scm の隣）に
// 置かれていたので「実行ファイルの隣 → cwd」の2箇所で足りていたが、
// scheme13 の実行ファイルは scheme13/ の中にあり、その隣に system_lib.scm は
// 無い。結果、リポジトリのルート以外から起動すると**黙って**ライブラリを
// 失っていた（7日目に発覚。決定39）。
//
// 探索順。先に見つかったものを使う:
//   1. 環境変数（明示指定。ファイルへのパス）
//   2. 実行ファイルの隣
//   3. 実行ファイルの1つ上（scheme13/scheme13 → リポジトリのルート）
//   4. カレントディレクトリ
//   5. カレントディレクトリの1つ上
static RootVec<std::string> library_candidates(const char* argv0, const char* env_var,
                                               const char* file) {
    RootVec<std::string> candidates;
    if (const char* env = std::getenv(env_var); env && *env)
        candidates.push_back(env);
    if (argv0 && *argv0) {
        std::string exe(argv0);
        std::size_t slash = exe.find_last_of('/');
        if (slash != std::string::npos) {
            std::string dir = exe.substr(0, slash + 1);
            candidates.push_back(dir + file);
            candidates.push_back(dir + "../" + file);
        }
    }
    candidates.push_back(file);
    candidates.push_back(std::string("../") + file);
    return candidates;
}

// 候補を順に試す。読めたら true。
static bool try_load_library(const RootVec<std::string>& candidates) {
    for (const std::string& path : candidates) {
        try {
            load_library_dedup(path);
            return true;
        } catch (const std::exception&) {
            // 次の候補へ
        }
    }
    return false;
}

static void warn_library_missing(const char* file, const char* env_var,
                                 const char* what,
                                 const RootVec<std::string>& candidates) {
    std::fprintf(stderr, "scheme13: warning: %s not found; %s\n  looked in:\n",
                 file, what);
    for (const std::string& path : candidates)
        std::fprintf(stderr, "    %s\n", path.c_str());
    std::fprintf(stderr, "  set %s to its path, or run from the directory "
                         "that holds it.\n", env_var);
}

// 起動時に読むライブラリは2つ。**順序に意味がある。**
//
//   system_lib.scm  scheme12 と共有している既存資産。触らない
//   lib13.scm       scheme13 が足す R5RS 手続き（決定42）。scheme13/ にある
//
// lib13.scm を**後**に読むのは、system_lib.scm が定義している名前を
// 上書きしないため。load_library_dedup は既に定義済みの名前を飛ばすので、
// 先に読んだほうが勝つ。既存資産の振る舞いを scheme13 が変えてはならない。
//
// **どちらも、見つからなければ黙らずに警告する。** 黙って縮退するのが最も困る。
static void load_startup_libraries(const char* argv0) {
    RootVec<std::string> sys = library_candidates(argv0, "SCHEME13_LIB", "system_lib.scm");
    if (!try_load_library(sys))
        warn_library_missing("system_lib.scm", "SCHEME13_LIB",
                             "the shared library (reverse, map, append, ...) "
                             "is unavailable.", sys);

    RootVec<std::string> own = library_candidates(argv0, "SCHEME13_LIB13", "lib13.scm");
    if (!try_load_library(own))
        warn_library_missing("lib13.scm", "SCHEME13_LIB13",
                             "the R5RS additions (abs, assoc, member, list-ref, ...) "
                             "are unavailable.", own);
}

// --- 自己テスト（凍結仕様との突き合わせ） ----------------------------------

static int g_checks   = 0;
static int g_failures = 0;

static void check_eq(const std::string& what, const std::string& got, const std::string& want) {
    ++g_checks;
    if (got == want) return;
    ++g_failures;
    std::printf("  FAIL  %s\n        got : %s\n        want: %s\n",
                what.c_str(), got.c_str(), want.c_str());
}

// ソースを1つ読んで write 表現に直す（式が1つだけであることを前提にする）
static std::string read_one_to_string(const std::string& src) {
    std::uint16_t id = source_intern("<selftest>", src);
    Reader r(id);
    ValuePtr v = r.read_expr();
    if (!v) return "<none>";
    return to_string(v);
}

static void selftest_display() {
    // dev_memo.md §2.1 の表を 1 行ずつ突き合わせる
    check_eq("()",            read_one_to_string("()"),            "NIL");
    check_eq("nil",           read_one_to_string("nil"),           "NIL");
    check_eq("#t",            read_one_to_string("#t"),            "TRUE");
    check_eq("true",          read_one_to_string("true"),          "TRUE");
    check_eq("#f",            read_one_to_string("#f"),            "FALSE");
    check_eq("false",         read_one_to_string("false"),         "FALSE");
    check_eq("AbC",           read_one_to_string("AbC"),           "AbC");
    check_eq("(a B c)",       read_one_to_string("(a B c)"),       "(a B c)");
    check_eq("(a . b)",       read_one_to_string("(a . b)"),       "(a . b)");
    check_eq("#(1 a \"s\")",  read_one_to_string("#(1 a \"s\")"),  "#(1 a \"s\")");
    // write は文字列の中の改行をエスケープしない
    check_eq("string newline", read_one_to_string("\"hi\\nthere\""), "\"hi\nthere\"");

    // 手で組み立てるしかないもの
    Template* t1 = new Template();
    t1->params.push_back(to_gc("x"));
    t1->params.push_back(to_gc("y"));
    Closure* c1 = new Closure(t1, nullptr);
    check_eq("closure", to_string(c1), "#<closure:(x y)>");

    Template* t2 = new Template();
    t2->params.push_back(to_gc("x"));
    t2->rest = to_gc("r");
    check_eq("closure rest", to_string(new Closure(t2, nullptr)), "#<closure:(x . r)>");

    Template* t3 = new Template();
    t3->rest = to_gc("args");
    check_eq("closure all-rest", to_string(new Closure(t3, nullptr)), "#<closure:(args)>");

    check_eq("macro", to_string(new Macro(c1)), "(MACRO #<closure:(x y)>)");
    check_eq("primitive", to_string(make_primitive("car", nullptr)), "(PRIMITIVE car)");
    check_eq("special form", to_string(make_special_form("if")), "(SPECIAL-FORM if)");
    check_eq("continuation", to_string(new Continuation()), "#<continuation>");
    check_eq("eof", to_string(g_eof), "#<eof>");

    ValuePtr port = make_port(nullptr, true);   // 所有する（＝閉じられる）ポート
    static_cast<Port*>(port)->is_closed = true;
    check_eq("closed port", to_string(port), "#<closed-port>");

    // 循環（cdr 方向）: (1 . #<circular>)
    ValuePtr cyc = make_pair(make_int(1LL), g_nil);
    as_pair(cyc)->cdr = cyc;
    check_eq("circular cdr", to_string(cyc), "(1 . #<circular>)");

    // 循環（car 方向）: (( . #<circular>) 2)
    ValuePtr cyc2 = list_from({make_int(1LL), make_int(2LL)});
    as_pair(cyc2)->car = cyc2;
    check_eq("circular car", to_string(cyc2), "(( . #<circular>) 2)");

    // 循環ベクタ: #(#<circular-vector> 0)
    ValuePtr vec = make_vector(2, make_int(0LL));
    as_vector(vec)->elems[0] = vec;
    check_eq("circular vector", to_string(vec), "#(#<circular-vector> 0)");

    // 共有構造（DAG）は循環ではない。バックトラックを忘れると誤判定する
    ValuePtr shared = list_from({make_symbol("a")});
    check_eq("shared DAG", to_string(list_from({shared, shared})), "((a) (a))");

    // 実数（18日目の §2.1。決定90）。**丸めて隠さない**
    check_eq("real 1.5",       read_one_to_string("1.5"),    "1.5");
    check_eq("real 1.0",       read_one_to_string("1.0"),    "1.0");
    check_eq("real 6.0",       to_string(make_flonum(2.0 * 3.0)), "6.0");
    check_eq("real 1/3",       to_string(make_flonum(1.0 / 3.0)), "0.3333333333333333");
    check_eq("real 0.1+0.2",   to_string(make_flonum(0.1 + 0.2)), "0.30000000000000004");
    check_eq("real 1e21",      read_one_to_string("1e21"),   "1e21");
    check_eq("real 1e-7",      read_one_to_string("1e-7"),   "1e-7");
    check_eq("real -0.0",      read_one_to_string("-0.0"),   "-0.0");
    check_eq("real +inf.0",    read_one_to_string("+inf.0"), "+inf.0");
    check_eq("real -inf.0",    read_one_to_string("-inf.0"), "-inf.0");
    check_eq("real +nan.0",    read_one_to_string("+nan.0"), "+nan.0");
    check_eq("real in list",   read_one_to_string("(1.5 x)"), "(1.5 x)");
    check_eq("real in vector", read_one_to_string("#(1.5)"),  "#(1.5)");
    check_eq("real display",   to_display_string(make_flonum(2.5)), "2.5");

    // display と write の違いは、一番外側が文字列のときだけ
    check_eq("display string", to_display_string(make_string("x")), "x");
    check_eq("write string",   to_string(make_string("x")),         "\"x\"");
    ValuePtr inner = list_from({make_string("x"), make_symbol("y")});
    check_eq("display list of string", to_display_string(inner), "(\"x\" y)");
}

static void selftest_reader() {
    // 角括弧は区切り文字ではない: '[1 2] は [1 と 2] の 2 シンボル
    {
        std::uint16_t id = source_intern("<selftest>", "'[1 2]");
        GcVec<TopForm> xs = read_all(id);
        check_eq("brackets: count", std::to_string(xs.size()), "2");
        if (xs.size() == 2) {
            check_eq("brackets: 1st", to_string(xs[0].expr), "(quote [1)");
            check_eq("brackets: 2nd", to_string(xs[1].expr), "2]");
        }
    }
    check_eq("quote",      read_one_to_string("'x"),   "(quote x)");
    check_eq("quasiquote", read_one_to_string("`x"),   "(quasiquote x)");
    check_eq("unquote",    read_one_to_string(",x"),   "(unquote x)");
    check_eq("splice",     read_one_to_string(",@x"),  "(splice x)");

    // 数値の判定規則（scheme12 と同一）
    check_eq("number",       read_one_to_string("42"),    "42");
    check_eq("neg number",   read_one_to_string("-5"),    "-5");
    check_eq("plus symbol",  read_one_to_string("+"),     "+");
    check_eq("minus symbol", read_one_to_string("-"),     "-");
    // 符号つき整数。+5 は19日目まで Boost の例外で処理系ごと落ちていた（決定99）
    check_eq("plus number",  read_one_to_string("+5"),    "5");
    check_eq("plus bignum",  read_one_to_string("+9999999999800000000001"),
                             "9999999999800000000001");
    check_eq("1a is symbol", read_one_to_string("1a"),    "1a");
    check_eq("bignum",
             read_one_to_string("9999999999800000000001"), "9999999999800000000001");

    // fixnum とヒープ整数の境界。表示は同じでなければならない
    check_eq("fixnum max",   read_one_to_string(std::to_string(FIXNUM_MAX)),
                             std::to_string(FIXNUM_MAX));
    check_eq("fixnum max+1", read_one_to_string((BigInt(FIXNUM_MAX) + 1).str()),
                             (BigInt(FIXNUM_MAX) + 1).str());
    check_eq("fixnum min",   read_one_to_string(std::to_string(FIXNUM_MIN)),
                             std::to_string(FIXNUM_MIN));
    check_eq("fixnum min-1", read_one_to_string((BigInt(FIXNUM_MIN) - 1).str()),
                             (BigInt(FIXNUM_MIN) - 1).str());

    // 文字列のエスケープは \n だけが特別
    check_eq("escape t",     read_one_to_string("\"a\\tb\""),  "\"atb\"");
    check_eq("escape quote", read_one_to_string("\"a\\\"b\""), "\"a\"b\"");

    // ドットは単独トークンのときだけ（scheme12 からの意図的な変更）
    check_eq("dotted pair", read_one_to_string("(1 . 2)"),  "(1 . 2)");
    check_eq("ellipsis",    read_one_to_string("'(...)"),   "(quote (...))");

    // # で始まる他のトークンはシンボル
    check_eq("hash label", read_one_to_string("#1="), "#1=");
    check_eq("hash true only with delimiter", read_one_to_string("#true"), "#true");

    // 実数のリテラル（§2.5。18日目の決定89）。
    // **トークン全体が形に一致したときだけ数**で、外れたらシンボルのまま
    check_eq("real .5",       read_one_to_string(".5"),      "0.5");
    check_eq("real 1.",       read_one_to_string("1."),      "1.0");
    check_eq("real 1.5e-3",   read_one_to_string("1.5e-3"),  "0.0015");
    check_eq("real -0.75",    read_one_to_string("-0.75"),   "-0.75");
    check_eq("1/2 is symbol",   read_one_to_string("1/2"),   "1/2");
    check_eq("1.2.3 is symbol", read_one_to_string("1.2.3"), "1.2.3");
    check_eq("1e is symbol",    read_one_to_string("1e"),    "1e");
    check_eq("1e+ is symbol",   read_one_to_string("1e+"),   "1e+");
    // from_chars に判定を任せると数に化ける3つ（決定89）。シンボルのままであること
    check_eq("inf is symbol",      read_one_to_string("inf"),      "inf");
    check_eq("nan is symbol",      read_one_to_string("nan"),      "nan");
    check_eq("infinity is symbol", read_one_to_string("infinity"), "infinity");
    // 桁あふれと桁不足は ±inf / ±0.0 に丸める（黙って落とさない）
    check_eq("overflow",      read_one_to_string("1e400"),   "+inf.0");
    check_eq("underflow",     read_one_to_string("1e-400"),  "0.0");
    check_eq("neg underflow", read_one_to_string("-1e-400"), "-0.0");
    // 実数は読み戻せる（決定90）。整数と違って write の出力が入力に使える
    check_eq("real roundtrip", read_one_to_string("0.30000000000000004"),
                               "0.30000000000000004");
    // ドット対とは衝突しない（'.' がドットになるのは次が区切り文字のときだけ）
    check_eq("dot vs real",   read_one_to_string("(a .5)"),  "(a 0.5)");
    check_eq("dotted pair 2", read_one_to_string("(a . 5)"), "(a . 5)");

    // コメントと複数行
    {
        std::uint16_t id = source_intern("<selftest>", "; c\n(a\n b) ; c2\n(c)");
        GcVec<TopForm> xs = read_all(id);
        check_eq("comments: count", std::to_string(xs.size()), "2");
        if (xs.size() == 2) check_eq("comments: 1st", to_string(xs[0].expr), "(a b)");
    }
}

// 1つのソースを読んで 1段展開し、write 表現に直す
static std::string expand_one(const std::string& src) {
    std::uint16_t id = source_intern("<selftest>", src);
    Reader r(id);
    ValuePtr v = r.read_expr();
    if (!v) return "<none>";
    return to_string(expand_form_1(v));
}

static void selftest_expand() {
    check_eq("let",
             expand_one("(let ((x 1) (y 2)) (+ x y))"),
             "((lambda (x y) (+ x y)) 1 2)");
    check_eq("named let",
             expand_one("(let loop ((i 0)) (f i))"),
             "(letrec ((loop (lambda (i) (f i)))) (loop 0))");
    check_eq("let*",
             expand_one("(let* ((x 1) (y 2)) (+ x y))"),
             "(let ((x 1)) (let* ((y 2)) (+ x y)))");
    check_eq("let* empty",
             expand_one("(let* () (a) (b))"),
             "(begin (a) (b))");
    check_eq("letrec",
             expand_one("(letrec ((f 1)) (f))"),
             "(let ((f :undef)) (begin (set! f 1) (f)))");

    check_eq("and empty",  expand_one("(and)"),       "TRUE");
    check_eq("and one",    expand_one("(and x)"),     "x");
    check_eq("and three",  expand_one("(and a b c)"), "(if a (if b c FALSE) FALSE)");

    check_eq("or empty",   expand_one("(or)"),        "FALSE");
    check_eq("or one",     expand_one("(or x)"),      "x");
    // gensym の採番は scheme12 と同じく外側から
    g_gensym_counter = 0;
    check_eq("or three",   expand_one("(or a b c)"),
             "(let ((or1 a)) (if or1 or1 (let ((or2 b)) (if or2 or2 c))))");

    check_eq("cond empty", expand_one("(cond)"),      ":undef");
    check_eq("cond",       expand_one("(cond (a 1) (else 2))"), "(if a 1 2)");
    check_eq("cond else drops rest",
             expand_one("(cond (else 1) (b 2))"), "1");
    g_gensym_counter = 0;
    check_eq("cond test only",
             expand_one("(cond (a))"),
             "(let ((cond1 a)) (if cond1 cond1 :undef))");

    g_gensym_counter = 0;
    check_eq("case",
             expand_one("(case k ((1 2) a) (else b))"),
             "(let ((case1 k)) (cond ((memv case1 (quote (1 2))) a) (else b)))");

    g_gensym_counter = 0;
    check_eq("do",
             expand_one("(do ((i 0 (+ i 1))) ((= i 3) (quote done)) (f i))"),
             "(letrec ((loop1 (lambda (i) (if (= i 3) (quote done)"
             " (begin (f i) (loop1 (+ i 1))))))) (loop1 0))");

    // 準クオート
    check_eq("qq simple",
             expand_one("`(a ,x)"),
             "(cons (quote a) (cons x (quote NIL)))");
    // ドット位置の unquote。`(,k . ,v) は ((unquote k) unquote v) と読まれる
    check_eq("qq dotted",
             expand_one("`(,k . ,v)"),
             "(cons k v)");
    check_eq("qq splice",
             expand_one("`(a ,@b c)"),
             "(cons (quote a) (append b (cons (quote c) (quote NIL))))");
    check_eq("qq vector",
             expand_one("`#(1 ,x)"),
             "(list->vector (cons (quote 1) (cons x (quote NIL))))");

    // 本体先頭の define だけが letrec へ移る（§2.6）
    {
        std::uint16_t id = source_intern("<selftest>", "((define (g x) x) (g 1))");
        Reader r(id);
        ValuePtr body = r.read_expr();
        check_eq("scan out defines",
                 to_string(scan_out_defines(body)),
                 "((letrec ((g (lambda (x) x))) (g 1)))");
    }
    {
        // 式より後ろの define は移さない
        std::uint16_t id = source_intern("<selftest>", "((g 1) (define x 2))");
        Reader r(id);
        ValuePtr body = r.read_expr();
        check_eq("define after expr stays",
                 to_string(scan_out_defines(body)),
                 "((g 1) (define x 2))");
    }
    {
        // 本体が define だけなら :undef を足す
        std::uint16_t id = source_intern("<selftest>", "((define x 1))");
        Reader r(id);
        ValuePtr body = r.read_expr();
        check_eq("define only body",
                 to_string(scan_out_defines(body)),
                 "((letrec ((x 1)) :undef))");
    }

    // 構文エラー（位置つき）
    {
        std::uint16_t id = source_intern("t.scm", "(let ((x)) x)");
        Reader r(id);
        try {
            expand_form_1(r.read_expr());
            check_eq("bad binding", "no error", "error");
        } catch (const SchemeError& e) {
            check_eq("bad binding", format_error(e),
                     "t.scm:1:1: bad syntax in let\n"
                     "  expected: each binding to be (variable expression)\n"
                     "  given: (x)\n"
                     "    (let ((x)) x)\n    ^");
        }
    }
    {
        std::uint16_t id = source_intern("t.scm", "(do ((i 0)))");
        Reader r(id);
        try {
            expand_form_1(r.read_expr());
            check_eq("do arity", "no error", "error");
        } catch (const SchemeError& e) {
            check_eq("do arity", format_error(e),
                     "t.scm:1:1: bad syntax in do\n"
                     "  expected: at least 2 arguments\n"
                     "  given: 1\n"
                     "    (do ((i 0)))\n    ^");
        }
    }
}

// 原典のテスト機構の照合規則（大小文字を無視した write 表現の比較）。
// 実際の読み進めはゴールデン（test-case6.scm）が端から端まで押さえている。
static void selftest_test_matching() {
    auto datum = [](const std::string& src) {
        std::uint16_t id = source_intern("<selftest>", src);
        Reader r(id);
        return r.read_expr();
    };
    auto match = [&](const std::string& actual, const std::string& expected) {
        return test_matches(eval_top(datum(actual)), datum(expected)) ? "pass" : "NG";
    };
    // 期待値は CL のリーダ由来で大文字。大小文字を無視して照合する
    check_eq("test: symbol case",  match("(quote a)", "A"),        "pass");
    check_eq("test: list case",    match("(cdr '(a b c))", "(B C)"), "pass");
    check_eq("test: boolean",      match("(eq? 'a 'a)", "TRUE"),   "pass");
    check_eq("test: nil",          match("(cdr '(a))", "NIL"),     "pass");
    check_eq("test: dotted",       match("(cons 'a 'b)", "(A . B)"), "pass");
    check_eq("test: mismatch",     match("(quote a)", "B"),        "NG");
    // 原典との既知の差（golden/README.md の表）。ここが pass に変わったら
    // 凍結仕様のどれかが動いている
    check_eq("test: closure differs",  match("(lambda (x) x)", "(CLOSURE (LD (0 . 0) RTN) NIL)"), "NG");
    check_eq("test: (begin) differs",  match("(begin)", ":UNDEF"), "NG");
}

static void selftest_positions() {
    std::uint16_t id = source_intern("t.scm", "(define x\n        (foo bar))\n");
    Reader r(id);
    ValuePtr form = r.read_expr();

    SourcePos p = pos_of(form);
    check_eq("pos of form", std::to_string(p.line) + ":" + std::to_string(p.col), "1:1");

    // (foo bar) は 2 行目 9 桁目
    ValuePtr inner = car(cdr(cdr(form)));
    SourcePos q = pos_of(inner);
    check_eq("pos of inner", std::to_string(q.line) + ":" + std::to_string(q.col), "2:9");

    // 実行時に cons したペアは位置を持たない
    check_eq("pos of runtime pair",
             pos_of(make_pair(g_nil, g_nil)).known() ? "known" : "unknown", "unknown");

    // エラーの整形（キャレット行つき）
    std::uint16_t bad = source_intern("t.scm", "(foo\n  bar");
    try {
        read_all(bad);
        check_eq("unterminated list", "no error", "error");
    } catch (const SchemeError& e) {
        check_eq("unterminated list", format_error(e),
                 "t.scm:1:1: unexpected EOF in list\n    (foo\n    ^");
    }

    std::uint16_t bad2 = source_intern("t.scm", "(a b))");
    try {
        read_all(bad2);
        check_eq("stray paren", "no error", "error");
    } catch (const SchemeError& e) {
        check_eq("stray paren", format_error(e),
                 "t.scm:1:6: unexpected ')'\n    (a b))\n         ^");
    }

    std::uint16_t bad3 = source_intern("t.scm", "\"abc");
    try {
        read_all(bad3);
        check_eq("unterminated string", "no error", "error");
    } catch (const SchemeError& e) {
        check_eq("unterminated string", format_error(e),
                 "t.scm:1:1: unexpected EOF in string literal\n    \"abc\n    ^");
    }
}

// 1つの式を評価して write 表現に直す（コンパイラと VM の突き合わせ用）
static std::string eval_to_string(const std::string& src) {
    std::uint16_t id = source_intern("<selftest>", src);
    ValuePtr last = g_nil;
    for (const TopForm& f : read_all(id)) last = eval_top(f.expr, f.pos);
    return to_string(last);
}

// 式を評価し、投げられたエラーの本文（位置とキャレット行を除く）を返す。
// 落ちなかったら "no error"。文面そのものを固定するためのもの。
static std::string eval_error_body(const std::string& src) {
    std::uint16_t id = source_intern("<selftest>", src);
    try {
        for (const TopForm& f : read_all(id)) eval_top(f.expr, f.pos);
        return "no error";
    } catch (const SchemeError& e) {
        return e.what();
    }
}

// 同じだが、エラーが**どこを指したか**だけを "行:桁" で返す。位置が付かな
// かったら "no position"。マクロ展開後の位置を固定するためのもの（決定52）。
static std::string eval_error_at(const std::string& src) {
    std::uint16_t id = source_intern("<selftest>", src);
    try {
        for (const TopForm& f : read_all(id)) eval_top(f.expr, f.pos);
        return "no error";
    } catch (const SchemeError& e) {
        if (!e.pos.known()) return "no position";
        return std::to_string(e.pos.line) + ":" + std::to_string(e.pos.col);
    }
}

// エラー本文の形（決定33）。**見出し1行 + 字下げした詳細行**であること、
// 詳細が expected: / given: の順であること、内部エラーが利用者の誤りと
// 区別されること。ここが崩れると、読む側が毎回違う場所を探すことになる。
static void selftest_errors() {
    check_eq("type error shape",
             eval_error_body("(car 5)"),
             "car: wrong type of argument\n  expected: a pair\n  given: 5");
    check_eq("proper list expected",
             eval_error_body("(length (cons 1 2))"),
             "length: wrong type of argument\n  expected: a proper list\n  given: (1 . 2)");

    // クロージャの引数不足は**呼ばれた側の名前**を出す（§8 の1番目）
    check_eq("arity names the callee",
             eval_error_body("(define (f a b) a) (f 1)"),
             "f: wrong number of arguments\n  expected: 2 arguments\n  given: 1");
    check_eq("arity of anonymous closure",
             eval_error_body("((lambda (a b) a) 1)"),
             "#<closure:(a b)>: wrong number of arguments\n"
             "  expected: 2 arguments\n  given: 1");
    check_eq("arity with rest",
             eval_error_body("(define (g a . r) a) (g)"),
             "g: wrong number of arguments\n"
             "  expected: at least 1 argument\n  given: 0");
    check_eq("arity of primitive",
             eval_error_body("(cons 1)"),
             "cons: wrong number of arguments\n  expected: 2 arguments\n  given: 1");

    // 添字。空の入れ物に「0 から -1 まで」と言わせない
    check_eq("index range",
             eval_error_body("(vector-ref (vector 1 2 3) 7)"),
             "vector-ref: index out of range\n"
             "  expected: an element index from 0 to 2\n  given: 7");
    check_eq("index range on empty",
             eval_error_body("(vector-ref (vector) 0)"),
             "vector-ref: index out of range\n"
             "  expected: an element index, but the vector is empty\n  given: 0");
    // 値域は添字ではないので見出しを分ける
    check_eq("argument range",
             eval_error_body("(integer->char 999)"),
             "integer->char: argument out of range\n"
             "  expected: an ASCII code from 0 to 127\n  given: 999");

    // 算術は実数も受けるので、数でない引数は「an integer」ではなく
    // 「a number」と言う（20日目の決定102）
    check_eq("arithmetic type error",
             eval_error_body("(+ 1 \"x\")"),
             "+: wrong type of argument\n  expected: a number\n  given: \"x\"");
    // 有理数が無いので、整数値でない実数は正確な数にできない（決定93）
    check_eq("no exact representation",
             eval_error_body("(inexact->exact 2.5)"),
             "inexact->exact: argument out of range\n"
             "  expected: a real with no fractional part (there are no rationals)\n"
             "  given: 2.5");
    // 整数を要求する場所は実数を受け取らない（決定92）
    check_eq("index rejects a real",
             eval_error_body("(vector-ref (vector 1 2) 1.0)"),
             "vector-ref: wrong type of argument\n  expected: an integer\n  given: 1.0");

    check_eq("unbound variable",
             eval_error_body("(nosuchthing 1)"),
             "unbound variable: nosuchthing\n"
             "  note: it is referenced here but never defined by define or set!");
    check_eq("call a non-procedure",
             eval_error_body("(5 6)"),
             "attempt to call a non-procedure\n  expected: a procedure\n  given: 5");

    // ポート（10日目）。「ポートですらない」と「向きが違う」を区別する
    check_eq("not a port",
             eval_error_body("(read-char 5)"),
             "read-char: wrong type of argument\n  expected: a port\n  given: 5");
    check_eq("wrong port direction",
             eval_error_body("(read-char (current-output-port))"),
             "read-char: wrong type of argument\n"
             "  expected: an open input port\n  given: #<output-port>");

    // Scheme 側から投げる error（決定41）。見出しは呼ぶ側が決め、
    // irritant が given: の詳細行になる
    check_eq("error with one irritant",
             eval_error_body("(error \"sqrt: argument out of range\" -4)"),
             "sqrt: argument out of range\n  given: -4");
    check_eq("error with several irritants",
             eval_error_body("(error \"f: wrong type of argument\" 1 \"two\")"),
             "f: wrong type of argument\n  given: 1\n  given: \"two\"");
    check_eq("error with no irritant",
             eval_error_body("(error \"plain message\")"), "plain message");
    // 第1引数が文字列でなければ write 表現をそのまま見出しにする
    check_eq("error with a non-string message",
             eval_error_body("(error 'oops)"), "oops");

    // §2.3 で凍結した文面。中身は変えない
    check_eq("single-argument division",
             eval_error_body("(/ 5)"),
             "/: requires at least 2 arguments (single-argument reciprocal is not "
             "supported; use (/ 1 x) instead)");

    // 処理系自身の不変条件が壊れた場合は、利用者の誤りと明示的に分ける
    try {
        as_pair(g_nil);
        check_eq("internal error is labelled", "no error", "error");
    } catch (const SchemeError& e) {
        check_eq("internal error is labelled", e.what(),
                 "internal error: as_pair on a non-pair\n"
                 "  note: this is a bug in scheme13 itself, "
                 "not in the program being run");
    }
}

// 展開を外から観察する道具（決定34）。**コンパイラと同じ1段**を見せること。
// マクロ展開後の位置（11日目の決定52）。§9 の積み残しに対する回帰。
// **「利用者が書いた行」を指すこと**が満たすべき性質で、展開結果の内部の
// どこを指すかではない。
static void selftest_macro_positions() {
    // 展開結果の内部（生成された lambda の本体）で落ちても、マクロ呼び出しを指す
    check_eq("macro: deep expansion",
             eval_error_at("(define-macro (deep x) `(let ((y 1)) (begin (car ,x))))\n"
                           "(deep 5)\n"), "2:1");
    // 生成された lambda が後から呼ばれても、コードが書かれた場所を指す
    check_eq("macro: generated closure",
             eval_error_at("(define-macro (mk x) `(lambda () (car ,x)))\n"
                           "(define f (mk 5))\n"
                           "(f)\n"), "2:11");
    // 利用者が渡した部分式は**自分の位置を保つ**。マクロ呼び出しには丸めない
    check_eq("macro: argument keeps its own position",
             eval_error_at("(define-macro (unless c . body) `(if ,c #f (begin ,@body)))\n"
                           "(unless #f (car 5))\n"), "2:12");
    // 生成コードの未束縛参照
    check_eq("macro: unbound in expansion",
             eval_error_at("(define-macro (u) `(let ((q 1)) (nosuch q)))\n"
                           "(u)\n"), "2:1");
    // 生成コードの構文エラー（コンパイル時）
    check_eq("macro: bad syntax in expansion",
             eval_error_at("(define-macro (b) `(let ((a)) a))\n"
                           "(b)\n"), "2:1");
    // マクロがマクロを生む場合も同じ
    check_eq("macro: nested macros",
             eval_error_at("(define-macro (inner x) `(car ,x))\n"
                           "(define-macro (outer x) `(let ((q 1)) (inner ,x)))\n"
                           "(outer 5)\n"), "3:1");
    // 展開を通らない普通のソースは今までどおり（この修正で変わらないこと）
    check_eq("plain let is unaffected",
             eval_error_at("(let ((y 1)) (car 5))\n"), "1:14");
    check_eq("plain lambda is unaffected",
             eval_error_at("(define (h) (car 5))\n(h)\n"), "1:13");
}

static void selftest_macroexpand() {
    check_eq("macroexpand-1 on a special form",
             eval_to_string("(macroexpand-1 '(let ((x 1)) x))"),
             "((lambda (x) x) 1)");
    check_eq("macroexpand-1 on a user macro",
             eval_to_string("(define-macro (twice e) `(begin ,e ,e))"
                            "(macroexpand-1 '(twice (f)))"),
             "(begin (f) (f))");
    // 展開されないものはそのまま返る（エラーにしない）
    check_eq("macroexpand-1 leaves a call alone",
             eval_to_string("(macroexpand-1 '(+ 1 2))"), "(+ 1 2)");
    check_eq("macroexpand-1 leaves an atom alone",
             eval_to_string("(macroexpand-1 'x)"), "x");
    // macroexpand は外側だけを繰り返す。部分式へは降りない
    check_eq("macroexpand repeats the outside only",
             eval_to_string("(define-macro (swap! a b)"
                            " `(let ((tmp ,a)) (set! ,a ,b) (set! ,b tmp)))"
                            "(macroexpand '(swap! p q))"),
             "((lambda (tmp) (set! p q) (set! q tmp)) p)");
    check_eq("macroexpand does not descend",
             eval_to_string("(macroexpand '(f (let ((x 1)) x)))"),
             "(f (let ((x 1)) x))");
    // 自分自身に展開するマクロで止まらなくならないこと
    check_eq("macroexpand gives up on a self-expanding macro",
             eval_error_body("(define-macro (boom x) `(boom ,x)) (macroexpand '(boom 1))"),
             "macroexpand: expansion did not terminate\n"
             "  note: the outermost form still expands after 1000 steps; "
             "a macro is probably expanding into itself");
}

static void selftest_eval() {
    check_eq("arith",      eval_to_string("(+ 1 2 3)"),           "6");
    check_eq("nested",     eval_to_string("(* (+ 1 2) (- 10 4))"), "18");
    check_eq("bignum",     eval_to_string("(* 99999999999 99999999999)"),
                                          "9999999999800000000001");
    // fixnum の境界をまたいでも表示は同じでなければならない（§9 の規律）
    check_eq("fixnum overflow",
             eval_to_string("(= (* 4611686018427387903 2) 9223372036854775806)"), "TRUE");
    check_eq("normalize back",
             eval_to_string("(eq? (- (* 4611686018427387903 2) 9223372036854775805) 1)"),
             "TRUE");
    check_eq("div trunc",  eval_to_string("(/ -7 2)"),            "-3");
    check_eq("modulo neg", eval_to_string("(modulo -7 2)"),       "1");
    check_eq("modulo pos", eval_to_string("(modulo 7 -2)"),       "-1");

    // --- 実数（20日目）------------------------------------------------------
    // 伝播規則: 一つでも不正確なら結果も不正確（決定91）
    check_eq("contagion +",  eval_to_string("(+ 1 1.5)"),   "2.5");
    check_eq("contagion -",  eval_to_string("(- 1 0.5)"),   "0.5");
    check_eq("contagion *",  eval_to_string("(* 2 3.0)"),   "6.0");
    check_eq("negate real",  eval_to_string("(- 2.5)"),     "-2.5");
    // **整数だけなら1つも変わらない**（ここが崩れたら §5.1 が壊れる）
    check_eq("exact stays",  eval_to_string("(+ 1 2)"),     "3");
    check_eq("exact / stays", eval_to_string("(/ 7 2)"),    "3");
    // §2.3 の §/。整数どうしは切り捨て、実数が混ざれば実数除算（決定82）
    check_eq("div inexact",  eval_to_string("(/ 7 2.0)"),   "3.5");
    check_eq("div 1/3",      eval_to_string("(/ 1 3)"),     "0");
    check_eq("div 1.0/3",    eval_to_string("(/ 1.0 3)"),   "0.3333333333333333");
    check_eq("div zero real", eval_to_string("(/ 1.0 0.0)"), "+inf.0");
    // 混合比較は倍精度に寄せる（決定88）
    check_eq("mixed =",      eval_to_string("(= 1 1.0)"),      "TRUE");
    check_eq("mixed <",      eval_to_string("(< 1 1.5 2)"),    "TRUE");
    check_eq("eqv exactness", eval_to_string("(eqv? 1 1.0)"),  "FALSE");
    // **NaN はどの比較も偽**（決定87）。`>=` を「`<` の否定」で書いていたら落ちる
    check_eq("nan =",  eval_to_string("(= +nan.0 +nan.0)"), "FALSE");
    check_eq("nan <",  eval_to_string("(< +nan.0 1)"),      "FALSE");
    check_eq("nan >",  eval_to_string("(> +nan.0 1)"),      "FALSE");
    check_eq("nan <=", eval_to_string("(<= 1 +nan.0)"),     "FALSE");
    check_eq("nan >=", eval_to_string("(>= +nan.0 1)"),     "FALSE");
    check_eq("inf cmp", eval_to_string("(< 1e308 +inf.0)"), "TRUE");
    // 正確さの述語と変換（決定93）
    check_eq("exact? int",    eval_to_string("(exact? 3)"),        "TRUE");
    check_eq("exact? real",   eval_to_string("(exact? 3.0)"),      "FALSE");
    check_eq("inexact? real", eval_to_string("(inexact? 3.0)"),    "TRUE");
    check_eq("integer? 2.0",  eval_to_string("(integer? 2.0)"),    "TRUE");
    check_eq("integer? 2.5",  eval_to_string("(integer? 2.5)"),    "FALSE");
    check_eq("integer? inf",  eval_to_string("(integer? +inf.0)"), "FALSE");
    check_eq("integer? str",  eval_to_string("(integer? \"x\")"),  "FALSE");
    check_eq("rational? inf", eval_to_string("(rational? +inf.0)"), "FALSE");
    check_eq("real? nan",     eval_to_string("(real? +nan.0)"),    "TRUE");
    check_eq("e->i",          eval_to_string("(exact->inexact 1)"),   "1.0");
    check_eq("i->e",          eval_to_string("(inexact->exact 2.0)"), "2");
    // 大きい整数を実数にすると桁は落ちる（決定88）。落ちること自体が仕様
    check_eq("e->i big",
             eval_to_string("(exact->inexact (* 1125899906842624 1125899906842624))"),
             "1.2676506002282294e30");
    // 丸め: 正確な整数は恒等、実数は**実数のまま**。round は偶数丸め（決定93）
    check_eq("floor exact",    eval_to_string("(floor 5)"),      "5");
    check_eq("floor real",     eval_to_string("(floor 2.7)"),    "2.0");
    check_eq("floor neg",      eval_to_string("(floor -2.5)"),   "-3.0");
    check_eq("ceiling real",   eval_to_string("(ceiling 2.1)"),  "3.0");
    check_eq("truncate neg",   eval_to_string("(truncate -2.7)"), "-2.0");
    check_eq("round even 2.5", eval_to_string("(round 2.5)"),    "2.0");
    check_eq("round even 3.5", eval_to_string("(round 3.5)"),    "4.0");
    // 超越関数（21日目）。**libm の最後の桁に依存する値は固定しない**（決定107）。
    // %sqrt だけは IEEE 754 が正しい丸めを義務づけているので固定してよい
    check_eq("%sqrt",     eval_to_string("(%sqrt 2)"),   "1.4142135623730951");
    check_eq("%expt",     eval_to_string("(%expt 2.0 3)"), "8.0");
    check_eq("exp zero",  eval_to_string("(exp 0)"),     "1.0");
    check_eq("log one",   eval_to_string("(log 1)"),     "0.0");
    // 定義域の外は IEEE 754 に従う。例外にしない（決定105）
    check_eq("log zero",  eval_to_string("(log 0)"),     "-inf.0");
    check_eq("log neg",   eval_to_string("(log -1)"),    "+nan.0");
    check_eq("asin out",  eval_to_string("(asin 2)"),    "+nan.0");
    check_eq("atan2",     eval_to_string("(= (atan 1 1) (atan 1))"), "TRUE");

    check_eq("define",     eval_to_string("(define zz 1)"),       "zz");
    check_eq("set!",       eval_to_string("(define v 1) (set! v 2)"), "2");
    check_eq("newline ret", eval_to_string("(newline)"),          "NIL");

    check_eq("lambda",     eval_to_string("((lambda (x y) (+ x y)) 3 4)"), "7");
    check_eq("rest args",  eval_to_string("((lambda (x . r) r) 1 2 3)"),   "(2 3)");
    check_eq("closure",    eval_to_string("(define (adder n) (lambda (x) (+ x n)))"
                                          "((adder 3) 4)"), "7");
    check_eq("recursion",  eval_to_string("(define (f n) (if (= n 0) 1 (* n (f (- n 1)))))"
                                          "(f 10)"), "3628800");
    // 末尾再帰がスタックを食わないこと
    check_eq("tail call",  eval_to_string("(define (loop i acc)"
                                          " (if (= i 0) acc (loop (- i 1) (+ acc 1))))"
                                          "(loop 100000 0)"), "100000");
    check_eq("named let",  eval_to_string("(let loop ((i 0) (acc '()))"
                                          " (if (= i 3) acc (loop (+ i 1) (cons i acc))))"),
                                          "(2 1 0)");
    check_eq("internal define",
             eval_to_string("(define (outer x) (define (helper y) (* y 2)) (helper x))"
                            "(outer 5)"), "10");
    check_eq("apply",      eval_to_string("(apply + 1 2 '(3 4))"), "10");
    check_eq("macro",      eval_to_string("(define-macro (my-if c t e) `(cond (,c ,t) (else ,e)))"
                                          "(my-if #t 'yes 'no)"), "yes");
    check_eq("call/cc",    eval_to_string("(+ 1 (call/cc (lambda (k) (k 10) 999)))"), "11");
    check_eq("call/cc no escape",
             eval_to_string("(+ 1 (call/cc (lambda (k) 10)))"), "11");
    // §2.7: トップレベルのフォームは個別に評価されるので、フォームを跨いで
    // 継続を起動すると、そのフォームの残りは実行されず次のフォームへ進む。
    // ここでは (k n) が3番目のフォームの継続へ跳び、そのフォームが 3 を返して終わる。
    // ループにはならない（scheme12 で実測して確認した値）。
    check_eq("call/cc across top-level forms",
             eval_to_string("(define k #f)"
                            "(define n 0)"
                            "(set! n (+ 1 (call/cc (lambda (c) (set! k c) 1))))"
                            "(if (< n 5) (k n) n)"), "3");
    check_eq("equal? deep", eval_to_string("(equal? '(1 (2 #(3 \"x\"))) '(1 (2 #(3 \"x\"))))"),
                            "TRUE");
    check_eq("eq? numbers", eval_to_string("(eq? 100000000000 100000000000)"), "TRUE");
    check_eq("eq? strings", eval_to_string("(eq? \"a\" \"a\")"),   "FALSE");
    check_eq("procedure? call/cc", eval_to_string("(procedure? call/cc)"), "FALSE");
    check_eq("special form value", eval_to_string("if"), "(SPECIAL-FORM if)");
    check_eq("primitive value",    eval_to_string("car"), "(PRIMITIVE car)");
    check_eq("vector-set! ret", eval_to_string("(define w (make-vector 2 0))"
                                               "(vector-set! w 0 9)"), ":undef");
    check_eq("string is char",  eval_to_string("(string-ref \"abc\" 1)"), "\"b\"");
    check_eq("integer->char",   eval_to_string("(integer->char 65)"),     "\"A\"");
    check_eq("do loop", eval_to_string("(do ((i 0 (+ i 1)) (acc 0 (+ acc i)))"
                                       " ((= i 5) acc))"), "10");
    // --- 使い捨て閉包の印（12日目の決定54）---
    // let は ((lambda ...) ...) に展開され、その lambda は APP に食われて
    // 即座に死ぬ。**外へ逃げる閉包が巻き添えでスクラッチにならないこと**が
    // ここで守るべき性質。
    check_eq("let escapes as distinct closures",
             eval_to_string("(define (f n) (let ((a n)) (lambda () a)))"
                            "(define g1 (f 1)) (define g2 (f 2))"
                            "(list (g1) (g2))"), "(1 2)");
    check_eq("closures made in separate lets do not alias",
             eval_to_string("(define fs (list (let ((n 1)) (lambda () n))"
                            "                 (let ((n 2)) (lambda () n))))"
                            "(list ((car fs)) ((car (cdr fs))))"), "(1 2)");
    check_eq("nested let environments",
             eval_to_string("(let ((a 1)) (let ((b 2)) (let ((c 3)) (list a b c))))"),
             "(1 2 3)");
    // let の init が閉包を作る場合、その閉包は逃げるので本物でなければならない
    check_eq("closure bound by let is a real closure",
             eval_to_string("(let ((h (lambda (x) (* x 2)))) (list (h 3) (h 4)))"), "(6 8)");
    // 継続を let の中で捕まえる
    check_eq("call/cc inside let",
             eval_to_string("(+ 1 (let ((x 1)) (call/cc (lambda (k) (k 10) 999))))"), "11");
    // apply の被呼び出しが lambda（APPLY 経路。印は付かない）
    check_eq("apply on a literal lambda",
             eval_to_string("(apply (lambda (x y) (+ x y)) '(3 4))"), "7");
    // 名前つき let（閉包を作って再帰する）
    check_eq("named let still recurses",
             eval_to_string("(let loop ((i 0) (acc '())) "
                            "  (if (= i 3) acc (loop (+ i 1) (cons i acc))))"), "(2 1 0)");

    // --- 多値（13日目の決定58）---
    // **1個なら箱に入れない。** それ以外だけ Values オブジェクトになる。
    check_eq("values of one is the value", eval_to_string("(values 5)"),      "5");
    check_eq("values of two",              eval_to_string("(values 1 2)"),    "#<values 1 2>");
    check_eq("values of none",             eval_to_string("(values)"),        "#<values>");
    check_eq("values keeps write form",    eval_to_string("(values \"a\" 1)"),
                                           "#<values \"a\" 1>");
    check_eq("values->list of a box",  eval_to_string("(%values->list (values 1 2))"), "(1 2)");
    check_eq("values->list of one",    eval_to_string("(%values->list 7)"),            "(7)");
    check_eq("values->list of none",   eval_to_string("(%values->list (values))"),     "NIL");

    // --- ポート（10日目の決定46〜50）---
    // 標準ポートは**値**として1つずつあり、毎回作り直さない
    check_eq("current-output-port", eval_to_string("(current-output-port)"), "#<output-port>");
    check_eq("current-input-port",  eval_to_string("(current-input-port)"),  "#<input-port>");
    check_eq("std port is one value",
             eval_to_string("(eq? (current-input-port) (current-input-port))"), "TRUE");
    // R5RS では変数ではなく手続き
    check_eq("current-output-port is a procedure",
             eval_to_string("(procedure? current-output-port)"), "TRUE");
    check_eq("input-port?",  eval_to_string("(input-port? (current-input-port))"),  "TRUE");
    check_eq("output-port?", eval_to_string("(output-port? (current-output-port))"), "TRUE");
    check_eq("port direction",
             eval_to_string("(output-port? (current-input-port))"), "FALSE");
    check_eq("non-port", eval_to_string("(input-port? 5)"), "FALSE");
    // 標準ポートを閉じさせない（決定46）。ここが壊れると以後の printf が
    // すべて消えるので、この check より後ろの出力が消えること自体が兆候になる
    check_eq("std port never closes",
             eval_to_string("(close-output-port (current-output-port))"
                            "(output-port? (current-output-port))"), "TRUE");

    // 長いリストの equal? が C スタックを溢れさせないこと（§5.2）
    check_eq("long equal?",
             eval_to_string("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))"
                            "(equal? (build 200000 '()) (build 200000 '()))"), "TRUE");
}

// --- REPL ------------------------------------------------------------------

static bool is_balanced(const std::string& s) {
    int depth = 0;
    bool in_string = false, in_comment = false;
    for (std::size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c == '\n') { in_comment = false; continue; }
        if (in_comment) continue;
        if (c == ';' && !in_string) { in_comment = true; continue; }
        if (c == '"' && (i == 0 || s[i - 1] != '\\')) { in_string = !in_string; continue; }
        if (in_string) continue;
        if (c == '(') ++depth;
        else if (c == ')') { if (--depth < 0) return false; }
    }
    return depth == 0 && !in_string;
}

static std::string read_multiline_input() {
    std::string acc, line;
    bool first = true;
    for (;;) {
        std::fputs(first ? "scheme13> " : "       ...> ", stdout);
        std::fflush(stdout);
        first = false;
        int c;
        line.clear();
        bool got = false;
        while ((c = std::fgetc(stdin)) != EOF) { got = true; if (c == '\n') break; line.push_back(static_cast<char>(c)); }
        if (!got && c == EOF) return "";
        if (line.empty() && acc.empty()) return "";
        if (!acc.empty()) acc += "\n";
        acc += line;
        if (is_balanced(acc)) return acc;
    }
}

static int run_repl() {
    std::printf("scheme13 debug REPL. Type (help) for commands, (exit) to quit.\n");
    int repl_count = 0;
    for (;;) {
        std::string input = read_multiline_input();
        if (input.empty()) {
            if (std::feof(stdin)) { std::printf("\nBye!\n"); break; }
            continue;
        }
        try {
            std::uint16_t id = source_intern("<stdin:" + std::to_string(++repl_count) + ">",
                                             input);
            for (const TopForm& f : read_all(id))
                std::printf("%s\n", to_string(eval_top(f.expr, f.pos)).c_str());
        } catch (const SchemeError& ex) {
            std::fprintf(stderr, "Error: %s\n", format_error(ex).c_str());
        } catch (const std::exception& ex) {
            std::fprintf(stderr, "Error: %s\n", ex.what());
        }
    }
    return 0;
}

static void usage() {
    std::printf(
        "scheme13 (SECD with Boost bignum + Debug)\n"
        "Usage:\n"
        "  scheme13                Start interactive REPL ((exit) or Ctrl-D to quit)\n"
        "  scheme13 --load FILE    Evaluate file and exit\n"
        "  scheme13 --selftest     Check against the frozen spec\n"
        "  scheme13 --read FILE    Print the S-expressions as read\n"
        "  scheme13 --expand FILE  Print the S-expressions after syntax expansion\n"
        "  scheme13 --help         Show this help\n");
}

// --expand 用。フォームとその部分式を、書き換えられなくなるまで展開する。
// **コンパイラの経路とは別物**（コンパイラは comp() の中で必要なときだけ
// expand_form_1 を呼ぶ）。展開器が実コードで落ちないことを見るための道具。
static ValuePtr expand_all(ValuePtr x) {
    if (!is_pair(x)) return x;
    ValuePtr f = x;
    for (int guard = 0; guard < 100; ++guard) {
        if (!is_pair(f) || is_symbol_named(as_pair(f)->car, "quote")) return f;
        ValuePtr g = expand_form_1(f);
        if (g == f) break;
        f = g;
    }
    if (!is_pair(f) || is_symbol_named(as_pair(f)->car, "quote")) return f;

    ValueVec items;
    ValuePtr tail = f;
    while (is_pair(tail)) {                     // cdr 方向はループ（§4.3）
        items.push_back(expand_all(as_pair(tail)->car));
        tail = as_pair(tail)->cdr;
    }
    ValuePtr out = tail;
    for (std::size_t i = items.size(); i > 0; --i) out = make_pair(items[i - 1], out);
    return with_pos_of(out, f);
}

int main(int argc, char** argv) {
    GC_INIT();
    GC_set_max_heap_size(1024ULL * 1024 * 1024);
    GC_set_free_space_divisor(4);

    try {
        value_model_init();
        source_table_init();
        init_globals();

        std::string mode = (argc > 1) ? argv[1] : "";

        if (mode == "--selftest") {
            selftest_display();
            selftest_reader();
            selftest_expand();
            selftest_positions();
            selftest_eval();
            selftest_errors();
            selftest_macro_positions();
            selftest_macroexpand();
            selftest_test_matching();
            std::printf("\n  %d checks, %d failed\n", g_checks, g_failures);
            return g_failures == 0 ? 0 : 1;
        }

        if ((mode == "--read" || mode == "--expand") && argc > 2) {
            std::uint16_t id = source_intern(argv[2], slurp_file(argv[2]));
            bool expand = (mode == "--expand");
            for (const TopForm& f : read_all(id))
                std::printf("%s\n", to_string(expand ? expand_all(f.expr) : f.expr).c_str());
            return 0;
        }

        load_startup_libraries(argv[0]);

        if (mode == "--help" || mode == "-h") { usage(); return 0; }
        if (mode == "--load") {
            if (argc < 3) { std::fprintf(stderr, "scheme13: --load needs a path\n"); return 1; }
            std::printf("%s\n", to_string(load_from_path(argv[2])).c_str());
            return 0;
        }
        if (!mode.empty()) {
            std::fprintf(stderr, "scheme13: unknown arg: %s\ntry: scheme13 --help\n",
                         mode.c_str());
            return 1;
        }
        return run_repl();

    // (exit) の終了要求（決定64）。ここまで素通りさせ、普通に return する
    // ことで stdio が開いている出力ポートを流して閉じる。
    } catch (const SchemeExit& e) {
        std::fflush(stdout);
        return e.code;
    } catch (const SchemeError& e) {
        std::fflush(stdout);
        std::fprintf(stderr, "Fatal error: %s\n", format_error(e).c_str());
        return 1;
    } catch (const std::exception& e) {
        std::fflush(stdout);
        std::fprintf(stderr, "Fatal error: %s\n", e.what());
        return 1;
    }
}
