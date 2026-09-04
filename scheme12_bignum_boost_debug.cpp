// scheme12_bignum_boost_debug.cpp
// デバッグ機能付き改良版
// Part 1
#include <algorithm>
#include <cctype>
#include <climits>  // LLONG_MAX用に明示的に追加
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>
#include <iomanip>
#include <random>
#include <unordered_set>  // 循環検出用

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
// ここで追加宣言して limb 配列を GC_MALLOC_ATOMIC で確保させる
// （＝GC のスキャン対象から外し、数値のビット列がポインタと誤認されて
//   ゴミを保持してしまう保守的 GC の偽retentionも防ぐ）。
GC_DECLARE_PTRFREE(unsigned long long);

// Scheme の文字列値は GC 管理下のバッファに置く。
// char は ptr-free 宣言済みなので GC_MALLOC_ATOMIC で確保される。
using GcString = std::basic_string<char, std::char_traits<char>, gc_allocator<char> >;
static inline std::string to_std(const GcString& s) { return std::string(s.data(), s.size()); }
static inline GcString to_gc(const std::string& s) { return GcString(s.data(), s.size()); }

#if __has_include(<boost/multiprecision/cpp_int.hpp>)
#include <boost/multiprecision/cpp_int.hpp>
#define HAS_BIGNUM
// cpp_int の limb 配列は Boehm GC 管理下に置く。
// gc 継承クラスはデストラクタが呼ばれないため、既定の std::allocator
// （libgccpp により GC_MALLOC_UNCOLLECTABLE へ差し替えられる）だと
// limb 配列が回収されずルート集合に残り続けてしまう。
using BigIntType = boost::multiprecision::number<
    boost::multiprecision::cpp_int_backend<0, 0,
        boost::multiprecision::signed_magnitude,
        boost::multiprecision::unchecked,
        gc_allocator<unsigned long long> > >;
#else
#warning "Boost.Multiprecision not found. Using long long (limited precision)."
using BigIntType = long long;
#endif

// 前方宣言
struct Value;
struct Pair;
struct Closure;
struct Continuation;
struct DumpFrame;
struct Instruction;
struct Code;
struct FilePort;

// Bignum wrapper
struct BigInt : public gc {
    BigIntType value;
    BigInt() : value(0) {}
#ifdef HAS_BIGNUM
    explicit BigInt(const BigIntType& v) : value(v) {}
#endif
    explicit BigInt(long long v) : value(v) {}
    explicit BigInt(const std::string& s, int base = 10) {
        (void)base;
#ifdef HAS_BIGNUM
        value = BigIntType(s);
#else
        value = std::stoll(s);
#endif
    }
    
    BigInt operator+(const BigInt& other) const { return BigInt(BigIntType(value + other.value)); }
    BigInt operator-(const BigInt& other) const { return BigInt(BigIntType(value - other.value)); }
    BigInt operator*(const BigInt& other) const { return BigInt(BigIntType(value * other.value)); }
    BigInt operator/(const BigInt& other) const { return BigInt(BigIntType(value / other.value)); }
    BigInt operator%(const BigInt& other) const { return BigInt(BigIntType(value % other.value)); }
    BigInt operator-() const { return BigInt(BigIntType(-value)); }
    
    bool operator==(const BigInt& other) const { return value == other.value; }
    bool operator!=(const BigInt& other) const { return value != other.value; }
    bool operator<(const BigInt& other) const { return value < other.value; }
    bool operator>(const BigInt& other) const { return value > other.value; }
    bool operator<=(const BigInt& other) const { return value <= other.value; }
    bool operator>=(const BigInt& other) const { return value >= other.value; }
    
    std::string to_string() const {
#ifdef HAS_BIGNUM
        return value.str();
#else
        return std::to_string(value);
#endif
    }
    bool is_zero() const { return value == 0; }
};

// gc ではなく gc_cleanup を継承する。gc 継承だけではデストラクタが
// 一度も呼ばれず、到達不能になったポートの FILE* が閉じられないまま
// ディスクリプタを食い潰す（close 忘れで数百個開くと EMFILE になる）。
// gc_cleanup はファイナライザを登録し、回収時に ~FilePort を実行する。
struct FilePort : public gc_cleanup {
    std::FILE* fp;
    bool is_input;
    bool is_closed;
    
    FilePort(std::FILE* f, bool input) : fp(f), is_input(input), is_closed(false) {}
    ~FilePort() {
        if (fp && !is_closed) std::fclose(fp);
    }
    void close() {
        if (fp && !is_closed) {
            std::fclose(fp);
            is_closed = true;
            fp = nullptr;
        }
    }
};

using ValuePtr = Value*;
using PairPtr = Pair*;
using ClosurePtr = Closure*;
using ContPtr = Continuation*;
using CodePtr = Code*;
using BigIntPtr = BigInt*;
using FilePortPtr = FilePort*;
using ValueVec = std::vector<ValuePtr, gc_allocator<ValuePtr>>;
struct DumpNode;
using DumpPtr = DumpNode*;
using StringValueMap = std::unordered_map<std::string, ValuePtr,
    std::hash<std::string>, std::equal_to<std::string>,
    traceable_allocator<std::pair<const std::string, ValuePtr>>>;

struct Vector : public gc {
    ValueVec elements;
    Vector() = default;
    explicit Vector(std::size_t size, ValuePtr init = nullptr) {
        elements.resize(size, init);
    }
    explicit Vector(const ValueVec& elems) : elements(elems) {}
    std::size_t size() const { return elements.size(); }
    ValuePtr& at(std::size_t idx) { return elements.at(idx); }
    const ValuePtr& at(std::size_t idx) const { return elements.at(idx); }
};

using VectorPtr = Vector*;

struct Symbol { std::string name; };
struct NilTag {};

struct Pair : public gc {
    ValuePtr car;
    ValuePtr cdr;
    Pair(ValuePtr a, ValuePtr d) : car(a), cdr(d) {}
};

struct Closure : public gc {
    std::vector<std::string, gc_allocator<std::string>> params;
    std::optional<std::string> rest_param;
    CodePtr body;
    ValueVec captured_env;
    Closure(std::vector<std::string, gc_allocator<std::string>> p, std::optional<std::string> r, 
            CodePtr b, ValueVec env)
        : params(std::move(p)), rest_param(std::move(r)), body(b), captured_env(std::move(env)) {}
};

struct Macro : public gc {
    ClosurePtr transformer;
    explicit Macro(ClosurePtr t) : transformer(t) {}
};

using MacroPtr = Macro*;

struct SpecialForm : public gc {
    std::string name;
    explicit SpecialForm(const std::string& n) : name(n) {}
};

using SpecialFormPtr = SpecialForm*;

struct DumpFrame {
    ValueVec s;
    ValueVec e;
    CodePtr c;
    std::size_t pc;
};

// ダンプは永続リンクリスト。push はノード1個の確保、pop はポインタの付け替えで、
// 継続の捕捉は「今の先頭ポインタを持つ」だけの O(1) になる。
// ノードは不変なので、捕捉後に VM 側が push/pop しても捕捉済みの鎖は壊れない。
struct DumpNode : public gc {
    DumpFrame frame;
    DumpPtr next;
    std::size_t depth;
    DumpNode(DumpFrame f, DumpPtr n)
        : frame(std::move(f)), next(n), depth(n ? n->depth + 1 : 1) {}
};

static inline DumpPtr dump_push(DumpPtr d, DumpFrame f) {
    return new DumpNode(std::move(f), d);
}
static inline std::size_t dump_depth(DumpPtr d) { return d ? d->depth : 0; }

struct Continuation : public gc {
    ValueVec s;
    ValueVec e;
    CodePtr c;
    std::size_t pc;
    DumpPtr d;
    Continuation(ValueVec st, ValueVec en, CodePtr code, std::size_t p, DumpPtr dump)
        : s(std::move(st)), e(std::move(en)), c(code), pc(p), d(dump) {}
};

using PrimitiveFn = std::function<ValuePtr(const ValueVec&)>;

struct PrimitiveInfo : public gc {
    std::string name;
    PrimitiveFn fn;
    PrimitiveInfo(std::string n, PrimitiveFn f) : name(std::move(n)), fn(std::move(f)) {}
};

using PrimitiveInfoPtr = PrimitiveInfo*;

// 専用タグ（EOF用）
struct EofTag {};

struct Value : public gc {
    using Data = std::variant<NilTag, bool, BigIntPtr, GcString, Symbol, PairPtr, 
                             ClosurePtr, ContPtr, PrimitiveInfoPtr, FilePortPtr, VectorPtr, 
                             MacroPtr, SpecialFormPtr, EofTag>;  // ← EofTag追加
    Data data;
    explicit Value(Data d) : data(std::move(d)) {}
};

enum class Op {
    LD, LDC, LDG, LDF, ARGS, ARGS_AP, APP, TAPP, RTN,
    SEL, SELR, JOIN, POP, DEF, DEFM, LSET, GSET, LDCT, CALLCC, TCALLCC, STOP
};

struct Instruction {
    Op op;
    int a = 0;
    int b = 0;
    std::string sym;
    ValuePtr constant;
    CodePtr ct;
    CodePtr cf;
    CodePtr lambda_code;
    std::vector<std::string, gc_allocator<std::string>> lambda_params;
    std::optional<std::string> lambda_rest;
};

struct Code : public gc {
    std::vector<Instruction, gc_allocator<Instruction>> ins;
};

static ValuePtr g_nil = nullptr;
static ValuePtr g_true = nullptr;   // 追加
static ValuePtr g_false = nullptr;  // 追加
static StringValueMap g_globals;
static StringValueMap g_macros;
static StringValueMap g_symbol_intern;
static bool g_trace_mode = false;
static std::mt19937 g_random_engine;
static bool g_random_initialized = false;

[[noreturn]] static void vm_error(const std::string& msg) {
    throw std::runtime_error("scheme12 VM error: " + msg);
}

static ValuePtr make_value(Value::Data d) { return new Value(std::move(d)); }
static CodePtr make_code() { return new Code(); }

static ValuePtr make_bool(bool b) { 
    if (b) {
        if (!g_true) g_true = make_value(true);
        return g_true;
    } else {
        if (!g_false) g_false = make_value(false);
        return g_false;
    }
}

static ValuePtr make_int(const BigInt& n) {
    BigIntPtr p = new BigInt(n);
    return make_value(p);
}

static ValuePtr make_int(const std::string& s, int base = 10) {
    return make_int(BigInt(s, base));
}

static ValuePtr make_string(const GcString& s) { return make_value(s); }
static ValuePtr make_string(const std::string& s) { return make_value(to_gc(s)); }

static ValuePtr make_symbol(const std::string& s) {
    auto it = g_symbol_intern.find(s);
    if (it != g_symbol_intern.end()) return it->second;
    ValuePtr v = make_value(Symbol{s});
    g_symbol_intern[s] = v;
    return v;
}

static ValuePtr make_pair(ValuePtr a, ValuePtr d) {
    PairPtr pair = new Pair(a, d);
    ValuePtr value = make_value(pair);
    GC_reachable_here(a);
    GC_reachable_here(d);
    GC_reachable_here(pair);
    return value;
}

static ValuePtr make_closure(const std::vector<std::string, gc_allocator<std::string>>& params, 
                             std::optional<std::string> rest, CodePtr body, const ValueVec& env) {
    ClosurePtr closure = new Closure(params, std::move(rest), body, env);
    ValuePtr value = make_value(closure);
    GC_reachable_here(body);
    GC_reachable_here(closure);
    return value;
}

static ValuePtr make_cont(const ValueVec& s, const ValueVec& e, CodePtr c, std::size_t pc, 
                         DumpPtr d) {
    ContPtr cont = new Continuation(s, e, c, pc, d);
    ValuePtr value = make_value(cont);
    GC_reachable_here(c);
    GC_reachable_here(cont);
    return value;
}

static ValuePtr make_prim(const std::string& name, PrimitiveFn fn) {
    PrimitiveInfoPtr info = new PrimitiveInfo(name, std::move(fn));
    return make_value(info);
}

static ValuePtr make_vector_value(VectorPtr vec) { return make_value(vec); }

static ValuePtr make_vector_value(std::size_t size, ValuePtr init = nullptr) {
    VectorPtr vec = new Vector(size, init ? init : g_nil);
    return make_vector_value(vec);
}

static ValuePtr make_vector_value(const ValueVec& elems) {
    VectorPtr vec = new Vector(elems);
    return make_vector_value(vec);
}

static ValuePtr make_special_form(const std::string& name) {
    SpecialFormPtr sf = new SpecialForm(name);
    return make_value(sf);
}

// EOF専用オブジェクト生成
static ValuePtr g_eof = nullptr;  // グローバル変数として追加

static ValuePtr make_eof_object() {
    if (!g_eof) {
        g_eof = make_value(EofTag{});
    }
    return g_eof;
}

static bool is_vector(const ValuePtr& v) {
    return v && std::holds_alternative<VectorPtr>(v->data);
}

static VectorPtr as_vector(const ValuePtr& v) {
    if (!is_vector(v)) vm_error("expected vector");
    return std::get<VectorPtr>(v->data);
}

static bool is_string(const ValuePtr& v) {
    return v && std::holds_alternative<GcString>(v->data);
}

static GcString& as_string(const ValuePtr& v) {
    if (!is_string(v)) vm_error("expected string");
    return std::get<GcString>(v->data);
}

static bool is_nil(const ValuePtr& v) {
    return !v || std::holds_alternative<NilTag>(v->data);
}

static bool is_false(const ValuePtr& v) {
    if (is_nil(v)) return false;
    if (std::holds_alternative<bool>(v->data)) return !std::get<bool>(v->data);
    return false;
}

static bool is_true(const ValuePtr& v) { return !is_false(v); }
static bool is_pair(const ValuePtr& v) { return v && std::holds_alternative<PairPtr>(v->data); }

static bool is_symbol(const ValuePtr& v, const std::string& name = "") {
    if (!v || !std::holds_alternative<Symbol>(v->data)) return false;
    if (name.empty()) return true;
    return std::get<Symbol>(v->data).name == name;
}

static PairPtr as_pair(const ValuePtr& v) {
    if (!is_pair(v)) vm_error("expected pair");
    return std::get<PairPtr>(v->data);
}

static BigInt& as_int(const ValuePtr& v) {
    if (!v || !std::holds_alternative<BigIntPtr>(v->data)) vm_error("expected integer");
    return *std::get<BigIntPtr>(v->data);
}

static std::string as_symbol_name(const ValuePtr& v) {
    if (!is_symbol(v)) vm_error("expected symbol");
    return std::get<Symbol>(v->data).name;
}

static ValuePtr car(const ValuePtr& v) { return as_pair(v)->car; }
static ValuePtr cdr(const ValuePtr& v) { return as_pair(v)->cdr; }

// 命令を文字列化
static std::string op_to_string(Op op) {
    switch (op) {
        case Op::LD: return "LD";
        case Op::LDC: return "LDC";
        case Op::LDG: return "LDG";
        case Op::LDF: return "LDF";
        case Op::ARGS: return "ARGS";
        case Op::ARGS_AP: return "ARGS-AP";
        case Op::APP: return "APP";
        case Op::TAPP: return "TAPP";
        case Op::RTN: return "RTN";
        case Op::SEL: return "SEL";
        case Op::SELR: return "SELR";
        case Op::JOIN: return "JOIN";
        case Op::POP: return "POP";
        case Op::DEF: return "DEF";
        case Op::DEFM: return "DEFM";
        case Op::LSET: return "LSET";
        case Op::GSET: return "GSET";
        case Op::LDCT: return "LDCT";
        case Op::CALLCC: return "CALLCC";
        case Op::TCALLCC: return "TCALLCC";
        case Op::STOP: return "STOP";
        default: return "???";
    }
}

static std::string to_string(const ValuePtr& v);

static std::string instruction_to_string(const Instruction& ins, int indent = 0) {
    std::string prefix(indent * 2, ' ');
    std::ostringstream oss;
    oss << prefix << op_to_string(ins.op);
    
    switch (ins.op) {
        case Op::LD:
            oss << " (" << ins.a << " . " << ins.b << ")";
            break;
        case Op::LDC:
            oss << " " << to_string(ins.constant);
            break;
        case Op::LDG:
        case Op::DEF:
        case Op::DEFM:
        case Op::GSET:
            oss << " " << ins.sym;
            break;
        case Op::LDF:
            oss << " (";
            for (size_t i = 0; i < ins.lambda_params.size(); ++i) {
                if (i > 0) oss << " ";
                oss << ins.lambda_params[i];
            }
            if (ins.lambda_rest) {
                if (!ins.lambda_params.empty()) oss << " . ";
                oss << *ins.lambda_rest;
            }
            oss << ")";
            break;
        case Op::LSET:
            oss << " (" << ins.a << " . " << ins.b << ")";
            break;
        case Op::ARGS:
        case Op::ARGS_AP:
            oss << " " << ins.a;
            break;
        case Op::SEL:
        case Op::SELR:
            oss << " [THEN-BRANCH] [ELSE-BRANCH]";
            break;
        default:
            break;
    }
    return oss.str();
}

static std::string code_to_string(CodePtr code, int indent = 0) {
    if (!code || code->ins.empty()) return "(empty)";
    std::ostringstream oss;
    oss << "\n";
    for (size_t i = 0; i < code->ins.size(); ++i) {
        oss << std::string(indent * 2, ' ') << "[" << std::setw(3) << i << "] ";
        oss << instruction_to_string(code->ins[i], 0) << "\n";
    }
    return oss.str();
}

// 詳細表示用
static std::string instruction_to_string_detailed(const Instruction& ins, int indent = 0, int max_depth = 10);
static std::string code_to_string_detailed(CodePtr code, int indent = 0, int max_depth = 10);

static std::string instruction_to_string_detailed(const Instruction& ins, int indent, int max_depth) {
    std::string prefix(indent * 2, ' ');
    std::ostringstream oss;
    oss << op_to_string(ins.op);
    
    switch (ins.op) {
        case Op::LD:
            oss << " (" << ins.a << " . " << ins.b << ")";
            break;
        case Op::LDC:
            oss << " " << to_string(ins.constant);
            break;
        case Op::LDG:
        case Op::DEF:
        case Op::DEFM:
        case Op::GSET:
            oss << " " << ins.sym;
            break;
        case Op::LDF:
            oss << " (";
            for (size_t i = 0; i < ins.lambda_params.size(); ++i) {
                if (i > 0) oss << " ";
                oss << ins.lambda_params[i];
            }
            if (ins.lambda_rest) {
                if (!ins.lambda_params.empty()) oss << " . ";
                oss << *ins.lambda_rest;
            }
            oss << ")";
            if (ins.lambda_code && max_depth > 0) {
                oss << "\n" << prefix << "  Lambda body:";
                oss << code_to_string_detailed(ins.lambda_code, indent + 2, max_depth - 1);
            }
            break;
        case Op::LSET:
            oss << " (" << ins.a << " . " << ins.b << ")";
            break;
        case Op::ARGS:
        case Op::ARGS_AP:
            oss << " " << ins.a;
            break;
        case Op::SEL:
        case Op::SELR:
            if (max_depth > 0) {
                if (ins.ct) {
                    oss << "\n" << prefix << "  THEN:";
                    oss << code_to_string_detailed(ins.ct, indent + 2, max_depth - 1);
                }
                if (ins.cf) {
                    oss << "\n" << prefix << "  ELSE:";
                    oss << code_to_string_detailed(ins.cf, indent + 2, max_depth - 1);
                }
            } else {
                oss << " [THEN-BRANCH] [ELSE-BRANCH] (max depth reached)";
            }
            break;
        default:
            break;
    }
    return oss.str();
}

static std::string code_to_string_detailed(CodePtr code, int indent, int max_depth) {
    if (!code || code->ins.empty()) return "\n" + std::string(indent * 2, ' ') + "(empty)";
    if (max_depth < 0) return "\n" + std::string(indent * 2, ' ') + "(max depth reached)";
    
    std::ostringstream oss;
    oss << "\n";
    for (size_t i = 0; i < code->ins.size(); ++i) {
        oss << std::string(indent * 2, ' ') << "[" << std::setw(3) << i << "] ";
        oss << instruction_to_string_detailed(code->ins[i], indent, max_depth) << "\n";
    }
    return oss.str();
}

static ValuePtr list_from_vector(const ValueVec& xs) {
    ValuePtr out = g_nil;
    for (auto it = xs.rbegin(); it != xs.rend(); ++it) {
        out = make_pair(*it, out);
    }
    GC_reachable_here(xs.data());
    return out;
}

static ValuePtr list_from_vector(std::initializer_list<ValuePtr> xs) {
    ValueVec temp(xs.begin(), xs.end());
    return list_from_vector(temp);
}

// 循環検出付きvector_from_list
static ValueVec vector_from_list(ValuePtr ls) {
    ValueVec out;
    std::unordered_set<void*> visited;
    
    while (!is_nil(ls)) {
        if (!is_pair(ls)) vm_error("expected proper list");
        
        // 循環検出
        void* addr = static_cast<void*>(std::get<PairPtr>(ls->data));
        if (visited.count(addr)) {
            vm_error("circular list detected in vector_from_list");
        }
        visited.insert(addr);
        
        out.push_back(car(ls));
        ls = cdr(ls);
    }
    return out;
}

// 循環検出付きto_string（内部用）
static std::string to_string_with_visited(const ValuePtr& v, 
                                          std::unordered_set<void*>& visited);

// 循環検出付きlist_to_string
// visited は「いま辿っている経路上にあるノード」の集合。car へ降りるときも
// 同じ集合を引き回し、走査を終えたら自分が入れた分だけ取り除く（バックトラック）。
// 以前は car を to_string() で出力していたため visited が毎回作り直され、
// car 方向の循環（(set-car! x x) など）を検出できずスタックを溢れさせていた。
// erase しないと共有構造（DAG）を循環と誤判定するので、経路を記録して戻す。
static std::string list_to_string_with_visited(ValuePtr ls, 
                                               std::unordered_set<void*>& visited) {
    std::ostringstream oss;
    oss << "(";
    bool first = true;
    std::vector<void*> path;  // この呼び出しで visited に入れたノード
    
    while (!is_nil(ls)) {
        if (!is_pair(ls)) {
            oss << " . " << to_string_with_visited(ls, visited);
            break;
        }
        
        // 循環検出
        void* addr = static_cast<void*>(std::get<PairPtr>(ls->data));
        if (!visited.insert(addr).second) {
            oss << " . #<circular>";
            break;
        }
        path.push_back(addr);
        
        if (!first) oss << " ";
        first = false;
        oss << to_string_with_visited(car(ls), visited);
        ls = cdr(ls);
    }
    oss << ")";
    for (void* a : path) visited.erase(a);
    return oss.str();
}

static std::string list_to_string(ValuePtr ls) {
    std::unordered_set<void*> visited;
    return list_to_string_with_visited(ls, visited);
}

static std::string vector_to_string_with_visited(VectorPtr vec,
                                                 std::unordered_set<void*>& visited) {
    void* addr = static_cast<void*>(vec);
    
    // 循環検出
    if (visited.count(addr)) {
        return "#<circular-vector>";
    }
    visited.insert(addr);
    
    std::ostringstream oss;
    oss << "#(";
    for (std::size_t i = 0; i < vec->size(); ++i) {
        if (i > 0) oss << " ";
        oss << to_string_with_visited(vec->at(i), visited);
    }
    oss << ")";
    
    visited.erase(addr);  // バックトラック
    return oss.str();
}

static std::string to_string_with_visited(const ValuePtr& v, 
                                          std::unordered_set<void*>& visited) {
    if (is_nil(v)) return "NIL";
    if (std::holds_alternative<bool>(v->data)) 
        return std::get<bool>(v->data) ? "TRUE" : "FALSE";
    if (std::holds_alternative<BigIntPtr>(v->data)) 
        return std::get<BigIntPtr>(v->data)->to_string();
    if (std::holds_alternative<GcString>(v->data)) 
        return "\"" + to_std(std::get<GcString>(v->data)) + "\"";
    if (std::holds_alternative<Symbol>(v->data)) 
        return std::get<Symbol>(v->data).name;
    if (std::holds_alternative<PairPtr>(v->data)) 
        return list_to_string_with_visited(v, visited);
    
    if (std::holds_alternative<ClosurePtr>(v->data)) {
        ClosurePtr clo = std::get<ClosurePtr>(v->data);
        std::ostringstream oss;
        oss << "#<closure:(";
        for (size_t i = 0; i < clo->params.size(); ++i) {
            if (i > 0) oss << " ";
            oss << clo->params[i];
        }
        if (clo->rest_param) {
            if (!clo->params.empty()) oss << " . ";
            oss << *clo->rest_param;
        }
        oss << ")>";
        return oss.str();
    }
    
    if (std::holds_alternative<ContPtr>(v->data)) return "#<continuation>";
    
    if (std::holds_alternative<PrimitiveInfoPtr>(v->data)) {
        PrimitiveInfoPtr info = std::get<PrimitiveInfoPtr>(v->data);
        return "(PRIMITIVE " + info->name + ")";
    }
    
    if (std::holds_alternative<MacroPtr>(v->data)) {
        MacroPtr macro = std::get<MacroPtr>(v->data);
        return "(MACRO " + to_string(make_value(macro->transformer)) + ")";
    }
    
    if (std::holds_alternative<SpecialFormPtr>(v->data)) {
        SpecialFormPtr sf = std::get<SpecialFormPtr>(v->data);
        return "(SPECIAL-FORM " + sf->name + ")";
    }
    
    if (std::holds_alternative<FilePortPtr>(v->data)) {
        FilePortPtr port = std::get<FilePortPtr>(v->data);
        if (port->is_closed) return "#<closed-port>";
        return port->is_input ? "#<input-port>" : "#<output-port>";
    }
    
    if (std::holds_alternative<EofTag>(v->data)) return "#<eof>";
    
    if (std::holds_alternative<VectorPtr>(v->data)) {
        return vector_to_string_with_visited(std::get<VectorPtr>(v->data), visited);
    }
    
    return "#<unknown>";
}

static std::string to_string(const ValuePtr& v) {
    std::unordered_set<void*> visited;
    return to_string_with_visited(v, visited);
}

// Reader（角括弧サポート削除版）
struct Reader {
    explicit Reader(std::string src) : s(std::move(src)) {}
    std::string s;
    std::size_t p = 0;

    void skip_ws() {
        while (p < s.size()) {
            if (std::isspace(static_cast<unsigned char>(s[p]))) {
                ++p;
            } else if (s[p] == ';') {
                while (p < s.size() && s[p] != '\n') ++p;
            } else {
                break;
            }
        }
    }

    bool eof() {
        skip_ws();
        return p >= s.size();
    }

    char peek() {
        skip_ws();
        if (p >= s.size()) return '\0';
        return s[p];
    }

    char get() {
        if (p >= s.size()) return '\0';
        return s[p++];
    }

    ValuePtr read_expr() {
        skip_ws();
        if (p >= s.size()) return nullptr;
        char c = get();
        
        if (c == '#') {
            char next = peek();
            if (next == '(') {
                get();
                    return read_vector();
            }
            // #t と #f を直接処理（read_atom を呼ばない）
            if (next == 't' || next == 'T') {
                get();  // 't' を消費
                return make_bool(true);
            }
            if (next == 'f' || next == 'F') {
                get();  // 'f' を消費
                return make_bool(false);
            }
            // その他の # で始まるトークン（将来の拡張用）
            return read_atom(c);
        }
        
        if (c == '(') return read_list();
        if (c == '\'') {
            ValuePtr x = read_expr();
            return list_from_vector({make_symbol("quote"), x});
        }
        if (c == '`') {
            ValuePtr x = read_expr();
            return list_from_vector({make_symbol("quasiquote"), x});
        }
        if (c == ',') {
            if (peek() == '@') {
                get();
                ValuePtr x = read_expr();
                return list_from_vector({make_symbol("splice"), x});
            }
            ValuePtr x = read_expr();
            return list_from_vector({make_symbol("unquote"), x});
        }
        if (c == '"') return read_string();
        return read_atom(c);
    }

    ValuePtr read_vector() {
        ValueVec items;
        while (true) {
            skip_ws();
            if (p >= s.size()) vm_error("unexpected EOF in vector literal");
            if (peek() == ')') {
                get();
                return make_vector_value(items);
            }
            ValuePtr x = read_expr();
            // read_expr は入力を使い切ると nullptr を返す。ここで抜けないと
            // nullptr を積み続けて無限ループ（＝メモリ枯渇）になる。
            if (!x) vm_error("unexpected EOF in vector literal");
            items.push_back(x);
        }
    }

    ValuePtr read_string() {
        std::string out;
        while (p < s.size()) {
            char c = get();
            if (c == '"') break;
            if (c == '\\' && p < s.size()) {
                char n = get();
                if (n == 'n') out.push_back('\n');
                else out.push_back(n);
            } else {
                out.push_back(c);
            }
        }
        return make_string(out);
    }

    ValuePtr read_list() {
        skip_ws();
        if (p >= s.size()) vm_error("unexpected EOF in list");
        if (peek() == ')') {
            get();
            return g_nil;
        }
        ValueVec items;
        while (true) {
            skip_ws();
            if (p >= s.size()) vm_error("unexpected EOF in list");
            if (peek() == ')') {
                get();
                return list_from_vector(items);
            }
            if (peek() == '.') {
                get();
                ValuePtr tail = read_expr();
                if (!tail) vm_error("unexpected EOF after '.'");
                skip_ws();
                if (get() != ')') vm_error("expected ')'");
                ValuePtr out = tail;
                for (auto it = items.rbegin(); it != items.rend(); ++it) 
                    out = make_pair(*it, out);
                return out;
            }
            ValuePtr x = read_expr();
            // read_expr は入力を使い切ると nullptr を返す。ここで抜けないと
            // nullptr を積み続けて無限ループ（＝メモリ枯渇）になる。
            if (!x) vm_error("unexpected EOF in list");
            items.push_back(x);
        }
    }

    ValuePtr read_atom(char first) {
        std::string tok(1, first);
        while (p < s.size()) {
            char c = s[p];
            if (std::isspace(static_cast<unsigned char>(c)) || c == '(' || c == ')' || 
                c == '\'' || c == '`' || c == ',' || c == '"' || c == ';') break;
            tok.push_back(c);
            ++p;
        }
        
        // 真偽値の特別扱い（#t/#fはread_exprで処理されるのでここには来ない）
        if (tok == "nil") return g_nil;
        if (tok == "true") return make_bool(true);
        if (tok == "false") return make_bool(false);
        
        // 数値判定
        bool is_num = !tok.empty() && (std::isdigit(static_cast<unsigned char>(tok[0])) || 
                                       ((tok[0] == '-' || tok[0] == '+') && tok.size() > 1));
        if (is_num) {
            bool all_num = true;
            for (std::size_t i = (tok[0] == '-' || tok[0] == '+') ? 1 : 0; i < tok.size(); ++i) {
                if (!std::isdigit(static_cast<unsigned char>(tok[i]))) {
                    all_num = false;
                    break;
                }
            }
            if (all_num) {
                try {
                    return make_int(tok);
                } catch (...) {}
            }
        }
        return make_symbol(tok);
    }
};

static ValueVec read_all_exprs(const std::string& src);

// Part 2
// Compiler (変更なし - 以前と同じ)
using CompileEnv = std::vector<
    std::vector<std::string, gc_allocator<std::string>>,
    gc_allocator<std::vector<std::string, gc_allocator<std::string>>>
>;

static std::optional<std::pair<int, int>> location_of(const std::string& name, 
                                                      const CompileEnv& env) {
    for (int i = 0; i < static_cast<int>(env.size()); ++i) {
        for (int j = 0; j < static_cast<int>(env[i].size()); ++j) {
            if (env[i][j] == name) return std::make_pair(i, j);
        }
    }
    return std::nullopt;
}

static void emit(CodePtr code, Instruction ins) {
    code->ins.push_back(std::move(ins));
}

static Instruction make_ins(Op op) {
    Instruction i{};
    i.op = op;
    return i;
}

static void comp(ValuePtr expr, const CompileEnv& env, CodePtr code, bool tail);
static void comp_body(ValuePtr body, const CompileEnv& env, CodePtr code, bool tail);
static ValuePtr macro_expand_1_expr(ValuePtr expr);

// Macro expansion helpers (変更なし - 以前のコードと同じ)
static ValuePtr make_begin_form(const ValueVec& forms) {
    if (forms.empty()) return g_nil;
    if (forms.size() == 1) return forms[0];
    ValueVec xs;
    xs.push_back(make_symbol("begin"));
    xs.insert(xs.end(), forms.begin(), forms.end());
    return list_from_vector(xs);
}

static int g_gensym_counter = 0;
static ValuePtr make_gensym(const std::string& prefix = "g") {
    return make_symbol(prefix + std::to_string(++g_gensym_counter));
}

// ... (expand_let, expand_let_star, expand_letrec, expand_and, expand_or, 
//      expand_cond, qq_transfer, expand_case, expand_do は以前と同じなので省略)

// ここでは主要な関数のみ記載
static ValuePtr expand_let(ValuePtr rest) {
    ValuePtr bindings = car(rest);
    ValuePtr body = cdr(rest);
    if (is_symbol(bindings)) {
        ValuePtr name = bindings;
        ValuePtr real_bindings = car(body);
        ValuePtr real_body = cdr(body);
        ValueVec bs = vector_from_list(real_bindings);
        ValueVec params, args;
        for (auto& b : bs) {
            params.push_back(car(b));
            args.push_back(car(cdr(b)));
        }
        ValuePtr lambda_expr = make_pair(make_symbol("lambda"), 
                                        make_pair(list_from_vector(params), real_body));
        ValuePtr rec_bind = list_from_vector({name, lambda_expr});
        ValueVec call_items;
        call_items.push_back(name);
        call_items.insert(call_items.end(), args.begin(), args.end());
        return list_from_vector({make_symbol("letrec"), list_from_vector({rec_bind}), 
                                list_from_vector(call_items)});
    }
    ValueVec bs = vector_from_list(bindings);
    ValueVec params, args;
    for (auto& b : bs) {
        params.push_back(car(b));
        args.push_back(car(cdr(b)));
    }
    ValuePtr lambda_expr = make_pair(make_symbol("lambda"), 
                                    make_pair(list_from_vector(params), body));
    ValueVec call_items;
    call_items.push_back(lambda_expr);
    call_items.insert(call_items.end(), args.begin(), args.end());
    return list_from_vector(call_items);
}

static ValuePtr expand_let_star(ValuePtr rest) {
    ValuePtr bindings = car(rest);
    ValuePtr body = cdr(rest);
    ValueVec bs = vector_from_list(bindings);
    if (bs.empty()) return make_begin_form(vector_from_list(body));
    if (bs.size() == 1) return list_from_vector({make_symbol("let"), 
                                                 list_from_vector({bs[0]}), 
                                                 make_begin_form(vector_from_list(body))});
    ValuePtr first = bs[0];
    ValueVec tail_bindings(bs.begin() + 1, bs.end());
    ValuePtr nested = list_from_vector({make_symbol("let*"), list_from_vector(tail_bindings), 
                                       make_begin_form(vector_from_list(body))});
    return list_from_vector({make_symbol("let"), list_from_vector({first}), nested});
}

static ValuePtr expand_letrec(ValuePtr rest) {
    ValuePtr bindings = car(rest);
    ValuePtr body = cdr(rest);
    ValueVec bs = vector_from_list(bindings);
    ValueVec vars, vals;
    for (auto& b : bs) {
        vars.push_back(car(b));
        vals.push_back(car(cdr(b)));
    }
    ValueVec let_bindings;
    for (auto& v : vars) let_bindings.push_back(list_from_vector({v, make_symbol(":undef")}));
    ValueVec seq;
    for (std::size_t i = 0; i < vars.size(); ++i) {
        seq.push_back(list_from_vector({make_symbol("set!"), vars[i], vals[i]}));
    }
    auto body_vec = vector_from_list(body);
    seq.insert(seq.end(), body_vec.begin(), body_vec.end());
    return list_from_vector({make_symbol("let"), list_from_vector(let_bindings), 
                            make_begin_form(seq)});
}

static ValuePtr expand_and(ValuePtr rest) {
    ValueVec xs = vector_from_list(rest);
    if (xs.empty()) return make_bool(true);
    if (xs.size() == 1) return xs[0];
    ValueVec tail(xs.begin() + 1, xs.end());
    return list_from_vector({make_symbol("if"), xs[0], expand_and(list_from_vector(tail)), 
                            make_bool(false)});
}

static ValuePtr expand_or(ValuePtr rest) {
    ValueVec xs = vector_from_list(rest);
    if (xs.empty()) return make_bool(false);
    if (xs.size() == 1) return xs[0];
    ValueVec tail(xs.begin() + 1, xs.end());
    ValuePtr t = make_gensym("or");
    ValuePtr body = list_from_vector({make_symbol("if"), t, t, 
                                     expand_or(list_from_vector(tail))});
    ValuePtr bind = list_from_vector({t, xs[0]});
    return list_from_vector({make_symbol("let"), list_from_vector({bind}), body});
}

static ValuePtr expand_cond(ValuePtr rest) {
    if (is_nil(rest)) return make_symbol(":undef");
    ValuePtr clause = car(rest);
    ValuePtr rem = cdr(rest);
    ValuePtr test = car(clause);
    ValuePtr body = cdr(clause);
    if (is_symbol(test, "else")) return make_begin_form(vector_from_list(body));
    if (is_nil(body)) {
        ValuePtr t = make_gensym("cond");
        ValuePtr bind = list_from_vector({t, test});
        ValuePtr ife = list_from_vector({make_symbol("if"), t, t, expand_cond(rem)});
        return list_from_vector({make_symbol("let"), list_from_vector({bind}), ife});
    }
    return list_from_vector({make_symbol("if"), test, 
                            make_begin_form(vector_from_list(body)), expand_cond(rem)});
}

static ValuePtr qq_transfer(ValuePtr ls) {
    if (is_pair(ls)) {
        ValuePtr a = car(ls);
        if (is_pair(a)) {
            if (is_symbol(car(a), "unquote")) {
                return list_from_vector({make_symbol("cons"), car(cdr(a)), 
                                        qq_transfer(cdr(ls))});
            }
            if (is_symbol(car(a), "splice")) {
                return list_from_vector({make_symbol("append"), car(cdr(a)), 
                                        qq_transfer(cdr(ls))});
            }
            return list_from_vector({make_symbol("cons"), qq_transfer(a), 
                                    qq_transfer(cdr(ls))});
        }
        return list_from_vector({make_symbol("cons"), 
                                list_from_vector({make_symbol("quote"), a}), 
                                qq_transfer(cdr(ls))});
    }
    return list_from_vector({make_symbol("quote"), ls});
}

static ValuePtr expand_case(ValuePtr rest) {
    ValuePtr key = car(rest);
    ValuePtr clauses = cdr(rest);
    ValuePtr t = make_gensym("case");
    ValueVec cond_clauses;
    for (ValuePtr cur = clauses; !is_nil(cur); cur = cdr(cur)) {
        ValuePtr cl = car(cur);
        ValuePtr head = car(cl);
        ValuePtr body = cdr(cl);
        if (is_symbol(head, "else")) {
            ValueVec else_clause;
            else_clause.push_back(make_symbol("else"));
            auto b = vector_from_list(body);
            else_clause.insert(else_clause.end(), b.begin(), b.end());
            cond_clauses.push_back(list_from_vector(else_clause));
            continue;
        }
        ValuePtr quoted_keys = list_from_vector({make_symbol("quote"), head});
        ValuePtr test = list_from_vector({make_symbol("memv"), t, quoted_keys});
        ValueVec one;
        one.push_back(test);
        auto b = vector_from_list(body);
        one.insert(one.end(), b.begin(), b.end());
        cond_clauses.push_back(list_from_vector(one));
    }
    return list_from_vector({
        make_symbol("let"),
        list_from_vector({list_from_vector({t, key})}),
        make_pair(make_symbol("cond"), list_from_vector(cond_clauses))
    });
}

static ValuePtr expand_do(ValuePtr rest) {
    ValuePtr var_form = car(rest);
    ValuePtr rem = cdr(rest);
    ValuePtr test_form = car(rem);
    ValuePtr body = cdr(rem);
    ValueVec vars_raw = vector_from_list(var_form);
    ValueVec vars, inits, steps;
    for (auto& v : vars_raw) {
        vars.push_back(car(v));
        inits.push_back(car(cdr(v)));
        ValuePtr step_tail = cdr(cdr(v));
        steps.push_back(is_nil(step_tail) ? car(v) : car(step_tail));
    }
    ValuePtr test = car(test_form);
    ValuePtr test_result = cdr(test_form);
    ValuePtr loop_name = make_gensym("loop");
    ValueVec recur_call_items;
    recur_call_items.push_back(loop_name);
    recur_call_items.insert(recur_call_items.end(), steps.begin(), steps.end());
    ValuePtr recur_call = list_from_vector(recur_call_items);
    ValueVec else_seq = vector_from_list(body);
    else_seq.push_back(recur_call);
    ValuePtr else_expr = make_begin_form(else_seq);
    ValuePtr then_expr = make_begin_form(vector_from_list(test_result));
    ValuePtr if_expr = list_from_vector({make_symbol("if"), test, then_expr, else_expr});
    ValuePtr lambda_expr = list_from_vector({make_symbol("lambda"), 
                                            list_from_vector(vars), if_expr});
    ValuePtr loop_binding = list_from_vector({loop_name, lambda_expr});
    ValueVec loop_call_items;
    loop_call_items.push_back(loop_name);
    loop_call_items.insert(loop_call_items.end(), inits.begin(), inits.end());
    return list_from_vector({
        make_symbol("letrec"),
        list_from_vector({loop_binding}),
        list_from_vector(loop_call_items)
    });
}

// R5RS 4.1.6 / 5.2.2: 本体先頭に並ぶ define 群を letrec* 相当の内部束縛へ移す。
// これをやらないと define が Op::DEF（グローバルへの代入）にコンパイルされ、
// 内部の補助関数が LDG でグローバルを引くため、同名の補助関数を持つ別の関数に
// 後勝ちで上書きされてしまう。
// 先頭の連続した define だけを対象にする（式より後ろの define は R5RS でも未定義）。
// 呼ぶのは comp() の lambda ケースのみ。let / let* / 名前付き let / do はすべて
// lambda へ展開されてから comp に戻るので自動的にカバーされ、トップレベルや
// begin の define は従来どおりグローバルのまま残る。
static ValuePtr scan_out_defines(ValuePtr body) {
    ValueVec forms = vector_from_list(body);
    ValueVec bindings;
    std::size_t n = 0;
    while (n < forms.size() && is_pair(forms[n]) && is_symbol(car(forms[n]), "define")) {
        ValuePtr drest = cdr(forms[n]);
        if (is_nil(drest)) vm_error("invalid internal define");
        ValuePtr lhs = car(drest);
        ValuePtr rhs_tail = cdr(drest);
        if (is_symbol(lhs)) {
            // (define y expr)
            if (is_nil(rhs_tail)) vm_error("internal define needs a value");
            bindings.push_back(list_from_vector({lhs, car(rhs_tail)}));
        } else if (is_pair(lhs) && is_symbol(car(lhs))) {
            // (define (g . params) body...)
            ValuePtr lambda_expr = make_pair(make_symbol("lambda"),
                                             make_pair(cdr(lhs), rhs_tail));
            bindings.push_back(list_from_vector({car(lhs), lambda_expr}));
        } else {
            vm_error("invalid internal define");
        }
        ++n;
    }
    if (bindings.empty()) return body;

    ValueVec letrec_form;
    letrec_form.push_back(make_symbol("letrec"));
    letrec_form.push_back(list_from_vector(bindings));
    for (std::size_t i = n; i < forms.size(); ++i) letrec_form.push_back(forms[i]);
    // 本体が define だけの場合、letrec の本体が空になるので :undef を足す
    if (n == forms.size()) letrec_form.push_back(make_symbol(":undef"));
    return list_from_vector({list_from_vector(letrec_form)});
}

static void comp_body(ValuePtr body, const CompileEnv& env, CodePtr code, bool tail) {
    ValueVec forms = vector_from_list(body);
    if (forms.empty()) {
        Instruction ldc = make_ins(Op::LDC);
        ldc.constant = g_nil;
        emit(code, ldc);
        return;
    }
    for (std::size_t i = 0; i < forms.size(); ++i) {
        bool last = (i + 1 == forms.size());
        comp(forms[i], env, code, last && tail);
        if (!last) emit(code, make_ins(Op::POP));
    }
}

static bool extract_params(ValuePtr params_expr, 
                          std::vector<std::string, gc_allocator<std::string>>& fixed, 
                          std::optional<std::string>& rest) {
    fixed.clear();
    rest.reset();
    while (!is_nil(params_expr)) {
        if (!is_pair(params_expr)) {
            if (!is_symbol(params_expr)) return false;
            rest = as_symbol_name(params_expr);
            return true;
        }
        ValuePtr x = car(params_expr);
        if (!is_symbol(x)) return false;
        fixed.push_back(as_symbol_name(x));
        params_expr = cdr(params_expr);
    }
    return true;
}

static void comp(ValuePtr expr, const CompileEnv& env, CodePtr code, bool tail) {
    if (!expr || is_nil(expr) || std::holds_alternative<bool>(expr->data) || 
        std::holds_alternative<BigIntPtr>(expr->data) || 
        std::holds_alternative<GcString>(expr->data) ||
        std::holds_alternative<VectorPtr>(expr->data)) {
        Instruction ldc = make_ins(Op::LDC);
        ldc.constant = expr ? expr : g_nil;
        emit(code, ldc);
        return;
    }

    if (is_symbol(expr)) {
        std::string name = as_symbol_name(expr);
        auto pos = location_of(name, env);
        if (pos) {
            Instruction i = make_ins(Op::LD);
            i.a = pos->first;
            i.b = pos->second;
            emit(code, i);
        } else {
            Instruction i = make_ins(Op::LDG);
            i.sym = name;
            emit(code, i);
        }
        return;
    }

    if (!is_pair(expr)) vm_error("cannot compile atom: " + to_string(expr));
    ValuePtr head = car(expr);
    ValuePtr rest = cdr(expr);

    if (is_symbol(head, "quote")) {
        Instruction ldc = make_ins(Op::LDC);
        ldc.constant = car(rest);
        emit(code, ldc);
        return;
    }

    if (is_symbol(head, "test-start") || is_symbol(head, "test-end") ||
        is_symbol(head, "trace-print") || is_symbol(head, "macro-print") ||
        is_symbol(head, "compile-print")) {
        Instruction ldc = make_ins(Op::LDC);
        ldc.constant = make_bool(true);
        emit(code, ldc);
        return;
    }

    if (is_symbol(head, "quasiquote")) {
        comp(qq_transfer(car(rest)), env, code, tail);
        return;
    }

    if (is_symbol(head, "let")) {
        comp(expand_let(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "let*")) {
        comp(expand_let_star(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "letrec")) {
        comp(expand_letrec(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "and")) {
        comp(expand_and(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "or")) {
        comp(expand_or(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "cond")) {
        comp(expand_cond(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "case")) {
        comp(expand_case(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "do")) {
        comp(expand_do(rest), env, code, tail);
        return;
    }

    if (is_symbol(head, "if")) {
        ValuePtr test = car(rest);
        ValuePtr rem1 = cdr(rest);
        ValuePtr then_e = car(rem1);
        ValuePtr rem2 = cdr(rem1);
        ValuePtr else_e = is_nil(rem2) ? g_nil : car(rem2);
        comp(test, env, code, false);
        Instruction sel = make_ins(tail ? Op::SELR : Op::SEL);
        sel.ct = make_code();
        sel.cf = make_code();
        comp(then_e, env, sel.ct, tail);
        comp(else_e, env, sel.cf, tail);
        Op term = tail ? Op::RTN : Op::JOIN;
        emit(sel.ct, make_ins(term));
        emit(sel.cf, make_ins(term));
        emit(code, sel);
        return;
    }

    if (is_symbol(head, "begin")) {
        comp_body(rest, env, code, tail);
        return;
    }

    if (is_symbol(head, "lambda")) {
        ValuePtr params_expr = car(rest);
        ValuePtr body = cdr(rest);
        std::vector<std::string, gc_allocator<std::string>> fixed;
        std::optional<std::string> rest_param;
        if (!extract_params(params_expr, fixed, rest_param)) 
            vm_error("invalid lambda params");
        body = scan_out_defines(body);   // 本体先頭の define を letrec へ移す
        CompileEnv env2 = env;
        std::vector<std::string, gc_allocator<std::string>> frame = fixed;
        if (rest_param) frame.push_back(*rest_param);
        env2.insert(env2.begin(), frame);
        CodePtr body_code = make_code();
        comp_body(body, env2, body_code, true);
        emit(body_code, make_ins(Op::RTN));
        Instruction ins = make_ins(Op::LDF);
        ins.lambda_code = body_code;
        ins.lambda_params = fixed;
        ins.lambda_rest = rest_param;
        emit(code, ins);
        return;
    }

    if (is_symbol(head, "define")) {
        ValuePtr lhs = car(rest);
        ValuePtr rhs_tail = cdr(rest);
        if (is_symbol(lhs)) {
            comp(car(rhs_tail), env, code, false);
            Instruction d = make_ins(Op::DEF);
            d.sym = as_symbol_name(lhs);
            emit(code, d);
            return;
        }
        if (is_pair(lhs) && is_symbol(car(lhs))) {
            ValuePtr name = car(lhs);
            ValuePtr params = cdr(lhs);
            ValuePtr lambda_expr = make_pair(make_symbol("lambda"), 
                                            make_pair(params, rhs_tail));
            comp(lambda_expr, env, code, false);
            Instruction d = make_ins(Op::DEF);
            d.sym = as_symbol_name(name);
            emit(code, d);
            return;
        }
        vm_error("invalid define");
    }

    if (is_symbol(head, "define-macro")) {
        ValuePtr lhs = car(rest);
        ValuePtr rhs_tail = cdr(rest);
        if (is_symbol(lhs)) {
            comp(car(rhs_tail), env, code, false);
            Instruction d = make_ins(Op::DEFM);
            d.sym = as_symbol_name(lhs);
            emit(code, d);
            return;
        }
        if (is_pair(lhs) && is_symbol(car(lhs))) {
            ValuePtr name = car(lhs);
            ValuePtr params = cdr(lhs);
            ValuePtr lambda_expr = make_pair(make_symbol("lambda"), 
                                            make_pair(params, rhs_tail));
            comp(lambda_expr, env, code, false);
            Instruction d = make_ins(Op::DEFM);
            d.sym = as_symbol_name(name);
            emit(code, d);
            return;
        }
        vm_error("invalid define-macro");
    }

    if (is_symbol(head, "set!")) {
        ValuePtr name = car(rest);
        ValuePtr rhs = car(cdr(rest));
        if (!is_symbol(name)) vm_error("set! target must be symbol");
        std::string sym = as_symbol_name(name);
        comp(rhs, env, code, false);
        auto pos = location_of(sym, env);
        if (pos) {
            Instruction i = make_ins(Op::LSET);
            i.a = pos->first;
            i.b = pos->second;
            emit(code, i);
        } else {
            Instruction i = make_ins(Op::GSET);
            i.sym = sym;
            emit(code, i);
        }
        return;
    }

    if (is_symbol(head, "call/cc")) {
        comp(car(rest), env, code, false);
        // 末尾位置なら TAPP と同様にダンプを積まない（TCO を効かせる）
        emit(code, make_ins(tail ? Op::TCALLCC : Op::CALLCC));
        return;
    }

    if (is_symbol(head, "apply")) {
        ValueVec xs = vector_from_list(rest);
        if (xs.empty()) vm_error("apply needs at least one arg");
        ValuePtr fn = xs.front();
        for (std::size_t i = 1; i < xs.size(); ++i) comp(xs[i], env, code, false);
        Instruction aa = make_ins(Op::ARGS_AP);
        aa.a = static_cast<int>(xs.size() - 1);
        emit(code, aa);
        comp(fn, env, code, false);
        emit(code, make_ins(tail ? Op::TAPP : Op::APP));
        return;
    }

    ValuePtr expanded = macro_expand_1_expr(expr);
    if (expanded != expr) {
        comp(expanded, env, code, tail);
        return;
    }

    ValueVec args = vector_from_list(rest);
    for (auto& a : args) comp(a, env, code, false);
    Instruction pack = make_ins(Op::ARGS);
    pack.a = static_cast<int>(args.size());
    emit(code, pack);
    comp(head, env, code, false);
    emit(code, make_ins(tail ? Op::TAPP : Op::APP));
}

// Part 3: VM with trace support

#ifdef HAS_BIGNUM
static long long safe_bigint_to_ll(const BigInt& n, const char* context) {
    // 範囲チェック
    if (n.value > BigIntType(LLONG_MAX) || n.value < BigIntType(LLONG_MIN)) {
        std::string msg = std::string(context) + ": integer out of range for conversion";
        vm_error(msg);
    }
    
    try {
        std::string s = n.to_string();
        return std::stoll(s);
    } catch (const std::exception& e) {
        std::string msg = std::string(context) + ": conversion error - " + e.what();
        vm_error(msg);
    }
}
#else
static long long safe_bigint_to_ll(const BigInt& n, const char* context) {
    // Boost未使用時はlong longなのでそのまま返す
    // ただしオーバーフロー検出は困難
    (void)context;
    return n.value;
}
#endif

struct VM {
    ValueVec s;
    ValueVec e;
    CodePtr c;
    std::size_t pc = 0;
    DumpPtr d = nullptr;
    int step_count = 0;

    void trace_state(const Instruction& ins) {
        if (!g_trace_mode) return;
        
        std::cout << "\n==== Step " << step_count++ << " ====\n";
        std::cout << "PC: " << (pc - 1) << "\n";
        std::cout << "Instruction: " << instruction_to_string(ins, 0) << "\n";
        
        std::cout << "Stack: ";
        if (s.empty()) {
            std::cout << "(empty)\n";
        } else {
            std::cout << "\n";
            for (size_t i = 0; i < s.size() && i < 5; ++i) {
                std::cout << "  [" << i << "] " << to_string(s[s.size() - 1 - i]) << "\n";
            }
            if (s.size() > 5) {
                std::cout << "  ... (" << (s.size() - 5) << " more)\n";
            }
        }
        
        std::cout << "Environment: ";
        if (e.empty()) {
            std::cout << "(empty)\n";
        } else {
            std::cout << e.size() << " frame(s)\n";
            for (size_t i = 0; i < e.size() && i < 3; ++i) {
                std::cout << "  Frame[" << i << "]: ";
                ValuePtr frame = e[i];
                if (is_nil(frame)) {
                    std::cout << "NIL\n";
                } else if (is_vector(frame)) {
                    // 改善：ベクタフレームの表示
                    VectorPtr vec = as_vector(frame);
                    std::cout << "Vector(" << vec->size() << " bindings)\n";
                } else if (is_pair(frame)) {
                    auto fvec = vector_from_list(frame);
                    std::cout << "List(" << fvec.size() << " bindings)\n";
                } else {
                    std::cout << to_string(frame) << "\n";
                }
            }
            if (e.size() > 3) {
                std::cout << "  ... (" << (e.size() - 3) << " more frames)\n";
            }
        }
        
        std::cout << "Dump: " << dump_depth(d) << " frame(s)\n";
        std::cout << std::flush;
    }

    ValuePtr run() {
        while (true) {
            if (!c || pc >= c->ins.size()) vm_error("code exhausted without STOP");
            const Instruction& ins = c->ins[pc++];
            
            trace_state(ins);
            
            switch (ins.op) {
                case Op::LD: {
                    std::size_t pos = static_cast<std::size_t>(ins.a);
                    std::size_t idx = static_cast<std::size_t>(ins.b);
                    if (pos >= e.size()) vm_error("LD frame out of range");
                    ValuePtr frame = e[pos];
                    
                    // 改善：フレームがベクタなら直接アクセス、リストなら変換
                    if (is_vector(frame)) {
                        VectorPtr vec = as_vector(frame);
                        if (idx >= vec->size()) vm_error("LD index out of range");
                        s.push_back(vec->at(idx));
                    } else {
                        // 後方互換：リスト形式もサポート
                        auto frame_vec = vector_from_list(frame);
                        if (idx >= frame_vec.size()) vm_error("LD index out of range");
                        s.push_back(frame_vec[idx]);
                    }
                    break;
                }
                case Op::LDC:
                    s.push_back(ins.constant ? ins.constant : g_nil);
                    break;
                case Op::LDG: {
                    auto it = g_globals.find(ins.sym);
                    if (it == g_globals.end()) vm_error("unbound global: " + ins.sym);
                    s.push_back(it->second);
                    break;
                }
                case Op::LDF:
                    s.push_back(make_closure(ins.lambda_params, ins.lambda_rest, 
                                            ins.lambda_code, e));
                    break;
                case Op::ARGS: {
                    if (ins.a < 0 || static_cast<std::size_t>(ins.a) > s.size()) 
                        vm_error("ARGS stack underflow");
                    ValueVec v;
                    for (int i = 0; i < ins.a; ++i) {
                        v.push_back(s.back());
                        s.pop_back();
                    }
                    std::reverse(v.begin(), v.end());
                    s.push_back(list_from_vector(v));
                    break;
                }
                case Op::ARGS_AP: {
                    if (ins.a <= 0) vm_error("ARGS-AP needs >= 1");
                    if (static_cast<std::size_t>(ins.a) > s.size()) 
                        vm_error("ARGS-AP stack underflow");
                    ValuePtr tail = s.back();
                    s.pop_back();
                    ValueVec acc = vector_from_list(tail);
                    for (int i = 0; i < ins.a - 1; ++i) {
                        acc.insert(acc.begin(), s.back());
                        s.pop_back();
                    }
                    s.push_back(list_from_vector(acc));
                    break;
                }
                case Op::APP:
                case Op::TAPP: {
                    if (s.size() < 2) vm_error("APP stack underflow");
                    ValuePtr callee = s.back();
                    s.pop_back();
                    ValuePtr lvar = s.back();
                    s.pop_back();
                    
                    if (std::holds_alternative<PrimitiveInfoPtr>(callee->data)) {
                        auto args = vector_from_list(lvar);
                        PrimitiveInfoPtr info = std::get<PrimitiveInfoPtr>(callee->data);
                        ValuePtr out = info->fn(args);
                        s.push_back(out ? out : g_nil);
                        break;
                    }
                    
                    if (std::holds_alternative<ContPtr>(callee->data)) {
                        auto args = vector_from_list(lvar);
                        ValuePtr v = args.empty() ? g_nil : args[0];
                        ContPtr k = std::get<ContPtr>(callee->data);
                        s = k->s;
                        s.push_back(v);
                        e = k->e;
                        c = k->c;
                        pc = k->pc;
                        d = k->d;
                        break;
                    }
                    
                    if (!std::holds_alternative<ClosurePtr>(callee->data)) 
                        vm_error("APP target is not callable");
                    
                    ClosurePtr clo = std::get<ClosurePtr>(callee->data);
                    auto args = vector_from_list(lvar);
                    ValueVec frame = args;
                    
                    if (!clo->rest_param) {
                        if (args.size() != clo->params.size()) 
                            vm_error("arity mismatch");
                    } else {
                        if (args.size() < clo->params.size()) 
                            vm_error("arity mismatch (rest)");
                        ValueVec fixed(args.begin(), 
                                      args.begin() + static_cast<long>(clo->params.size()));
                        ValueVec rest(args.begin() + static_cast<long>(clo->params.size()), 
                                     args.end());
                        frame = fixed;
                        frame.push_back(list_from_vector(rest));
                    }
                    
                    if (ins.op == Op::APP) {
                        d = dump_push(d, DumpFrame{s, e, c, pc});
                    }
                    
                    s.clear();
                    ValueVec new_e;
                    // 改善：フレームをベクタとして保持
                    new_e.push_back(make_vector_value(frame));
                    new_e.insert(new_e.end(), clo->captured_env.begin(), 
                                clo->captured_env.end());
                    e = new_e;
                    c = clo->body;
                    pc = 0;
                    break;
                }
                case Op::RTN: {
                    if (!d) {
                        return s.empty() ? g_nil : s.back();
                    }
                    ValuePtr r = s.empty() ? g_nil : s.back();
                    DumpPtr top = d;   // ノードを基底ポインタで押さえてから鎖を進める
                    d = top->next;
                    s = top->frame.s;
                    s.push_back(r);
                    e = top->frame.e;
                    c = top->frame.c;
                    pc = top->frame.pc;
                    break;
                }
                case Op::SEL:
                case Op::SELR: {
                    if (s.empty()) vm_error("SEL stack underflow");
                    ValuePtr cond = s.back();
                    s.pop_back();
                    CodePtr next = is_true(cond) ? ins.ct : ins.cf;
                    if (!next) vm_error("SEL missing branch");
                    if (ins.op == Op::SEL) {
                        d = dump_push(d, DumpFrame{s, e, c, pc});
                    }
                    c = next;
                    pc = 0;
                    break;
                }
                case Op::JOIN: {
                    if (!d) vm_error("JOIN dump underflow");
                    c = d->frame.c;
                    pc = d->frame.pc;
                    d = d->next;
                    break;
                }
                case Op::POP:
                    if (s.empty()) vm_error("POP stack underflow");
                    s.pop_back();
                    break;
                case Op::DEF:
                    if (s.empty()) vm_error("DEF stack underflow");
                    g_globals[ins.sym] = s.back();
                    s.back() = make_symbol(ins.sym);
                    break;
                case Op::DEFM: {
                    if (s.empty()) vm_error("DEFM stack underflow");
                    ValuePtr macro_closure = s.back();
                    g_macros[ins.sym] = macro_closure;
                    if (std::holds_alternative<ClosurePtr>(macro_closure->data)) {
                        MacroPtr macro = new Macro(std::get<ClosurePtr>(macro_closure->data));
                        g_globals[ins.sym] = make_value(macro);
                    } else {
                        g_globals[ins.sym] = macro_closure;
                    }
                    s.back() = make_symbol(ins.sym);
                    break;
                }
                case Op::LSET: {
                    if (s.empty()) vm_error("LSET stack underflow");
                    std::size_t pos = static_cast<std::size_t>(ins.a);
                    std::size_t idx = static_cast<std::size_t>(ins.b);
                    if (pos >= e.size()) vm_error("LSET frame out of range");
                    ValuePtr frame = e[pos];
                    
                    // 改善：フレームがベクタなら直接アクセス
                    if (is_vector(frame)) {
                        VectorPtr vec = as_vector(frame);
                        if (idx >= vec->size()) vm_error("LSET index out of range");
                        vec->at(idx) = s.back();
                    } else {
                        // 後方互換：リスト形式
                        ValuePtr cell = frame;
                        for (std::size_t i = 0; i < idx; ++i) {
                            if (!is_pair(cell)) vm_error("LSET index out of range");
                            cell = cdr(cell);
                        }
                        if (!is_pair(cell)) vm_error("LSET index out of range");
                        as_pair(cell)->car = s.back();
                    }
                    break;
                }
                case Op::GSET:
                    if (s.empty()) vm_error("GSET stack underflow");
                    g_globals[ins.sym] = s.back();
                    break;
                case Op::LDCT:
                    s.push_back(make_cont(s, e, c, pc, d));
                    break;
                case Op::CALLCC:
                case Op::TCALLCC: {
                    if (s.empty()) vm_error("CALLCC stack underflow");
                    ValuePtr proc = s.back();
                    s.pop_back();
                    ValuePtr k = make_cont(s, e, c, pc, d);
                    ValuePtr lvar = list_from_vector({k});
                    
                    if (std::holds_alternative<PrimitiveInfoPtr>(proc->data)) {
                        auto args = vector_from_list(lvar);
                        PrimitiveInfoPtr info = std::get<PrimitiveInfoPtr>(proc->data);
                        ValuePtr out = info->fn(args);
                        s.push_back(out ? out : g_nil);
                        break;
                    }
                    
                    if (!std::holds_alternative<ClosurePtr>(proc->data)) 
                        vm_error("CALLCC target is not callable");
                    
                    ClosurePtr clo = std::get<ClosurePtr>(proc->data);
                    ValueVec args = vector_from_list(lvar);
                    ValueVec frame = args;
                    
                    if (!clo->rest_param) {
                        if (args.size() != clo->params.size()) 
                            vm_error("arity mismatch in CALLCC");
                    } else {
                        if (args.size() < clo->params.size()) 
                            vm_error("arity mismatch (rest) in CALLCC");
                        ValueVec fixed(args.begin(), 
                                      args.begin() + static_cast<long>(clo->params.size()));
                        ValueVec rest(args.begin() + static_cast<long>(clo->params.size()), 
                                     args.end());
                        frame = fixed;
                        frame.push_back(list_from_vector(rest));
                    }
                    
                    if (ins.op == Op::CALLCC) {
                        d = dump_push(d, DumpFrame{s, e, c, pc});
                    }
                    s.clear();
                    ValueVec new_e;
                    // 改善：フレームをベクタとして保持
                    new_e.push_back(make_vector_value(frame));
                    new_e.insert(new_e.end(), clo->captured_env.begin(), 
                                clo->captured_env.end());
                    e = new_e;
                    c = clo->body;
                    pc = 0;
                    break;
                }
                case Op::STOP:
                    return s.empty() ? g_nil : s.back();
            }
        }
    }
};

static CodePtr compile_top(ValuePtr expr) {
    CodePtr c = make_code();
    comp(expr, CompileEnv{}, c, false);
    emit(c, make_ins(Op::STOP));
    return c;
}

static ValuePtr eval_top(ValuePtr expr) {
    CodePtr code = compile_top(expr);
    VM vm;
    vm.c = code;
    vm.pc = 0;
    return vm.run();
}

static ValuePtr apply_callable_raw(ValuePtr proc, const ValueVec& args) {
    if (!proc) vm_error("macro apply: null callable");
    if (std::holds_alternative<PrimitiveInfoPtr>(proc->data)) {
        PrimitiveInfoPtr info = std::get<PrimitiveInfoPtr>(proc->data);
        ValuePtr out = info->fn(args);
        return out ? out : g_nil;
    }
    if (!std::holds_alternative<ClosurePtr>(proc->data)) {
        vm_error("macro apply target is not callable");
    }
    ClosurePtr clo = std::get<ClosurePtr>(proc->data);
    ValueVec frame = args;
    if (!clo->rest_param) {
        if (args.size() != clo->params.size()) vm_error("macro arity mismatch");
    } else {
        if (args.size() < clo->params.size()) vm_error("macro arity mismatch (rest)");
        ValueVec fixed(args.begin(), args.begin() + static_cast<long>(clo->params.size()));
        ValueVec rest(args.begin() + static_cast<long>(clo->params.size()), args.end());
        frame = fixed;
        frame.push_back(list_from_vector(rest));
    }
    VM vm;
    vm.s.clear();
    vm.e.clear();
    // 改善：フレームをベクタとして保持
    vm.e.push_back(make_vector_value(frame));
    vm.e.insert(vm.e.end(), clo->captured_env.begin(), clo->captured_env.end());
    vm.c = clo->body;
    vm.pc = 0;
    return vm.run();
}

static ValuePtr macro_expand_1_expr(ValuePtr expr) {
    if (!is_pair(expr)) return expr;
    ValuePtr head = car(expr);
    if (!is_symbol(head)) return expr;
    std::string name = as_symbol_name(head);
    auto it = g_macros.find(name);
    if (it == g_macros.end() || !it->second) return expr;
    ValueVec raw_args = vector_from_list(cdr(expr));
    return apply_callable_raw(it->second, raw_args);
}

// Part 4: Primitive Functions

static ValuePtr prim_add(const ValueVec& args) {
    BigInt n(0);
    for (auto& a : args) n = n + as_int(a);
    return make_int(n);
}

static ValuePtr prim_sub(const ValueVec& args) {
    if (args.empty()) vm_error("- expects at least 1 arg");
    BigInt n = as_int(args[0]);
    if (args.size() == 1) return make_int(-n);
    for (std::size_t i = 1; i < args.size(); ++i) n = n - as_int(args[i]);
    return make_int(n);
}

static ValuePtr prim_mul(const ValueVec& args) {
    BigInt n(1);
    for (auto& a : args) n = n * as_int(a);
    return make_int(n);
}

static ValuePtr prim_div(const ValueVec& args) {
    if (args.size() < 2) {
        vm_error("/ requires at least 2 arguments (single-argument reciprocal is not supported; use (/ 1 x) instead)");
    }
    
    BigInt n = as_int(args[0]);
    for (std::size_t i = 1; i < args.size(); ++i) {
        BigInt& d = as_int(args[i]);
        if (d.is_zero()) vm_error("division by zero");
        n = n / d;
    }
    return make_int(n);
}

static ValuePtr prim_modulo(const ValueVec& args) {
    if (args.size() != 2) vm_error("modulo expects 2 args");
    BigInt& a = as_int(args[0]);
    BigInt& b = as_int(args[1]);
    if (b.is_zero()) vm_error("modulo by zero");
    
    // Scheme準拠: 剰余の符号は除数bに一致
    BigInt r = a % b;
    if ((r < BigInt(0) && b > BigInt(0)) || 
        (r > BigInt(0) && b < BigInt(0))) {
        r = r + b;
    }
    return make_int(r);
}

static ValuePtr prim_num_eq(const ValueVec& args) {
    if (args.size() < 2) return make_bool(true);
    BigInt& base = as_int(args[0]);
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (!(as_int(args[i]) == base)) return make_bool(false);
    }
    return make_bool(true);
}

static ValuePtr prim_lt(const ValueVec& args) {
    if (args.size() < 2) return make_bool(true);
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (!(as_int(args[i - 1]) < as_int(args[i]))) return make_bool(false);
    }
    return make_bool(true);
}

static ValuePtr prim_gt(const ValueVec& args) {
    if (args.size() < 2) return make_bool(true);
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (!(as_int(args[i - 1]) > as_int(args[i]))) return make_bool(false);
    }
    return make_bool(true);
}

static ValuePtr prim_le(const ValueVec& args) {
    if (args.size() < 2) return make_bool(true);
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (!(as_int(args[i - 1]) <= as_int(args[i]))) return make_bool(false);
    }
    return make_bool(true);
}

static ValuePtr prim_ge(const ValueVec& args) {
    if (args.size() < 2) return make_bool(true);
    for (std::size_t i = 1; i < args.size(); ++i) {
        if (!(as_int(args[i - 1]) >= as_int(args[i]))) return make_bool(false);
    }
    return make_bool(true);
}

static ValuePtr prim_cons(const ValueVec& args) {
    if (args.size() != 2) vm_error("cons expects 2 args");
    return make_pair(args[0], args[1]);
}

static ValuePtr prim_set_car(const ValueVec& args) {
    if (args.size() != 2 || !is_pair(args[0])) 
        vm_error("set-car! expects pair and value");
    as_pair(args[0])->car = args[1];
    return args[1];
}

static ValuePtr prim_set_cdr(const ValueVec& args) {
    if (args.size() != 2 || !is_pair(args[0])) 
        vm_error("set-cdr! expects pair and value");
    as_pair(args[0])->cdr = args[1];
    return args[1];
}

static ValuePtr prim_car(const ValueVec& args) {
    if (args.size() != 1) vm_error("car expects 1 arg");
    return car(args[0]);
}

static ValuePtr prim_cdr(const ValueVec& args) {
    if (args.size() != 1) vm_error("cdr expects 1 arg");
    return cdr(args[0]);
}

static ValuePtr prim_caar(const ValueVec& args) {
    if (args.size() != 1) vm_error("caar expects 1 arg");
    return car(car(args[0]));
}

static ValuePtr prim_cdar(const ValueVec& args) {
    if (args.size() != 1) vm_error("cdar expects 1 arg");
    return cdr(car(args[0]));
}

static ValuePtr prim_cadr(const ValueVec& args) {
    if (args.size() != 1) vm_error("cadr expects 1 arg");
    return car(cdr(args[0]));
}

static ValuePtr prim_cddr(const ValueVec& args) {
    if (args.size() != 1) vm_error("cddr expects 1 arg");
    return cdr(cdr(args[0]));
}

static ValuePtr prim_caddr(const ValueVec& args) {
    if (args.size() != 1) vm_error("caddr expects 1 arg");
    return car(cdr(cdr(args[0])));
}

static ValuePtr prim_cdddr(const ValueVec& args) {
    if (args.size() != 1) vm_error("cdddr expects 1 arg");
    return cdr(cdr(cdr(args[0])));
}

static ValuePtr prim_list(const ValueVec& args) {
    return list_from_vector(args);
}

static ValuePtr append_two_lists(ValuePtr a, ValuePtr b) {
    ValueVec elems;
    while (!is_nil(a)) {
        if (!is_pair(a)) vm_error("append: first argument must be a list");
        elems.push_back(car(a));
        a = cdr(a);
    }
    ValuePtr out = b;
    for (auto it = elems.rbegin(); it != elems.rend(); ++it) {
        out = make_pair(*it, out);
    }
    return out;
}

static ValuePtr prim_append(const ValueVec& args) {
    ValuePtr out = g_nil;
    for (std::size_t i = 0; i < args.size(); ++i) {
        ValuePtr x = args[i];
        if (i + 1 == args.size()) {
            out = append_two_lists(out, x);
        } else {
            if (!is_nil(x) && !is_pair(x)) vm_error("append: expected list");
            out = append_two_lists(out, x);
        }
    }
    return out;
}

static ValuePtr prim_eq(const ValueVec& args) {
    if (args.size() != 2) return make_bool(false);
    if (args[0] == args[1]) return make_bool(true);
    if (std::holds_alternative<BigIntPtr>(args[0]->data) && 
        std::holds_alternative<BigIntPtr>(args[1]->data)) {
        return make_bool(as_int(args[0]) == as_int(args[1]));
    }
    if (is_symbol(args[0]) && is_symbol(args[1])) {
        return make_bool(as_symbol_name(args[0]) == as_symbol_name(args[1]));
    }
    return make_bool(false);
}

static ValuePtr prim_eqv(const ValueVec& args) {
    return prim_eq(args);
}

// より堅牢な循環検出（Floyd's cycle detection）
static bool is_proper_list(ValuePtr v) {
    if (is_nil(v)) return true;
    if (!is_pair(v)) return false;
    
    ValuePtr slow = v;
    ValuePtr fast = v;
    
    while (true) {
        if (is_nil(fast)) return true;
        if (!is_pair(fast)) return false;
        fast = cdr(fast);
        
        if (is_nil(fast)) return true;
        if (!is_pair(fast)) return false;
        fast = cdr(fast);
        
        slow = cdr(slow);
        
        // 循環検出：fastとslowが同じになったら循環
        if (slow == fast) return false;
    }
}

// 循環検出付きequal?実装
// ノード対応を記録する構造
using VisitedMap = std::unordered_map<void*, void*, 
    std::hash<void*>, std::equal_to<void*>,
    traceable_allocator<std::pair<void* const, void*>>>;

static bool value_equal_with_visited(ValuePtr a, ValuePtr b, VisitedMap& visited) {
    // 同一オブジェクトなら等しい
    if (a == b) return true;
    
    // どちらかがNILなら、両方NILの場合のみ等しい
    if (is_nil(a) || is_nil(b)) return is_nil(a) && is_nil(b);
    
    // 型が異なる場合の基本比較
    if (std::holds_alternative<bool>(a->data) && std::holds_alternative<bool>(b->data)) {
        return std::get<bool>(a->data) == std::get<bool>(b->data);
    }
    if (std::holds_alternative<BigIntPtr>(a->data) && 
        std::holds_alternative<BigIntPtr>(b->data)) {
        return as_int(a) == as_int(b);
    }
    if (std::holds_alternative<GcString>(a->data) && 
        std::holds_alternative<GcString>(b->data)) {
        return std::get<GcString>(a->data) == std::get<GcString>(b->data);
    }
    if (std::holds_alternative<Symbol>(a->data) && std::holds_alternative<Symbol>(b->data)) {
        return std::get<Symbol>(a->data).name == std::get<Symbol>(b->data).name;
    }
    
    // ベクタの比較（循環検出付き）
    if (std::holds_alternative<VectorPtr>(a->data) && 
        std::holds_alternative<VectorPtr>(b->data)) {
        VectorPtr va = std::get<VectorPtr>(a->data);
        VectorPtr vb = std::get<VectorPtr>(b->data);
        
        void* addr_a = static_cast<void*>(va);
        void* addr_b = static_cast<void*>(vb);
        
        // 既に訪問済みか確認
        auto it = visited.find(addr_a);
        if (it != visited.end()) {
            // 対応関係が一致するか確認
            return it->second == addr_b;
        }
        
        // サイズチェック
        if (va->size() != vb->size()) return false;
        
        // 訪問記録
        visited[addr_a] = addr_b;
        
        // 各要素を再帰比較
        for (std::size_t i = 0; i < va->size(); ++i) {
            if (!value_equal_with_visited(va->at(i), vb->at(i), visited)) {
                visited.erase(addr_a);  // バックトラック
                return false;
            }
        }
        
        visited.erase(addr_a);  // バックトラック
        return true;
    }
    
    // ペアの比較（循環検出付き・対応関係記録）
    // cdr 方向は再帰ではなくループで辿る。以前は cdr も再帰していたため、
    // 長いリスト同士の equal? が C スタックを溢れさせていた（20万要素で SIGSEGV）。
    // car だけ再帰し、スパン上のノードは経路として記録して最後にまとめて外す。
    if (std::holds_alternative<PairPtr>(a->data) && 
        std::holds_alternative<PairPtr>(b->data)) {
        std::vector<void*> path;  // この呼び出しで visited に入れたキー
        bool result;
        for (;;) {
            void* addr_a = static_cast<void*>(std::get<PairPtr>(a->data));
            void* addr_b = static_cast<void*>(std::get<PairPtr>(b->data));
            
            // 既に訪問済みなら、対応関係が一致するかで判定（循環の合流点）
            auto it = visited.find(addr_a);
            if (it != visited.end()) {
                result = (it->second == addr_b);
                break;
            }
            
            // 訪問記録
            visited[addr_a] = addr_b;
            path.push_back(addr_a);
            
            if (!value_equal_with_visited(car(a), car(b), visited)) {
                result = false;
                break;
            }
            
            a = cdr(a);
            b = cdr(b);
            if (a == b) { result = true; break; }
            
            bool a_pair = is_pair(a);
            bool b_pair = is_pair(b);
            if (a_pair != b_pair) { result = false; break; }
            if (!a_pair) {
                // 末尾（NIL や非ペア）は 1 段だけ再帰して比較
                result = value_equal_with_visited(a, b, visited);
                break;
            }
        }
        
        for (void* k : path) visited.erase(k);  // バックトラック
        return result;
    }
    
    return false;
}

static bool value_equal(ValuePtr a, ValuePtr b) {
    VisitedMap visited;
    return value_equal_with_visited(a, b, visited);
}

static ValuePtr prim_equal(const ValueVec& args) {
    if (args.size() != 2) return make_bool(false);
    return make_bool(value_equal(args[0], args[1]));
}

static ValuePtr prim_symbolp(const ValueVec& args) {
    if (args.size() != 1) vm_error("symbol? expects 1 arg");
    return make_bool(args[0] && std::holds_alternative<Symbol>(args[0]->data));
}

static ValuePtr prim_numberp(const ValueVec& args) {
    if (args.size() != 1) vm_error("number? expects 1 arg");
    return make_bool(args[0] && std::holds_alternative<BigIntPtr>(args[0]->data));
}

static ValuePtr prim_booleanp(const ValueVec& args) {
    if (args.size() != 1) vm_error("boolean? expects 1 arg");
    return make_bool(args[0] && std::holds_alternative<bool>(args[0]->data));
}

static ValuePtr prim_procedurep(const ValueVec& args) {
    if (args.size() != 1) vm_error("procedure? expects 1 arg");
    ValuePtr v = args[0];
    if (!v) return make_bool(false);
    return make_bool(
        std::holds_alternative<PrimitiveInfoPtr>(v->data) ||
        std::holds_alternative<ClosurePtr>(v->data) ||
        std::holds_alternative<ContPtr>(v->data));
}

static ValuePtr prim_listp(const ValueVec& args) {
    if (args.size() != 1) vm_error("list? expects 1 arg");
    return make_bool(is_proper_list(args[0]));
}

static ValuePtr prim_atomp(const ValueVec& args) {
    if (args.size() != 1) vm_error("atom? expects 1 arg");
    return make_bool(!is_pair(args[0]));
}

static ValuePtr prim_length(const ValueVec& args) {
    if (args.size() != 1) vm_error("length expects 1 arg");
    ValuePtr ls = args[0];
    if (!is_proper_list(ls)) vm_error("length expects proper list");
    BigInt n(0);
    while (!is_nil(ls)) {
        n = n + BigInt(1);
        ls = cdr(ls);
    }
    return make_int(n);
}

static ValuePtr prim_not(const ValueVec& args) {
    if (args.size() != 1) vm_error("not expects 1 arg");
    return make_bool(!is_true(args[0]));
}

static ValuePtr prim_memv(const ValueVec& args) {
    if (args.size() != 2) vm_error("memv expects 2 args");
    ValuePtr key = args[0];
    ValuePtr ls = args[1];
    while (!is_nil(ls)) {
        if (!is_pair(ls)) vm_error("memv expects proper list");
        ValuePtr x = car(ls);
        ValueVec eq_args{key, x};
        if (is_true(prim_eq(eq_args))) return ls;
        ls = cdr(ls);
    }
    return make_bool(false);
}

static ValuePtr prim_memq(const ValueVec& args) {
    if (args.size() != 2) vm_error("memq expects 2 args");
    ValuePtr key = args[0];
    ValuePtr ls = args[1];
    while (!is_nil(ls)) {
        if (!is_pair(ls)) vm_error("memq expects proper list");
        if (car(ls) == key) return ls;
        ls = cdr(ls);
    }
    return make_bool(false);
}

static ValuePtr prim_assq(const ValueVec& args) {
    if (args.size() != 2) vm_error("assq expects 2 args");
    ValuePtr key = args[0];
    ValuePtr ls = args[1];
    while (!is_nil(ls)) {
        if (!is_pair(ls)) vm_error("assq expects proper alist");
        ValuePtr entry = car(ls);
        if (is_pair(entry) && car(entry) == key) return entry;
        ls = cdr(ls);
    }
    return make_bool(false);
}

static ValuePtr prim_nullp(const ValueVec& args) {
    if (args.size() != 1) vm_error("null? expects 1 arg");
    return make_bool(is_nil(args[0]));
}

static ValuePtr prim_pairp(const ValueVec& args) {
    if (args.size() != 1) vm_error("pair? expects 1 arg");
    return make_bool(is_pair(args[0]));
}

static ValuePtr prim_display(const ValueVec& args) {
    if (args.empty() || args.size() > 2) {
        vm_error("display expects 1 or 2 args");
    }
    
    ValuePtr val = args[0];
    std::FILE* out = stdout;
    
    // 2引数の場合はポート指定
    if (args.size() == 2) {
        if (!std::holds_alternative<FilePortPtr>(args[1]->data)) {
            vm_error("display: second arg must be a port");
        }
        FilePortPtr port = std::get<FilePortPtr>(args[1]->data);
        if (port->is_input || port->is_closed || !port->fp) {
            vm_error("display: port is not an open output port");
        }
        out = port->fp;
    }
    
    // 文字列は引用符なしで直接出力、それ以外はto_stringを使用
    if (is_string(val)) {
        std::fprintf(out, "%s", as_string(val).c_str());
    } else {
        std::fprintf(out, "%s", to_string(val).c_str());
    }
    
    return val;
}

static ValuePtr prim_write(const ValueVec& args) {
    if (args.empty() || args.size() > 2) {
        vm_error("write expects 1 or 2 args");
    }
    
    ValuePtr val = args[0];
    std::FILE* out = stdout;
    
    // 2引数の場合はポート指定
    if (args.size() == 2) {
        if (!std::holds_alternative<FilePortPtr>(args[1]->data)) {
            vm_error("write: second arg must be a port");
        }
        FilePortPtr port = std::get<FilePortPtr>(args[1]->data);
        if (port->is_input || port->is_closed || !port->fp) {
            vm_error("write: port is not an open output port");
        }
        out = port->fp;
    }
    
    std::fprintf(out, "%s", to_string(val).c_str());
    return val;
}

static ValuePtr prim_newline(const ValueVec& args) {
    if (args.size() > 1) {
        vm_error("newline expects 0 or 1 arg");
    }
    
    std::FILE* out = stdout;
    
    // 1引数の場合はポート指定
    if (args.size() == 1) {
        if (!std::holds_alternative<FilePortPtr>(args[0]->data)) {
            vm_error("newline: arg must be a port");
        }
        FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
        if (port->is_input || port->is_closed || !port->fp) {
            vm_error("newline: port is not an open output port");
        }
        out = port->fp;
    }
    
    std::fprintf(out, "\n");
    return g_nil;
}

// File I/O primitives
static ValuePtr prim_open_input_file(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<GcString>(args[0]->data)) {
        vm_error("open-input-file expects a string path");
    }
    std::string path = to_std(std::get<GcString>(args[0]->data));
    std::FILE* fp = std::fopen(path.c_str(), "rb");
    if (!fp) {
        vm_error("open-input-file: cannot open file: " + path);
    }
    FilePortPtr port = new FilePort(fp, true);
    return make_value(port);
}

static ValuePtr prim_open_output_file(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<GcString>(args[0]->data)) {
        vm_error("open-output-file expects a string path");
    }
    std::string path = to_std(std::get<GcString>(args[0]->data));
    std::FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) {
        vm_error("open-output-file: cannot open file: " + path);
    }
    FilePortPtr port = new FilePort(fp, false);
    return make_value(port);
}

static ValuePtr prim_close_input_port(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("close-input-port expects a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    port->close();
    return g_nil;
}

static ValuePtr prim_close_output_port(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("close-output-port expects a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    port->close();
    return g_nil;
}

static ValuePtr prim_read_line(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("read-line expects a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    if (!port->is_input || port->is_closed || !port->fp) {
        vm_error("read-line: port is not an open input port");
    }
    
    std::string line;
    int c;
    while ((c = std::fgetc(port->fp)) != EOF) {
        if (c == '\n') break;
        if (c == '\r') {
            int next = std::fgetc(port->fp);
            if (next != '\n' && next != EOF) {
                std::ungetc(next, port->fp);
            }
            break;
        }
        line.push_back(static_cast<char>(c));
    }
    
    if (c == EOF && line.empty()) {
        return make_eof_object();
    }
    return make_string(line);
}

// prim_write_newline は元のまま（1引数必須・ポート専用）
static ValuePtr prim_write_newline(const ValueVec& args) {
    if (args.size() != 1) {
        vm_error("write_newline expects 1 arg (port)");
    }
    if (!std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("write_newline: arg must be a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    if (port->is_input || port->is_closed || !port->fp) {
        vm_error("write_newline: port is not an open output port");
    }
    std::fputc('\n', port->fp);
    return g_nil;
}

// 判定関数
static ValuePtr prim_eof_objectp(const ValueVec& args) {
    if (args.size() != 1) vm_error("eof-object? expects 1 arg");
    return make_bool(args[0] && std::holds_alternative<EofTag>(args[0]->data));
}

static ValuePtr prim_read_char(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("read-char expects a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    
    if (!port->is_input || port->is_closed || !port->fp) {
        vm_error("read-char: port is not an open input port");
    }
    
    int c = std::fgetc(port->fp);
    if (c == EOF) {
        return make_eof_object();
    }
    
    std::string s(1, static_cast<char>(c));
    return make_string(s);
}

static ValuePtr prim_write_char(const ValueVec& args) {
    if (args.size() != 2) {
        vm_error("write-char expects 2 args (char, port)");
    }
    if (!std::holds_alternative<GcString>(args[0]->data)) {
        vm_error("write-char: first arg must be a string (char)");
    }
    if (!std::holds_alternative<FilePortPtr>(args[1]->data)) {
        vm_error("write-char: second arg must be a port");
    }
    
    std::string s = to_std(std::get<GcString>(args[0]->data));
    if (s.empty()) {
        vm_error("write-char: empty string");
    }
    
    FilePortPtr port = std::get<FilePortPtr>(args[1]->data);
    if (port->is_input || port->is_closed || !port->fp) {
        vm_error("write-char: port is not an open output port");
    }
    
    std::fputc(s[0], port->fp);
    return g_nil;
}

static ValuePtr prim_read_expr(const ValueVec& args) {
    if (args.size() != 1 || !std::holds_alternative<FilePortPtr>(args[0]->data)) {
        vm_error("read-expr expects a port");
    }
    FilePortPtr port = std::get<FilePortPtr>(args[0]->data);
    
    if (!port->is_input || port->is_closed || !port->fp) {
        vm_error("read-expr: port is not an open input port");
    }
    
    std::string buffer;
    int paren_depth = 0;
    bool in_string = false;
    bool in_comment = false;
    bool seen_content = false;
    
    while (true) {
        int c = std::fgetc(port->fp);
        if (c == EOF) {
            if (!seen_content) {
                return make_eof_object();
            }
            break;
        }
        
        char ch = static_cast<char>(c);
        
        if (ch == ';' && !in_string) {
            in_comment = true;
        }
        if (ch == '\n') {
            in_comment = false;
        }
        if (in_comment) {
            buffer.push_back(ch);
            continue;
        }
        
        if (ch == '"' && (buffer.empty() || buffer.back() != '\\')) {
            in_string = !in_string;
        }
        
        if (!in_string) {
            // 修正：角括弧を削除（丸括弧のみ）
            if (ch == '(') {
                paren_depth++;
                seen_content = true;
            } else if (ch == ')') {
                paren_depth--;
            } else if (!std::isspace(static_cast<unsigned char>(ch))) {
                seen_content = true;
            }
        }
        
        buffer.push_back(ch);
        
        if (seen_content && paren_depth == 0 && !in_string) {
            std::string trimmed = buffer;
            while (!trimmed.empty() && 
                   std::isspace(static_cast<unsigned char>(trimmed.back()))) {
                trimmed.pop_back();
            }
            if (!trimmed.empty()) {
                break;
            }
        }
    }
    
    if (buffer.empty()) {
        return make_eof_object();
    }
    
    try {
        Reader r(buffer);
        ValuePtr expr = r.read_expr();
        return expr ? expr : make_eof_object();
    } catch (...) {
        vm_error("read-expr: parse error");
        return make_eof_object();
    }
}

static ValuePtr prim_read_from_stdin(const ValueVec& args) {
    (void)args;
    std::string line;
    if (!std::getline(std::cin, line)) {
        return make_eof_object();
    }
    
    try {
        Reader r(line);
        ValuePtr expr = r.read_expr();
        return expr ? expr : make_eof_object();
    } catch (...) {
        vm_error("read: parse error");
        return make_eof_object();
    }
}

// String primitives (以前のコードと同じ - 省略可能)
static ValuePtr prim_stringp(const ValueVec& args) {
    if (args.size() != 1) vm_error("string? expects 1 arg");
    return make_bool(is_string(args[0]));
}

static ValuePtr prim_make_string(const ValueVec& args) {
    if (args.empty() || args.size() > 2) vm_error("make-string expects 1 or 2 args");
    BigInt& len = as_int(args[0]);
    if (len < BigInt(0)) vm_error("make-string: negative length");
    
    long long len_val = safe_bigint_to_ll(len, "make-string");
    if (len_val < 0 || len_val > 1000000) vm_error("make-string: length out of reasonable range");
    std::size_t n = static_cast<std::size_t>(len_val);
    
    char fill_char = ' ';
    if (args.size() == 2) {
        GcString& s = as_string(args[1]);
        if (s.empty()) vm_error("make-string: empty fill char");
        fill_char = s[0];
    }
    
    return make_string(std::string(n, fill_char));
}

static ValuePtr prim_string_length(const ValueVec& args) {
    if (args.size() != 1) vm_error("string-length expects 1 arg");
    return make_int(BigInt(static_cast<long long>(as_string(args[0]).size())));
}

static ValuePtr prim_string_ref(const ValueVec& args) {
    if (args.size() != 2) vm_error("string-ref expects 2 args");
    GcString& s = as_string(args[0]);
    BigInt& idx = as_int(args[1]);
    
    long long i = safe_bigint_to_ll(idx, "string-ref");  // 修正
    if (i < 0 || static_cast<std::size_t>(i) >= s.size()) {
        vm_error("string-ref: index out of range");
    }
    
    return make_string(std::string(1, s[static_cast<std::size_t>(i)]));
}

static ValuePtr prim_string_set(const ValueVec& args) {
    if (args.size() != 3) vm_error("string-set! expects 3 args");
    GcString& s = as_string(args[0]);
    BigInt& idx = as_int(args[1]);
    GcString& newchar = as_string(args[2]);
    
    if (newchar.empty()) vm_error("string-set!: empty char string");
    
    long long i = safe_bigint_to_ll(idx, "string-set!");  // 修正
    if (i < 0 || static_cast<std::size_t>(i) >= s.size()) {
        vm_error("string-set!: index out of range");
    }
    
    s[static_cast<std::size_t>(i)] = newchar[0];
    return make_symbol(":undef");
}

static ValuePtr prim_substring(const ValueVec& args) {
    if (args.size() < 2 || args.size() > 3) vm_error("substring expects 2 or 3 args");
    GcString& s = as_string(args[0]);
    BigInt& start = as_int(args[1]);
    
    long long start_val = safe_bigint_to_ll(start, "substring");  // 修正
    if (start_val < 0 || start_val > static_cast<long long>(s.size())) {
        vm_error("substring: start index out of range");
    }
    std::size_t start_idx = static_cast<std::size_t>(start_val);
    std::size_t end_idx = s.size();
    
    if (args.size() == 3) {
        BigInt& end = as_int(args[2]);
        long long end_val = safe_bigint_to_ll(end, "substring");  // 修正
        if (end_val < start_val || end_val > static_cast<long long>(s.size())) {
            vm_error("substring: end index out of range");
        }
        end_idx = static_cast<std::size_t>(end_val);
    }
    
    return make_string(s.substr(start_idx, end_idx - start_idx));
}

static ValuePtr prim_string_append(const ValueVec& args) {
    GcString result;
    for (auto& arg : args) {
        result += as_string(arg);
    }
    return make_string(result);
}

static ValuePtr prim_string_to_list(const ValueVec& args) {
    if (args.size() != 1) vm_error("string->list expects 1 arg");
    GcString& s = as_string(args[0]);
    ValueVec chars;
    for (char c : s) {
        chars.push_back(make_string(std::string(1, c)));
    }
    return list_from_vector(chars);
}

static ValuePtr prim_list_to_string(const ValueVec& args) {
    if (args.size() != 1) vm_error("list->string expects 1 arg");
    ValuePtr ls = args[0];
    GcString result;
    while (!is_nil(ls)) {
        if (!is_pair(ls)) vm_error("list->string: not a proper list");
        GcString& ch = as_string(car(ls));
        if (!ch.empty()) result += ch[0];
        ls = cdr(ls);
    }
    return make_string(result);
}

static ValuePtr prim_string_eq(const ValueVec& args) {
    if (args.size() != 2) vm_error("string=? expects 2 args");
    return make_bool(as_string(args[0]) == as_string(args[1]));
}

static ValuePtr prim_string_lt(const ValueVec& args) {
    if (args.size() != 2) vm_error("string<? expects 2 args");
    return make_bool(as_string(args[0]) < as_string(args[1]));
}

static ValuePtr prim_string_gt(const ValueVec& args) {
    if (args.size() != 2) vm_error("string>? expects 2 args");
    return make_bool(as_string(args[0]) > as_string(args[1]));
}

static ValuePtr prim_string_le(const ValueVec& args) {
    if (args.size() != 2) vm_error("string<=? expects 2 args");
    return make_bool(as_string(args[0]) <= as_string(args[1]));
}

static ValuePtr prim_string_ge(const ValueVec& args) {
    if (args.size() != 2) vm_error("string>=? expects 2 args");
    return make_bool(as_string(args[0]) >= as_string(args[1]));
}

static ValuePtr prim_number_to_string(const ValueVec& args) {
    if (args.size() != 1) vm_error("number->string expects 1 arg");
    return make_string(as_int(args[0]).to_string());
}

static ValuePtr prim_string_to_number(const ValueVec& args) {
    if (args.size() != 1) vm_error("string->number expects 1 arg");
    try {
        return make_int(to_std(as_string(args[0])));
    } catch (...) {
        return make_bool(false);
    }
}

static ValuePtr prim_char_to_integer(const ValueVec& args) {
    if (args.size() != 1) vm_error("char->integer expects 1 arg");
    GcString& s = as_string(args[0]);
    if (s.empty()) vm_error("char->integer: empty string");
    return make_int(BigInt(static_cast<long long>(static_cast<unsigned char>(s[0]))));
}

static ValuePtr prim_integer_to_char(const ValueVec& args) {
    if (args.size() != 1) vm_error("integer->char expects 1 arg");
    BigInt& n = as_int(args[0]);
    long long val = safe_bigint_to_ll(n, "integer->char");  // 修正
    if (val < 0 || val > 127) vm_error("integer->char: value out of ASCII range");
    return make_string(std::string(1, static_cast<char>(val)));
}

// Vector primitives (以前のコードと同じ - 省略可能)
static ValuePtr prim_vectorp(const ValueVec& args) {
    if (args.size() != 1) vm_error("vector? expects 1 arg");
    return make_bool(is_vector(args[0]));
}

static ValuePtr prim_make_vector(const ValueVec& args) {
    if (args.empty() || args.size() > 2) vm_error("make-vector expects 1 or 2 args");
    BigInt& len = as_int(args[0]);
    if (len < BigInt(0)) vm_error("make-vector: negative length");
    
    long long len_val = safe_bigint_to_ll(len, "make-vector");  // 修正
    if (len_val < 0 || len_val > 1000000) vm_error("make-vector: length too large");
    std::size_t n = static_cast<std::size_t>(len_val);
    
    ValuePtr init = (args.size() == 2) ? args[1] : g_nil;
    return make_vector_value(n, init);
}

static ValuePtr prim_vector(const ValueVec& args) {
    return make_vector_value(args);
}

static ValuePtr prim_vector_length(const ValueVec& args) {
    if (args.size() != 1) vm_error("vector-length expects 1 arg");
    VectorPtr vec = as_vector(args[0]);
    return make_int(BigInt(static_cast<long long>(vec->size())));
}

static ValuePtr prim_vector_ref(const ValueVec& args) {
    if (args.size() != 2) vm_error("vector-ref expects 2 args");
    VectorPtr vec = as_vector(args[0]);
    BigInt& idx = as_int(args[1]);
    
    long long i = safe_bigint_to_ll(idx, "vector-ref");  // 修正
    if (i < 0 || static_cast<std::size_t>(i) >= vec->size()) {
        vm_error("vector-ref: index out of range");
    }
    return vec->at(static_cast<std::size_t>(i));
}

static ValuePtr prim_vector_set(const ValueVec& args) {
    if (args.size() != 3) vm_error("vector-set! expects 3 args");
    VectorPtr vec = as_vector(args[0]);
    BigInt& idx = as_int(args[1]);
    ValuePtr val = args[2];
    
    long long i = safe_bigint_to_ll(idx, "vector-set!");  // 修正
    if (i < 0 || static_cast<std::size_t>(i) >= vec->size()) {
        vm_error("vector-set!: index out of range");
    }
    vec->at(static_cast<std::size_t>(i)) = val;
    return make_symbol(":undef");
}

static ValuePtr prim_vector_to_list(const ValueVec& args) {
    if (args.size() != 1) vm_error("vector->list expects 1 arg");
    VectorPtr vec = as_vector(args[0]);
    return list_from_vector(vec->elements);
}

static ValuePtr prim_list_to_vector(const ValueVec& args) {
    if (args.size() != 1) vm_error("list->vector expects 1 arg");
    ValueVec elems = vector_from_list(args[0]);
    return make_vector_value(elems);
}

// Part 5: Load, Debug Primitives, Initialization, and Main

static std::string slurp_file(const std::string& path) {
    std::FILE* in = std::fopen(path.c_str(), "rb");
    if (!in) throw std::runtime_error("scheme12: cannot open file: " + path);
    if (std::fseek(in, 0, SEEK_END) != 0) {
        std::fclose(in);
        throw std::runtime_error("scheme12: cannot seek file: " + path);
    }
    long size = std::ftell(in);
    if (size < 0) {
        std::fclose(in);
        throw std::runtime_error("scheme12: cannot stat file: " + path);
    }
    if (std::fseek(in, 0, SEEK_SET) != 0) {
        std::fclose(in);
        throw std::runtime_error("scheme12: cannot rewind file: " + path);
    }
    std::string src(static_cast<std::size_t>(size), '\0');
    if (!src.empty()) {
        std::size_t got = std::fread(&src[0], 1, src.size(), in);
        if (got != src.size()) {
            std::fclose(in);
            throw std::runtime_error("scheme12: cannot read file: " + path);
        }
    }
    std::fclose(in);
    return src;
}

static ValuePtr load_from_path(const std::string& path) {
    std::string src = slurp_file(path);
    auto exprs = read_all_exprs(src);
    ValuePtr last = g_nil;
    for (auto& e : exprs) last = eval_top(e);
    return last;
}

static std::optional<std::pair<std::string, bool>> extract_definition_name(ValuePtr expr) {
    if (!is_pair(expr)) return std::nullopt;
    ValuePtr head = car(expr);
    bool is_macro_def = false;
    if (is_symbol(head, "define")) {
        is_macro_def = false;
    } else if (is_symbol(head, "define-macro")) {
        is_macro_def = true;
    } else {
        return std::nullopt;
    }

    ValuePtr rest = cdr(expr);
    if (is_nil(rest)) return std::nullopt;
    ValuePtr lhs = car(rest);
    if (is_symbol(lhs)) {
        return std::make_pair(as_symbol_name(lhs), is_macro_def);
    }
    if (is_pair(lhs) && is_symbol(car(lhs))) {
        return std::make_pair(as_symbol_name(car(lhs)), is_macro_def);
    }
    return std::nullopt;
}

static ValuePtr load_library_from_path_dedup(const std::string& path) {
    std::string src = slurp_file(path);
    auto exprs = read_all_exprs(src);
    ValuePtr last = g_nil;
    for (auto& e : exprs) {
        auto def = extract_definition_name(e);
        if (def) {
            const std::string& name = def->first;
            bool is_macro_def = def->second;
            if (is_macro_def) {
                if (g_macros.find(name) != g_macros.end()) continue;
            } else {
                if (g_globals.find(name) != g_globals.end()) continue;
            }
        }
        last = eval_top(e);
    }
    return last;
}

static void load_startup_libraries(const char* argv0) {
    std::vector<std::string> candidates;

    if (argv0 && *argv0) {
        std::error_code ec;
        std::filesystem::path exe_path = std::filesystem::absolute(
            std::filesystem::path(argv0), ec);
        if (!ec) {
            std::filesystem::path exe_dir = exe_path.parent_path();
            candidates.push_back((exe_dir / "system_lib.scm").string());
        }
    }

    candidates.push_back("system_lib.scm");

    for (const auto& path : candidates) {
        try {
            load_library_from_path_dedup(path);
            return;
        } catch (const std::exception&) {
            // Try next candidate.
        }
    }
}

static ValuePtr prim_load(const ValueVec& args) {
    if (args.empty() || !args[0] || !std::holds_alternative<GcString>(args[0]->data)) {
        vm_error("load expects a string path");
    }
    std::string path = to_std(std::get<GcString>(args[0]->data));
    return load_from_path(path);
}

// Random number functions
static void init_random() {
    if (!g_random_initialized) {
        std::random_device rd;
        g_random_engine.seed(rd());
        g_random_initialized = true;
    }
}

static ValuePtr prim_random(const ValueVec& args) {
    if (args.size() != 1) {
        vm_error("random expects 1 argument");
    }
    
    init_random();
    
    BigInt& n = as_int(args[0]);
    if (n <= BigInt(0)) {
        vm_error("random: argument must be positive");
    }
    
    // 範囲チェック（変換前に行う）
#ifdef HAS_BIGNUM
    if (n.value > BigIntType(LLONG_MAX)) {
        vm_error("random: argument too large (must fit in long long range)");
    }
#endif
    
    // 安全に変換
    long long max_val = safe_bigint_to_ll(n, "random");
    
    std::uniform_int_distribution<long long> dist(0, max_val - 1);
    long long result = dist(g_random_engine);
    return make_int(BigInt(result));
}

static ValuePtr prim_random_seed(const ValueVec& args) {
    if (args.size() != 1) {
        vm_error("random-seed expects 1 argument");
    }
    
    BigInt& seed = as_int(args[0]);
    long long seed_val = safe_bigint_to_ll(seed, "random-seed");  // 修正
    
    g_random_engine.seed(static_cast<unsigned int>(seed_val));
    g_random_initialized = true;
    
    return make_symbol(":ok");
}

// Symbol/String conversion primitives
static ValuePtr prim_symbol_to_string(const ValueVec& args) {
    if (args.size() != 1) vm_error("symbol->string expects 1 arg");
    if (!is_symbol(args[0])) vm_error("symbol->string expects a symbol");
    return make_string(as_symbol_name(args[0]));
}

static ValuePtr prim_string_to_symbol(const ValueVec& args) {
    if (args.size() != 1) vm_error("string->symbol expects 1 arg");
    if (!is_string(args[0])) vm_error("string->symbol expects a string");
    return make_symbol(to_std(as_string(args[0])));
}

// GC primitives
static ValuePtr prim_gc_collect(const ValueVec& args) {
    (void)args;
    GC_gcollect();
    return make_symbol(":gc-collected");
}

static ValuePtr prim_gc_get_heap_size(const ValueVec& args) {
    (void)args;
    size_t heap_size = GC_get_heap_size();
    return make_int(BigInt(static_cast<long long>(heap_size)));
}

static ValuePtr prim_gc_get_free_bytes(const ValueVec& args) {
    (void)args;
    size_t free_bytes = GC_get_free_bytes();
    return make_int(BigInt(static_cast<long long>(free_bytes)));
}

// Debug primitives

static ValuePtr prim_compile(const ValueVec& args) {
    if (args.size() != 1) vm_error("compile expects 1 arg");
    CodePtr code = compile_top(args[0]);
    std::cout << "\n=== Compiled Code ===\n";
    std::cout << code_to_string_detailed(code, 0, 10);  // ← 変更
    std::cout << "=====================\n";
    return make_symbol(":compiled");
}

static ValuePtr prim_disassemble(const ValueVec& args) {
    if (args.size() != 1) vm_error("disassemble expects 1 arg");
    ValuePtr v = args[0];
    
    if (std::holds_alternative<ClosurePtr>(v->data)) {
        ClosurePtr clo = std::get<ClosurePtr>(v->data);
        std::cout << "\n=== Disassembly ===\n";
        std::cout << "Parameters: (";
        for (size_t i = 0; i < clo->params.size(); ++i) {
            if (i > 0) std::cout << " ";
            std::cout << clo->params[i];
        }
        if (clo->rest_param) {
            if (!clo->params.empty()) std::cout << " . ";
            std::cout << *clo->rest_param;
        }
        std::cout << ")\n";
        std::cout << "Body:" << code_to_string_detailed(clo->body, 1, 10);
        std::cout << "Environment: " << clo->captured_env.size() << " frame(s)\n";
        std::cout << "===================\n";
        return make_symbol(":disassembled");
    }
    
    if (std::holds_alternative<MacroPtr>(v->data)) {
        MacroPtr macro = std::get<MacroPtr>(v->data);
        std::cout << "\n=== Macro Transformer ===\n";
        ValuePtr clo_val = make_value(macro->transformer);
        return prim_disassemble({clo_val});
    }
    
    std::cout << "Not a closure or macro: " << to_string(v) << "\n";
    return make_symbol(":not-disassemblable");
}

static ValuePtr prim_trace_on(const ValueVec& args) {
    (void)args;
    g_trace_mode = true;
    std::cout << "Trace mode ON\n";
    return make_bool(true);
}

static ValuePtr prim_trace_off(const ValueVec& args) {
    (void)args;
    g_trace_mode = false;
    std::cout << "Trace mode OFF\n";
    return make_bool(false);
}

static ValuePtr prim_globals(const ValueVec& args) {
    (void)args;
    std::cout << "\n=== Global Variables ===\n";
    std::vector<std::string> names;
    for (auto& kv : g_globals) {
        names.push_back(kv.first);
    }
    std::sort(names.begin(), names.end());
    
    for (auto& name : names) {
        ValuePtr val = g_globals[name];
        std::cout << name << " : ";
        
        // 短縮表示
        if (std::holds_alternative<PrimitiveInfoPtr>(val->data)) {
            PrimitiveInfoPtr info = std::get<PrimitiveInfoPtr>(val->data);
            std::cout << "(PRIMITIVE " << info->name << ")";
        } else if (std::holds_alternative<SpecialFormPtr>(val->data)) {
            SpecialFormPtr sf = std::get<SpecialFormPtr>(val->data);
            std::cout << "(SPECIAL-FORM " << sf->name << ")";
        } else if (std::holds_alternative<ClosurePtr>(val->data)) {
            std::cout << "#<closure>";
        } else if (std::holds_alternative<MacroPtr>(val->data)) {
            std::cout << "#<macro>";
        } else {
            std::cout << to_string(val);
        }
        std::cout << "\n";
    }
    std::cout << "========================\n";
    return make_symbol(":globals-listed");
}

static ValuePtr prim_macros(const ValueVec& args) {
    (void)args;
    std::cout << "\n=== Macros ===\n";
    std::vector<std::string> names;
    for (auto& kv : g_macros) {
        names.push_back(kv.first);
    }
    std::sort(names.begin(), names.end());
    
    for (auto& name : names) {
        std::cout << name << "\n";
    }
    std::cout << "==============\n";
    return make_symbol(":macros-listed");
}

static ValuePtr prim_help(const ValueVec& args) {
    (void)args;
    std::cout << R"(
=== scheme12 Debug Commands ===

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

Tracing:
  (trace-on)            Enable VM step-by-step trace
  (trace-off)           Disable trace
  
Example trace session:
  scheme12> (trace-on)
  scheme12> (+ 1 2)
  [Shows detailed VM execution steps]
  scheme12> (trace-off)

Example inspection:
  scheme12> (define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
  scheme12> fact
  [Shows closure structure with code]
  scheme12> (compile '(+ 1 2))
  [Shows compiled bytecode]
  scheme12> (disassemble fact)
  [Shows detailed disassembly]

================================
)";
    return make_symbol(":help");
}

static ValuePtr prim_gensym(const ValueVec& args) {
    std::string prefix = "g";
    if (!args.empty() && std::holds_alternative<GcString>(args[0]->data)) {
        prefix = to_std(std::get<GcString>(args[0]->data));
    }
    return make_gensym(prefix);
}

static void init_globals() {
    g_nil = make_value(NilTag{});
    
    // シングルトン作成（make_bool内で作られるが明示的に初期化）
    g_true = make_bool(true);
    g_false = make_bool(false);
    g_eof = make_eof_object();  // ← 追加
    
    g_globals.clear();
    g_macros.clear();
    g_symbol_intern.clear();
    
    // シングルトンを使用
    g_globals["true"] = g_true;
    g_globals["false"] = g_false;
    g_globals["nil"] = g_nil;
    g_globals["TRUE"] = g_true;
    g_globals["FALSE"] = g_false;
    g_globals["NIL"] = g_nil;
    g_globals["T"] = g_true;
    g_globals[":undef"] = make_symbol(":undef");
    g_globals["eof-object"] = g_eof;
    
    // Special forms
    g_globals["quote"] = make_special_form("quote");
    g_globals["if"] = make_special_form("if");
    g_globals["lambda"] = make_special_form("lambda");
    g_globals["define"] = make_special_form("define");
    g_globals["define-macro"] = make_special_form("define-macro");
    g_globals["set!"] = make_special_form("set!");
    g_globals["call/cc"] = make_special_form("call/cc");
    g_globals["apply"] = make_special_form("apply");
    g_globals["begin"] = make_special_form("begin");
    g_globals["let"] = make_special_form("let");
    g_globals["let*"] = make_special_form("let*");
    g_globals["letrec"] = make_special_form("letrec");
    g_globals["and"] = make_special_form("and");
    g_globals["or"] = make_special_form("or");
    g_globals["cond"] = make_special_form("cond");
    g_globals["case"] = make_special_form("case");
    g_globals["do"] = make_special_form("do");
    g_globals["quasiquote"] = make_special_form("quasiquote");
    
    // Arithmetic
    g_globals["+"] = make_prim("+", prim_add);
    g_globals["-"] = make_prim("-", prim_sub);
    g_globals["*"] = make_prim("*", prim_mul);
    g_globals["/"] = make_prim("/", prim_div);
    g_globals["modulo"] = make_prim("modulo", prim_modulo);
    g_globals["="] = make_prim("=", prim_num_eq);
    g_globals["<"] = make_prim("<", prim_lt);
    g_globals[">"] = make_prim(">", prim_gt);
    g_globals["<="] = make_prim("<=", prim_le);
    g_globals[">="] = make_prim(">=", prim_ge);
    
    // List operations
    g_globals["cons"] = make_prim("cons", prim_cons);
    g_globals["set-car!"] = make_prim("set-car!", prim_set_car);
    g_globals["set-cdr!"] = make_prim("set-cdr!", prim_set_cdr);
    g_globals["car"] = make_prim("car", prim_car);
    g_globals["cdr"] = make_prim("cdr", prim_cdr);
    g_globals["caar"] = make_prim("caar", prim_caar);
    g_globals["cdar"] = make_prim("cdar", prim_cdar);
    g_globals["cadr"] = make_prim("cadr", prim_cadr);
    g_globals["cddr"] = make_prim("cddr", prim_cddr);
    g_globals["caddr"] = make_prim("caddr", prim_caddr);
    g_globals["cdddr"] = make_prim("cdddr", prim_cdddr);
    g_globals["list"] = make_prim("list", prim_list);
    g_globals["append"] = make_prim("append", prim_append);
    
    // Predicates
    // NOTE: This implementation's eq? and eqv? both perform value comparison
    // for numbers (not pointer identity). This differs from strict R5RS where
    // eq? on numbers is implementation-dependent (often false for different
    // number objects with same value). For symbol equality, both use name
    // comparison which is standard.
    g_globals["eq?"] = make_prim("eq?", prim_eq);
    g_globals["eqv?"] = make_prim("eqv?", prim_eqv);
    g_globals["equal?"] = make_prim("equal?", prim_equal);
    g_globals["not"] = make_prim("not", prim_not);
    g_globals["symbol?"] = make_prim("symbol?", prim_symbolp);
    g_globals["number?"] = make_prim("number?", prim_numberp);
    g_globals["boolean?"] = make_prim("boolean?", prim_booleanp);
    g_globals["procedure?"] = make_prim("procedure?", prim_procedurep);
    g_globals["list?"] = make_prim("list?", prim_listp);
    g_globals["atom?"] = make_prim("atom?", prim_atomp);
    g_globals["length"] = make_prim("length", prim_length);
    g_globals["memv"] = make_prim("memv", prim_memv);
    g_globals["memq"] = make_prim("memq", prim_memq);
    g_globals["assq"] = make_prim("assq", prim_assq);
    g_globals["null?"] = make_prim("null?", prim_nullp);
    g_globals["pair?"] = make_prim("pair?", prim_pairp);
    
    // I/O
    g_globals["display"] = make_prim("display", prim_display);
    g_globals["write"] = make_prim("write", prim_write);
    g_globals["newline"] = make_prim("newline", prim_newline);
    g_globals["read"] = make_prim("read", prim_read_from_stdin);
    
    // File I/O
    g_globals["open-input-file"] = make_prim("open-input-file", prim_open_input_file);
    g_globals["open-output-file"] = make_prim("open-output-file", prim_open_output_file);
    g_globals["close-input-port"] = make_prim("close-input-port", prim_close_input_port);
    g_globals["close-output-port"] = make_prim("close-output-port", prim_close_output_port);
    g_globals["read-line"] = make_prim("read-line", prim_read_line);
    g_globals["write_newline"] = make_prim("write_newline", prim_write_newline);  // 元のまま残す
    g_globals["eof-object?"] = make_prim("eof-object?", prim_eof_objectp);
    g_globals["read-char"] = make_prim("read-char", prim_read_char);
    g_globals["write-char"] = make_prim("write-char", prim_write_char);
    g_globals["read-expr"] = make_prim("read-expr", prim_read_expr);
    g_globals["load"] = make_prim("load", prim_load);
    
    // String operations
    g_globals["string?"] = make_prim("string?", prim_stringp);
    g_globals["make-string"] = make_prim("make-string", prim_make_string);
    g_globals["string-length"] = make_prim("string-length", prim_string_length);
    g_globals["string-ref"] = make_prim("string-ref", prim_string_ref);
    g_globals["string-set!"] = make_prim("string-set!", prim_string_set);
    g_globals["substring"] = make_prim("substring", prim_substring);
    g_globals["string-append"] = make_prim("string-append", prim_string_append);
    g_globals["string->list"] = make_prim("string->list", prim_string_to_list);
    g_globals["list->string"] = make_prim("list->string", prim_list_to_string);
    g_globals["string=?"] = make_prim("string=?", prim_string_eq);
    g_globals["string<?"] = make_prim("string<?", prim_string_lt);
    g_globals["string>?"] = make_prim("string>?", prim_string_gt);
    g_globals["string<=?"] = make_prim("string<=?", prim_string_le);
    g_globals["string>=?"] = make_prim("string>=?", prim_string_ge);
    g_globals["number->string"] = make_prim("number->string", prim_number_to_string);
    g_globals["string->number"] = make_prim("string->number", prim_string_to_number);
    g_globals["char->integer"] = make_prim("char->integer", prim_char_to_integer);
    g_globals["integer->char"] = make_prim("integer->char", prim_integer_to_char);
    
    // Vector operations
    g_globals["vector?"] = make_prim("vector?", prim_vectorp);
    g_globals["make-vector"] = make_prim("make-vector", prim_make_vector);
    g_globals["vector"] = make_prim("vector", prim_vector);
    g_globals["vector-length"] = make_prim("vector-length", prim_vector_length);
    g_globals["vector-ref"] = make_prim("vector-ref", prim_vector_ref);
    g_globals["vector-set!"] = make_prim("vector-set!", prim_vector_set);
    g_globals["vector->list"] = make_prim("vector->list", prim_vector_to_list);
    g_globals["list->vector"] = make_prim("list->vector", prim_list_to_vector);
    
    // Utilities
    g_globals["gensym"] = make_prim("gensym", prim_gensym);
    
    // Random number generation
    g_globals["random"] = make_prim("random", prim_random);
    g_globals["random-seed"] = make_prim("random-seed", prim_random_seed);
    
    // Symbol/String conversion (NEW!)
    g_globals["symbol->string"] = make_prim("symbol->string", prim_symbol_to_string);
    g_globals["string->symbol"] = make_prim("string->symbol", prim_string_to_symbol);
    
    // Garbage collection
    g_globals["gc-collect"] = make_prim("gc-collect", prim_gc_collect);
    g_globals["gc-heap-size"] = make_prim("gc-heap-size", prim_gc_get_heap_size);
    g_globals["gc-free-bytes"] = make_prim("gc-free-bytes", prim_gc_get_free_bytes);
    
    // Debug commands
    g_globals["compile"] = make_prim("compile", prim_compile);
    g_globals["disassemble"] = make_prim("disassemble", prim_disassemble);
    g_globals["trace-on"] = make_prim("trace-on", prim_trace_on);
    g_globals["trace-off"] = make_prim("trace-off", prim_trace_off);
    g_globals["globals"] = make_prim("globals", prim_globals);
    g_globals["macros"] = make_prim("macros", prim_macros);
    g_globals["help"] = make_prim("help", prim_help);
}

static ValueVec read_all_exprs(const std::string& src) {
    Reader r(src);
    ValueVec out;
    while (!r.eof()) {
        ValuePtr x = r.read_expr();
        if (!x) break;
        out.push_back(x);
    }
    return out;
}

static bool is_balanced(const std::string& s) {
    int paren_count = 0;
    bool in_string = false;
    bool in_comment = false;
    
    for (std::size_t i = 0; i < s.size(); ++i) {
        char c = s[i];
        if (c == ';' && !in_string) {
            in_comment = true;
            continue;
        }
        if (c == '\n') {
            in_comment = false;
            continue;
        }
        if (in_comment) continue;
        if (c == '"' && (i == 0 || s[i-1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        
        // 修正：角括弧を削除（丸括弧のみ）
        if (c == '(') {
            ++paren_count;
        } else if (c == ')') {
            --paren_count;
            if (paren_count < 0) return false;
        }
    }
    return paren_count == 0 && !in_string;
}

static std::string read_multiline_input() {
    std::string accumulated;
    std::string line;
    bool first_line = true;
    
    while (true) {
        if (first_line) {
            std::cout << "scheme12> " << std::flush;
            first_line = false;
        } else {
            std::cout << "       ...> " << std::flush;
        }
        if (!std::getline(std::cin, line)) {
            return "";
        }
        if (line.empty() && accumulated.empty()) {
            return "";
        }
        if (!accumulated.empty()) {
            accumulated += "\n";
        }
        accumulated += line;
        if (is_balanced(accumulated)) {
            return accumulated;
        }
    }
}

int main(int argc, char** argv) {
    try {
        GC_INIT();
        // GCのヒープサイズを拡張
        GC_set_max_heap_size(1024 * 1024 * 1024);  // 1GB
        GC_enable_incremental();
        
        // より積極的なGCを設定
        GC_set_free_space_divisor(4);  // デフォルトは3、小さいほど頻繁にGC
        
        init_globals();
        load_startup_libraries(argv[0]);

        if (argc > 1) {
            for (int i = 1; i < argc; ++i) {
                std::string arg = argv[i];
                if (arg == "--help" || arg == "-h") {
#ifdef HAS_BIGNUM
                    std::cout << "scheme12_debug (SECD with Boost bignum + Debug)\n";
#else
                    std::cout << "scheme12_debug (SECD with long long + Debug)\n";
#endif
                    std::cout << "Usage:\n";
                    std::cout << "  scheme12_debug              Start interactive REPL\n";
                    std::cout << "  scheme12_debug --load FILE  Evaluate file and exit\n";
                    std::cout << "  scheme12_debug --help       Show this help\n";
                    std::cout << "\nDebug commands in REPL:\n";
                    std::cout << "  (help)           Show debug commands\n";
                    std::cout << "  (trace-on)       Enable VM trace\n";
                    std::cout << "  (trace-off)      Disable VM trace\n";
                    std::cout << "  (compile expr)   Show compiled code\n";
                    std::cout << "  (disassemble fn) Show function internals\n";
                    std::cout << "  (globals)        List global variables\n";
                    std::cout << "  (macros)         List macros\n";
                    return 0;
                }
                if (arg == "--load") {
                    if (i + 1 >= argc) {
                        std::cerr << "scheme12: --load needs a path\n";
                        return 1;
                    }
                    ++i;
                    ValuePtr out = load_from_path(argv[i]);
                    std::cout << to_string(out) << "\n";
                    continue;
                }
                std::cerr << "scheme12: unknown arg: " << arg << "\n";
                std::cerr << "try: scheme12 --help\n";
                return 1;
            }
            return 0;
        }

        std::cout << "scheme12 debug REPL. Type (help) for commands.\n";
        
        while (true) {
            std::string input = read_multiline_input();
            if (input.empty()) {
                if (std::cin.eof()) {
                    std::cout << "\nBye!\n";
                    break;
                }
                continue;
            }
            try {
                auto exprs = read_all_exprs(input);
                for (auto& expr : exprs) {
                    ValuePtr out = eval_top(expr);
                    std::cout << to_string(out) << "\n";
                }
            } catch (const std::exception& ex) {
                std::cerr << "Error: " << ex.what() << "\n";
            }
        }
    } catch (const std::exception& ex) {
        std::cerr << "Fatal error: " << ex.what() << std::endl;
        return 1;
    }
    return 0;
}

