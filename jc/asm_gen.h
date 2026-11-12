#ifndef ASM_GEN_H_
#define ASM_GEN_H_
/*
 * asm_gen.h
 *
 * Translates a J source file into RISC-V assembly.
 */

#include <stdbool.h>
#include <stdio.h>

// Compiles a whole J program.
//
// Arguments:
// - j_file: the J source, open for reading
// - asm_file: where the generated RISC-V assembly is written
//
// Return Value:
// - true if the whole file was compiled
// - false if the J program is malformed or memory ran out. A description of
//   the problem is printed to stderr and asm_file is left incomplete.
bool compile(FILE* j_file, FILE* asm_file);

#endif  // ASM_GEN_H_
