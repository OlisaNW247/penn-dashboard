/*
 * token.c
 *
 * Reads J tokens one at a time from a source file.
 */

#include "token.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

// current line of the J source file, used for error messages
int line_number = 1;

// a reserved word that maps directly onto one token type
typedef struct keyword_st {
  const char* text;
  token_type type;
} keyword;

static const keyword KEYWORDS[] = {
    {"defun", DEFUN}, {"return", RETURN},     {"+", PLUS},      {"-", MINUS},
    {"*", MUL},       {"/", DIV},             {"%", MOD},       {"and", AND},
    {"or", OR},       {"not", NOT},           {"lt", LT},       {"le", LE},
    {"eq", EQ},       {"ge", GE},             {"gt", GT},       {"if", IF},
    {"else", ELSE},   {"endif", ENDIF},       {"while", WHILE},
    {"endwhile", ENDWHILE},                   {"drop", DROP},   {"dup", DUP},
    {"swap", SWAP},   {"rot", ROT},
};

static const int NUM_KEYWORDS = sizeof(KEYWORDS) / sizeof(KEYWORDS[0]);

// Skips whitespace and comments. Returns the first character of the next
// token, or EOF if there are no more tokens in the file.
static int skip_to_token(FILE* j_file) {
  int c = fgetc(j_file);
  while (c != EOF) {
    if (c == ';') {
      // a comment runs until the end of the line
      while (c != EOF && c != '\n') {
        c = fgetc(j_file);
      }
    } else if (c == '\n') {
      line_number++;
      c = fgetc(j_file);
    } else if (isspace(c)) {
      c = fgetc(j_file);
    } else {
      break;
    }
  }
  return c;
}

// Returns true if every character of str satisfies the given <ctype.h> test.
// An empty string never satisfies the test.
static bool all_chars(const char* str, int (*test)(int)) {
  if (*str == '\0') {
    return false;
  }
  for (; *str != '\0'; str++) {
    if (!test((unsigned char)*str)) {
      return false;
    }
  }
  return true;
}

// Tries to interpret str as a decimal literal: digits with an optional
// leading minus sign that fit in a 32-bit two's complement integer.
static bool parse_decimal(const char* str, int32_t* value) {
  const char* digits = (str[0] == '-') ? str + 1 : str;
  if (!all_chars(digits, isdigit)) {
    return false;
  }
  errno = 0;
  long long parsed = strtoll(str, NULL, 10);
  if (errno != 0 || parsed < INT32_MIN || parsed > INT32_MAX) {
    return false;
  }
  *value = (int32_t)parsed;
  return true;
}

// Tries to interpret str as a hex literal: 0x followed by 1 to 8 hex digits.
static bool parse_hex(const char* str, int32_t* value) {
  if (str[0] != '0' || str[1] != 'x') {
    return false;
  }
  const char* digits = str + 2;
  if (!all_chars(digits, isxdigit) || strlen(digits) > 8) {
    return false;
  }
  *value = (int32_t)(uint32_t)strtoul(digits, NULL, 16);
  return true;
}

// Tries to interpret str as get_argN or set_argN where N is from 1 to 8.
static bool parse_arg(const char* str, token* output) {
  token_type type;
  if (strncmp(str, "get_arg", 7) == 0) {
    type = GET_ARG;
  } else if (strncmp(str, "set_arg", 7) == 0) {
    type = SET_ARG;
  } else {
    return false;
  }
  if (str[7] < '1' || str[7] > '8' || str[8] != '\0') {
    return false;
  }
  output->type = type;
  output->arg_no = str[7] - '0';
  return true;
}

// Returns true if str is a legal identifier: a letter followed by any number
// of letters, digits and underscores.
static bool is_identifier(const char* str) {
  if (!isalpha((unsigned char)str[0])) {
    return false;
  }
  for (str++; *str != '\0'; str++) {
    if (!isalnum((unsigned char)*str) && *str != '_') {
      return false;
    }
  }
  return true;
}

// Sets the type (and any extra fields) of output based on output->str.
static void classify(token* output) {
  const char* str = output->str;

  for (int i = 0; i < NUM_KEYWORDS; i++) {
    if (strcmp(str, KEYWORDS[i].text) == 0) {
      output->type = KEYWORDS[i].type;
      return;
    }
  }

  if (parse_hex(str, &output->literal_value) ||
      parse_decimal(str, &output->literal_value)) {
    output->type = LITERAL;
    return;
  }

  // anything that starts with get_arg / set_arg must be a legal argument
  // token, so that get_arg9 is an error instead of a call to "get_arg9"
  if (strncmp(str, "get_arg", 7) == 0 || strncmp(str, "set_arg", 7) == 0) {
    if (!parse_arg(str, output)) {
      output->type = BAD_TOKEN;
    }
    return;
  }

  output->type = is_identifier(str) ? IDENT : BAD_TOKEN;
}

bool next_token(FILE* j_file, token* output) {
  output->type = BAD_TOKEN;
  output->literal_value = 0;
  output->arg_no = 0;
  output->str[0] = '\0';

  int c = skip_to_token(j_file);
  if (c == EOF) {
    return false;
  }

  // a token runs until whitespace, the start of a comment or the end of file
  int length = 0;
  bool too_long = false;
  while (c != EOF && !isspace(c) && c != ';') {
    if (length < MAX_TOKEN_LENGTH) {
      output->str[length++] = (char)c;
    } else {
      too_long = true;
    }
    c = fgetc(j_file);
  }
  output->str[length] = '\0';

  // leave the terminating character for the next call so that newlines are
  // counted and comments are skipped in one place
  if (c != EOF) {
    ungetc(c, j_file);
  }

  if (too_long) {
    return false;
  }

  classify(output);
  return output->type != BAD_TOKEN;
}

void print_token(FILE* f, token to_print) {
  static const char* const NAMES[] = {
      "DEFUN", "IDENT",  "RETURN", "PLUS",     "MINUS", "MUL",
      "DIV",   "MOD",    "AND",    "OR",       "NOT",   "LT",
      "LE",    "EQ",     "GE",     "GT",       "IF",    "ELSE",
      "ENDIF", "WHILE",  "ENDWHILE", "DROP",   "DUP",   "SWAP",
      "ROT",   "GET_ARG", "SET_ARG", "LITERAL", "BAD_TOKEN"};

  fprintf(f, "%s", NAMES[to_print.type]);
  switch (to_print.type) {
    case IDENT:
    case BAD_TOKEN:
      fprintf(f, " %s", to_print.str);
      break;
    case LITERAL:
      fprintf(f, " %d", to_print.literal_value);
      break;
    case GET_ARG:
    case SET_ARG:
      fprintf(f, " %d", to_print.arg_no);
      break;
    default:
      break;
  }
  fprintf(f, "\n");
}
