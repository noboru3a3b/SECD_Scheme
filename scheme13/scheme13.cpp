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
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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
};

// 添字 0 は「位置なし」を表す番兵。ファイル id は 16bit なので上限 65535。
static RootVec<SourceFile> g_sources;

static void source_table_init() {
    if (g_sources.empty()) g_sources.push_back(SourceFile{to_gc("<unknown>"), GcString()});
}

// ソースを登録して id を返す。上限を超えたら 0（位置なし）を返す。
static std::uint16_t source_intern(const std::string& name, const std::string& text) {
    source_table_init();
    if (g_sources.size() >= 0xFFFFu) return 0;
    g_sources.push_back(SourceFile{to_gc(name), to_gc(text)});
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

static std::string source_name(const SourcePos& pos) {
    if (!pos.known() || pos.file >= g_sources.size()) return "<unknown>";
    return to_std(g_sources[pos.file].name);
}

// 処理系が投げる唯一の例外型。位置は任意（known() が false なら位置なし）。
struct SchemeError : std::runtime_error {
    SourcePos pos;
    SchemeError(const std::string& msg, SourcePos p)
        : std::runtime_error(msg), pos(p) {}
};

[[noreturn]] static void error_at(const SourcePos& pos, const std::string& msg) {
    throw SchemeError(msg, pos);
}
[[noreturn]] static void error_here(const std::string& msg) {
    throw SchemeError(msg, SourcePos{});
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
    out += source_name(e.pos);
    out += ":" + std::to_string(e.pos.line) + ":" + std::to_string(e.pos.col) + ": ";
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
struct Code;
using ValuePtr = Object*;
using CodePtr  = Code*;
using ValueVec = GcVec<ValuePtr>;

enum class Tag : std::uint8_t {
    Fixnum,       // ヘッダを持たない即値。tag_of() だけが返す
    Nil, Boolean, Bignum, String, Symbol, Pair, Vector,
    Closure, Continuation, Primitive, Macro, SpecialForm, Port, Eof
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

struct Closure : Object {
    GcVec<GcString>          params;
    std::optional<GcString>  rest;
    CodePtr                  body = nullptr;
    // 環境の表現はセクション10（VM）で確定する。
    ValueVec                 env;
    Closure() : Object(Tag::Closure) {}
};

struct Continuation : Object {
    // 中身（s/e/c/pc/d）はセクション10（VM）で確定する。
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
struct Port : Object {
    std::FILE* fp;
    bool is_input;
    bool is_closed;
    Port(std::FILE* f, bool input)
        : Object(Tag::Port), fp(f), is_input(input), is_closed(false) {}
    void close() {
        if (fp && !is_closed) { std::fclose(fp); is_closed = true; fp = nullptr; }
    }
};

// --- シングルトン ----------------------------------------------------------

static ValuePtr g_nil   = nullptr;
static ValuePtr g_true  = nullptr;
static ValuePtr g_false = nullptr;
static ValuePtr g_eof   = nullptr;

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
    Port* p = new Port(fp, is_input);
    GC_REGISTER_FINALIZER_IGNORE_SELF(p, port_finalizer, nullptr, nullptr, nullptr);
    return p;
}

// --- 述語 ------------------------------------------------------------------

static inline bool is_nil(ValuePtr v)     { return v == g_nil; }
static inline bool is_pair(ValuePtr v)    { return has_tag(v, Tag::Pair); }
static inline bool is_string(ValuePtr v)  { return has_tag(v, Tag::String); }
static inline bool is_vector(ValuePtr v)  { return has_tag(v, Tag::Vector); }
static inline bool is_symbol(ValuePtr v)  { return has_tag(v, Tag::Symbol); }
static inline bool is_number(ValuePtr v)  { return is_fixnum(v) || has_tag(v, Tag::Bignum); }

// 偽なのは #f ただ一つ。nil も 0 も空文字列も真。（dev_memo.md §2）
static inline bool is_false(ValuePtr v) { return v == g_false; }
static inline bool is_true(ValuePtr v)  { return v != g_false; }

static bool is_symbol_named(ValuePtr v, std::string_view name) {
    return is_symbol(v) && view_of(static_cast<Symbol*>(v)->name) == name;
}

// --- アクセサ --------------------------------------------------------------

static Pair* as_pair(ValuePtr v) {
    if (!is_pair(v)) error_here("expected pair");
    return static_cast<Pair*>(v);
}
static GcString& as_string(ValuePtr v) {
    if (!is_string(v)) error_here("expected string");
    return static_cast<Str*>(v)->s;
}
static Vector* as_vector(ValuePtr v) {
    if (!is_vector(v)) error_here("expected vector");
    return static_cast<Vector*>(v);
}
static const GcString& as_symbol_name(ValuePtr v) {
    if (!is_symbol(v)) error_here("expected symbol");
    return static_cast<Symbol*>(v)->name;
}
static BigInt as_bigint(ValuePtr v) {
    if (is_fixnum(v)) return BigInt(static_cast<long long>(fixnum_value(v)));
    if (has_tag(v, Tag::Bignum)) return static_cast<Bignum*>(v)->v;
    error_here("expected integer");
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

static void write_closure_params(std::string& out, Closure* c) {
    out += '(';
    for (std::size_t i = 0; i < c->params.size(); ++i) {
        if (i > 0) out += ' ';
        out.append(c->params[i].data(), c->params[i].size());
    }
    if (c->rest) {
        if (!c->params.empty()) out += " . ";
        out.append(c->rest->data(), c->rest->size());
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
            write_closure_params(out, static_cast<Closure*>(v));
            out += '>';
            return;
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
            write_closure_params(out, static_cast<Macro*>(v)->transformer);
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
    ValuePtr read_atom(const SourcePos& start) {
        std::string tok;
        while (!done() && !is_delimiter(peek())) tok += advance();
        if (tok.empty()) error_at(start, "empty token");

        if (tok == "nil")   return g_nil;
        if (tok == "true")  return g_true;
        if (tok == "false") return g_false;

        bool signed_head = (tok[0] == '-' || tok[0] == '+');
        bool numeric = std::isdigit(static_cast<unsigned char>(tok[0])) ||
                       (signed_head && tok.size() > 1);
        if (numeric) {
            for (std::size_t i = signed_head ? 1 : 0; i < tok.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(tok[i]))) { numeric = false; break; }
            }
            if (numeric) return make_int_from_text(tok);
        }
        return make_symbol(tok);
    }
};

static ValueVec read_all(std::uint16_t file_id) {
    Reader   r(file_id);
    ValueVec out;
    while (true) {
        ValuePtr x = r.read_expr();
        if (!x) break;
        out.push_back(x);
    }
    return out;
}

// ===========================================================================
// セクション 12. 起動（暫定）
// ===========================================================================
//
// コンパイラと VM がまだ無いので、今の main は
//   --selftest  セクション 3〜5 の自己テスト（凍結仕様との突き合わせ）
//   --read FILE 読んだ S 式をそのまま書き戻す（目視確認用）
// の 2 つだけを持つ。REPL と --load はセクション 8〜11 が入ってから。

static int  g_checks = 0;
static int  g_failures = 0;

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
    Closure* c1 = new Closure();
    c1->params.push_back(to_gc("x"));
    c1->params.push_back(to_gc("y"));
    check_eq("closure", to_string(c1), "#<closure:(x y)>");

    Closure* c2 = new Closure();
    c2->params.push_back(to_gc("x"));
    c2->rest = to_gc("r");
    check_eq("closure rest", to_string(c2), "#<closure:(x . r)>");

    Closure* c3 = new Closure();
    c3->rest = to_gc("args");
    check_eq("closure all-rest", to_string(c3), "#<closure:(args)>");

    check_eq("macro", to_string(new Macro(c1)), "(MACRO #<closure:(x y)>)");
    check_eq("primitive", to_string(make_primitive("car", nullptr)), "(PRIMITIVE car)");
    check_eq("special form", to_string(make_special_form("if")), "(SPECIAL-FORM if)");
    check_eq("continuation", to_string(new Continuation()), "#<continuation>");
    check_eq("eof", to_string(g_eof), "#<eof>");

    ValuePtr port = make_port(nullptr, true);
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
        ValueVec xs = read_all(id);
        check_eq("brackets: count", std::to_string(xs.size()), "2");
        if (xs.size() == 2) {
            check_eq("brackets: 1st", to_string(xs[0]), "(quote [1)");
            check_eq("brackets: 2nd", to_string(xs[1]), "2]");
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

    // コメントと複数行
    {
        std::uint16_t id = source_intern("<selftest>", "; c\n(a\n b) ; c2\n(c)");
        ValueVec xs = read_all(id);
        check_eq("comments: count", std::to_string(xs.size()), "2");
        if (xs.size() == 2) check_eq("comments: 1st", to_string(xs[0]), "(a b)");
    }
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

static bool read_file(const std::string& path, std::string& out) {
    std::FILE* fp = std::fopen(path.c_str(), "rb");
    if (!fp) return false;
    char buf[65536];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, fp)) > 0) out.append(buf, n);
    std::fclose(fp);
    return true;
}

int main(int argc, char** argv) {
    GC_INIT();
    value_model_init();
    source_table_init();

    std::string mode = (argc > 1) ? argv[1] : "--selftest";

    try {
        if (mode == "--selftest") {
            selftest_display();
            selftest_reader();
            selftest_positions();
            std::printf("\n  %d checks, %d failed\n", g_checks, g_failures);
            return g_failures == 0 ? 0 : 1;
        }
        if (mode == "--read" && argc > 2) {
            std::string text;
            if (!read_file(argv[2], text)) {
                std::fprintf(stderr, "scheme13: cannot open file: %s\n", argv[2]);
                return 1;
            }
            std::uint16_t id = source_intern(argv[2], text);
            for (ValuePtr x : read_all(id)) std::printf("%s\n", to_string(x).c_str());
            return 0;
        }
        std::fprintf(stderr,
            "scheme13 (作りかけ: セクション 1-5 のみ)\n"
            "  scheme13 --selftest      凍結仕様との突き合わせ\n"
            "  scheme13 --read FILE     読んだ S 式を書き戻す\n");
        return 1;
    } catch (const SchemeError& e) {
        std::fprintf(stderr, "Fatal error: %s\n", format_error(e).c_str());
        return 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Fatal error: %s\n", e.what());
        return 1;
    }
}
