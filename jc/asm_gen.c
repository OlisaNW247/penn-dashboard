/*
 * asm_gen.c
 *
 * Generates RISC-V assembly for J tokens.
 *
 * The J stack lives on the RISC-V stack: sp always points at the top J
 * value, each value is 4 bytes and the stack grows towards lower addresses.
 * t0, t1 and t2 are scratch registers and never hold a value across tokens.
 *
 * Functions use the clang frame layout: ra at -4(s0), the caller's s0 at
 * -8(s0), and everything below s0 - 16 is the function's J stack.
 */

#include "asm_gen.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "token.h"

// bytes used by the saved ra and s0 at the top of every frame
#define FRAME_SIZE 16

typedef enum { BLOCK_IF, BLOCK_WHILE } block_kind;

// an if statement or while loop that has not been closed yet
typedef struct block_st {
  block_kind kind;
  int id;          // number used to make this block's labels unique
  bool seen_else;  // only meaningful for BLOCK_IF
  int line;        // where the block started, for error messages
} block;

// everything the compiler needs to remember between tokens
typedef struct compiler_st {
  FILE* out;
  block* blocks;  // LIFO stack of the open if / while blocks
  int num_blocks;
  int capacity;
  int next_id;                             // id for the next if / while
  bool in_function;                        // has a defun been seen?
  bool has_return;                         // has that function returned?
  char function[MAX_TOKEN_LENGTH + 1];     // name of the current function
} compiler;

// Reports a problem with the J program on stderr.
static void error(const char* format, ...) {
  va_list args;
  va_start(args, format);
  fprintf(stderr, "error: line %d: ", line_number);
  vfprintf(stderr, format, args);
  fprintf(stderr, "\n");
  va_end(args);
}

/* ---------- the stack of open blocks ---------- */

static bool push_block(compiler* c, block_kind kind) {
  if (c->num_blocks == c->capacity) {
    int capacity = (c->capacity == 0) ? 8 : c->capacity * 2;
    block* blocks = realloc(c->blocks, capacity * sizeof(block));
    if (blocks == NULL) {
      error("out of memory");
      return false;
    }
    c->blocks = blocks;
    c->capacity = capacity;
  }
  block* b = &c->blocks[c->num_blocks++];
  b->kind = kind;
  b->id = c->next_id++;
  b->seen_else = false;
  b->line = line_number;
  return true;
}

// Returns the innermost open block if it has the given kind, otherwise NULL.
static block* top_block(compiler* c, block_kind kind) {
  if (c->num_blocks == 0 || c->blocks[c->num_blocks - 1].kind != kind) {
    return NULL;
  }
  return &c->blocks[c->num_blocks - 1];
}

// Reports the innermost unclosed block, if any. Returns true if all blocks
// are closed.
static bool check_blocks_closed(compiler* c) {
  if (c->num_blocks == 0) {
    return true;
  }
  block* b = &c->blocks[c->num_blocks - 1];
  error("'%s' on line %d is never closed with '%s'",
        b->kind == BLOCK_IF ? "if" : "while", b->line,
        b->kind == BLOCK_IF ? "endif" : "endwhile");
  return false;
}

// Warns if the current function never returns.
static void check_function_returns(compiler* c) {
  if (c->in_function && !c->has_return) {
    fprintf(stderr, "warning: function '%s' has no return\n", c->function);
  }
}

/* ---------- small pieces of assembly ---------- */

// pushes t0 onto the J stack
static void push_t0(FILE* out) {
  fprintf(out, "\taddi\tsp, sp, -4\n");
  fprintf(out, "\tsw\tt0, 0(sp)\n");
}

// pops the top of the J stack into t0
static void pop_t0(FILE* out) {
  fprintf(out, "\tlw\tt0, 0(sp)\n");
  fprintf(out, "\taddi\tsp, sp, 4\n");
}

// Pops the top two values (top in t0, next in t1), runs the given
// instructions which must leave their result in t0, and pushes the result.
static void binary_op(FILE* out, const char* instructions) {
  fprintf(out, "\tlw\tt0, 0(sp)\n");
  fprintf(out, "\tlw\tt1, 4(sp)\n");
  fprintf(out, "\taddi\tsp, sp, 4\n");
  fprintf(out, "%s", instructions);
  fprintf(out, "\tsw\tt0, 0(sp)\n");
}

// Pushes a 32-bit constant. Instruction immediates are only 12 bits wide, so
// larger values are built from an upper 20-bit part and a lower 12-bit part.
static void gen_literal(FILE* out, int32_t value) {
  if (value >= -2048 && value <= 2047) {
    fprintf(out, "\taddi\tt0, zero, %d\n", value);
  } else {
    uint32_t bits = (uint32_t)value;
    // addi sign extends its immediate, so round the upper part up whenever
    // the lower part will be negative
    uint32_t upper = ((bits + 0x800) >> 12) & 0xFFFFF;
    int32_t lower = (int32_t)(bits & 0xFFF);
    if (lower >= 0x800) {
      lower -= 0x1000;
    }
    fprintf(out, "\tlui\tt0, %u\n", upper);
    if (lower != 0) {
      fprintf(out, "\taddi\tt0, t0, %d\n", lower);
    }
  }
  push_t0(out);
}

/* ---------- functions ---------- */

static bool gen_defun(compiler* c, FILE* j_file) {
  if (!check_blocks_closed(c)) {
    return false;
  }
  check_function_returns(c);

  token name;
  if (!next_token(j_file, &name) || name.type != IDENT) {
    error("expected a function name after 'defun' but found '%s'", name.str);
    return false;
  }

  c->in_function = true;
  c->has_return = false;
  strcpy(c->function, name.str);

  fprintf(c->out, "\n\t.globl\t%s\n", name.str);
  fprintf(c->out, "%s:\n", name.str);
  fprintf(c->out, "\taddi\tsp, sp, -%d\n", FRAME_SIZE);
  fprintf(c->out, "\tsw\tra, %d(sp)\n", FRAME_SIZE - 4);
  fprintf(c->out, "\tsw\ts0, %d(sp)\n", FRAME_SIZE - 8);
  fprintf(c->out, "\taddi\ts0, sp, %d\n", FRAME_SIZE);
  return true;
}

static void gen_return(compiler* c) {
  c->has_return = true;
  // the return value is the top of the J stack. Whatever else the function
  // left on its J stack is discarded by resetting sp from the frame pointer.
  fprintf(c->out, "\tlw\ta0, 0(sp)\n");
  fprintf(c->out, "\taddi\tsp, s0, -%d\n", FRAME_SIZE);
  fprintf(c->out, "\tlw\tra, %d(sp)\n", FRAME_SIZE - 4);
  fprintf(c->out, "\tlw\ts0, %d(sp)\n", FRAME_SIZE - 8);
  fprintf(c->out, "\taddi\tsp, sp, %d\n", FRAME_SIZE);
  fprintf(c->out, "\tret\n");
}

static void gen_call(compiler* c, const char* name) {
  fprintf(c->out, "\tcall\t%s\n", name);
  // the return value becomes the new top of the J stack
  fprintf(c->out, "\taddi\tsp, sp, -4\n");
  fprintf(c->out, "\tsw\ta0, 0(sp)\n");
}

/* ---------- control flow ---------- */

// Branches are written as a short conditional branch over an unconditional
// jump so that the body of an if or while can be arbitrarily long.

static bool gen_if(compiler* c) {
  if (!push_block(c, BLOCK_IF)) {
    return false;
  }
  int id = c->blocks[c->num_blocks - 1].id;
  pop_t0(c->out);
  fprintf(c->out, "\tbne\tt0, zero, .Ljc_then_%d\n", id);
  fprintf(c->out, "\tj\t.Ljc_else_%d\n", id);
  fprintf(c->out, ".Ljc_then_%d:\n", id);
  return true;
}

static bool gen_else(compiler* c) {
  block* b = top_block(c, BLOCK_IF);
  if (b == NULL) {
    error("'else' without a matching 'if'");
    return false;
  }
  if (b->seen_else) {
    error("second 'else' for the 'if' on line %d", b->line);
    return false;
  }
  b->seen_else = true;
  fprintf(c->out, "\tj\t.Ljc_endif_%d\n", b->id);
  fprintf(c->out, ".Ljc_else_%d:\n", b->id);
  return true;
}

static bool gen_endif(compiler* c) {
  block* b = top_block(c, BLOCK_IF);
  if (b == NULL) {
    error("'endif' without a matching 'if'");
    return false;
  }
  if (!b->seen_else) {
    // no else block: a false condition skips straight to the end
    fprintf(c->out, ".Ljc_else_%d:\n", b->id);
  }
  fprintf(c->out, ".Ljc_endif_%d:\n", b->id);
  c->num_blocks--;
  return true;
}

static bool gen_while(compiler* c) {
  if (!push_block(c, BLOCK_WHILE)) {
    return false;
  }
  int id = c->blocks[c->num_blocks - 1].id;
  fprintf(c->out, ".Ljc_while_%d:\n", id);
  pop_t0(c->out);
  fprintf(c->out, "\tbne\tt0, zero, .Ljc_body_%d\n", id);
  fprintf(c->out, "\tj\t.Ljc_endwhile_%d\n", id);
  fprintf(c->out, ".Ljc_body_%d:\n", id);
  return true;
}

static bool gen_endwhile(compiler* c) {
  block* b = top_block(c, BLOCK_WHILE);
  if (b == NULL) {
    error("'endwhile' without a matching 'while'");
    return false;
  }
  fprintf(c->out, "\tj\t.Ljc_while_%d\n", b->id);
  fprintf(c->out, ".Ljc_endwhile_%d:\n", b->id);
  c->num_blocks--;
  return true;
}

/* ---------- one token ---------- */

// Generates the assembly for a single token. j_file is only read from when
// the token needs a following token (the name after defun).
static bool gen_token(compiler* c, FILE* j_file, const token* t) {
  FILE* out = c->out;

  switch (t->type) {
    case DEFUN:
      return gen_defun(c, j_file);
    case IDENT:
      gen_call(c, t->str);
      return true;
    case RETURN:
      gen_return(c);
      return true;

    case LITERAL:
      gen_literal(out, t->literal_value);
      return true;

    // arithmetic: the top of the stack is the first operand
    case PLUS:
      binary_op(out, "\tadd\tt0, t0, t1\n");
      return true;
    case MINUS:
      binary_op(out, "\tsub\tt0, t0, t1\n");
      return true;
    case MUL:
      binary_op(out, "\tmul\tt0, t0, t1\n");
      return true;
    case DIV:
      binary_op(out, "\tdiv\tt0, t0, t1\n");
      return true;
    case MOD:
      binary_op(out, "\trem\tt0, t0, t1\n");
      return true;

    // bitwise logic
    case AND:
      binary_op(out, "\tand\tt0, t0, t1\n");
      return true;
    case OR:
      binary_op(out, "\tor\tt0, t0, t1\n");
      return true;
    case NOT:
      fprintf(out, "\tlw\tt0, 0(sp)\n");
      fprintf(out, "\txori\tt0, t0, -1\n");
      fprintf(out, "\tsw\tt0, 0(sp)\n");
      return true;

    // signed comparisons of a (top, t0) against b (next, t1)
    case LT:  // a < b
      binary_op(out, "\tslt\tt0, t0, t1\n");
      return true;
    case LE:  // a <= b is !(b < a)
      binary_op(out, "\tslt\tt0, t1, t0\n\txori\tt0, t0, 1\n");
      return true;
    case EQ:  // a == b is (a ^ b) == 0
      binary_op(out, "\txor\tt0, t0, t1\n\tsltiu\tt0, t0, 1\n");
      return true;
    case GE:  // a >= b is !(a < b)
      binary_op(out, "\tslt\tt0, t0, t1\n\txori\tt0, t0, 1\n");
      return true;
    case GT:  // a > b is b < a
      binary_op(out, "\tslt\tt0, t1, t0\n");
      return true;

    case IF:
      return gen_if(c);
    case ELSE:
      return gen_else(c);
    case ENDIF:
      return gen_endif(c);
    case WHILE:
      return gen_while(c);
    case ENDWHILE:
      return gen_endwhile(c);

    // stack manipulation
    case DROP:
      fprintf(out, "\taddi\tsp, sp, 4\n");
      return true;
    case DUP:
      fprintf(out, "\tlw\tt0, 0(sp)\n");
      push_t0(out);
      return true;
    case SWAP:
      fprintf(out, "\tlw\tt0, 0(sp)\n");
      fprintf(out, "\tlw\tt1, 4(sp)\n");
      fprintf(out, "\tsw\tt1, 0(sp)\n");
      fprintf(out, "\tsw\tt0, 4(sp)\n");
      return true;
    case ROT:  // x y z becomes y z x
      fprintf(out, "\tlw\tt0, 0(sp)\n");
      fprintf(out, "\tlw\tt1, 4(sp)\n");
      fprintf(out, "\tlw\tt2, 8(sp)\n");
      fprintf(out, "\tsw\tt1, 8(sp)\n");
      fprintf(out, "\tsw\tt0, 4(sp)\n");
      fprintf(out, "\tsw\tt2, 0(sp)\n");
      return true;

    // argument N lives in register a(N - 1)
    case GET_ARG:
      fprintf(out, "\taddi\tsp, sp, -4\n");
      fprintf(out, "\tsw\ta%d, 0(sp)\n", t->arg_no - 1);
      return true;
    case SET_ARG:
      fprintf(out, "\tlw\ta%d, 0(sp)\n", t->arg_no - 1);
      fprintf(out, "\taddi\tsp, sp, 4\n");
      return true;

    case BAD_TOKEN:
    default:
      error("illegal token '%s'", t->str);
      return false;
  }
}

bool compile(FILE* j_file, FILE* asm_file) {
  compiler c;
  c.out = asm_file;
  c.blocks = NULL;
  c.num_blocks = 0;
  c.capacity = 0;
  c.next_id = 0;
  c.in_function = false;
  c.has_return = false;
  c.function[0] = '\0';

  line_number = 1;
  bool ok = true;
  token t;

  while (ok && next_token(j_file, &t)) {
    fprintf(asm_file, "\t# %s\n", t.str);
    ok = gen_token(&c, j_file, &t);
  }

  if (ok) {
    // next_token stops both at the end of the file and at tokens it cannot
    // read, and only the first of those is fine
    if (!feof(j_file) || t.str[0] != '\0') {
      error("illegal token '%s'", t.str);
      ok = false;
    } else {
      ok = check_blocks_closed(&c);
      check_function_returns(&c);
    }
  }

  free(c.blocks);
  return ok;
}
