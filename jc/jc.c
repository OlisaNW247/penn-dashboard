/*
 * jc.c
 *
 * The J compiler: translates a J source file into RISC-V assembly.
 *
 * Usage: ./jc source.j
 * Writes the assembly to source.s
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asm_gen.h"

// Builds the name of the output file by replacing the .j extension of
// j_name with .s. Returns a malloc'd string the caller must free, or NULL
// if j_name does not end in .j or memory ran out.
static char* asm_file_name(const char* j_name) {
  size_t length = strlen(j_name);
  if (length < 3 || strcmp(j_name + length - 2, ".j") != 0) {
    return NULL;
  }
  char* s_name = malloc(length + 1);
  if (s_name == NULL) {
    return NULL;
  }
  strcpy(s_name, j_name);
  s_name[length - 1] = 's';
  return s_name;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s source.j\n", argv[0]);
    return EXIT_FAILURE;
  }

  char* s_name = asm_file_name(argv[1]);
  if (s_name == NULL) {
    fprintf(stderr, "error: '%s' is not a .j file\n", argv[1]);
    return EXIT_FAILURE;
  }

  FILE* j_file = fopen(argv[1], "r");
  if (j_file == NULL) {
    perror(argv[1]);
    free(s_name);
    return EXIT_FAILURE;
  }

  FILE* asm_file = fopen(s_name, "w");
  if (asm_file == NULL) {
    perror(s_name);
    fclose(j_file);
    free(s_name);
    return EXIT_FAILURE;
  }

  bool ok = compile(j_file, asm_file);

  fclose(j_file);
  if (fclose(asm_file) != 0) {
    perror(s_name);
    ok = false;
  }

  if (!ok) {
    // do not leave half of a program behind
    remove(s_name);
  }

  free(s_name);
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
