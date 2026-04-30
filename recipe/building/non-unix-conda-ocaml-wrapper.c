/*
 * Generic conda-ocaml wrapper for non-unix
 *
 * Reads CONDA_OCAML_<TOOL> environment variable and executes that program
 * with all arguments passed through. Falls back to default if not set.
 *
 * The tool string may be multi-word (e.g. "zig.exe cc -target aarch64-windows-gnu").
 * On Unix, the shell wrapper splits on spaces implicitly via exec ${VAR} "$@".
 * Here we must tokenize explicitly before calling _spawnvp().
 *
 * Compile with: gcc -o conda-ocaml-cc.exe conda-ocaml-wrapper.c -DTOOL_NAME=CC -DDEFAULT_TOOL="gcc.exe"
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <errno.h>
#include <windows.h>

/* These are defined at compile time via -D flags */
#ifndef TOOL_NAME
#error "TOOL_NAME must be defined (e.g., -DTOOL_NAME=CC)"
#endif

#ifndef DEFAULT_TOOL
#error "DEFAULT_TOOL must be defined (e.g., -DDEFAULT_TOOL=\"gcc.exe\")"
#endif

/* Stringify macros */
#define STR(x) #x
#define XSTR(x) STR(x)

/* Build environment variable name: CONDA_OCAML_CC, CONDA_OCAML_AS, etc. */
#define ENV_VAR_NAME "CONDA_OCAML_" XSTR(TOOL_NAME)

#define MAX_ARGS 256

int main(int argc, char *argv[]) {
    const char *env_val;
    char *tool_copy;
    const char *new_argv[MAX_ARGS];
    int new_argc = 0;
    char *token;

    /* Get tool from environment, fall back to default */
    env_val = getenv(ENV_VAR_NAME);
    if (!env_val || env_val[0] == '\0') {
        env_val = DEFAULT_TOOL;
    }

    /* Tokenize tool string on spaces (e.g. "zig.exe cc -target triple") */
    tool_copy = _strdup(env_val);
    if (!tool_copy) {
        fprintf(stderr, "conda-ocaml-wrapper: out of memory\n");
        return 127;
    }

    token = strtok(tool_copy, " \t");
    while (token && new_argc < MAX_ARGS - 1) {
        new_argv[new_argc++] = token;
        token = strtok(NULL, " \t");
    }

    /* Append caller's argv[1..argc-1] */
    for (int i = 1; i < argc && new_argc < MAX_ARGS - 1; i++) {
        new_argv[new_argc++] = argv[i];
    }
    new_argv[new_argc] = NULL;

    /* Execute: new_argv[0] is the executable, searched via PATH */
    int result = _spawnvp(_P_WAIT, new_argv[0], new_argv);

    if (result == -1) {
        fprintf(stderr, "conda-ocaml-wrapper: failed to execute '%s': %s\n",
                new_argv[0], strerror(errno));
        fprintf(stderr, "  Environment variable %s = '%s'\n",
                ENV_VAR_NAME, env_val);
        return 127;
    }

    free(tool_copy);
    return result;
}
