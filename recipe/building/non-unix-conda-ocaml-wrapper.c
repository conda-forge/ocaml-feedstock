/*
 * Generic conda-ocaml wrapper for Windows
 *
 * Reads CONDA_OCAML_<TOOL> environment variable and executes that program
 * with all arguments passed through. Falls back to default if not set.
 *
 * Compile with: gcc -o conda-ocaml-cc.exe conda-ocaml-wrapper.c -DTOOL_NAME=CC -DDEFAULT_TOOL="gcc.exe"
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
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

int main(int argc, char *argv[]) {
    const char *tool;
    char *env_val;
    int i;

    /* Get tool from environment, fall back to default */
    env_val = getenv(ENV_VAR_NAME);
    if (env_val && env_val[0] != '\0') {
        tool = env_val;
    } else {
        tool = DEFAULT_TOOL;
    }

    /* Replace argv[0] with the actual tool */
    argv[0] = (char *)tool;

    /* Execute the tool with all arguments */
    /* _spawnvp searches PATH and waits for completion */
    int result = _spawnvp(_P_WAIT, tool, (const char *const *)argv);

    if (result == -1) {
        fprintf(stderr, "conda-ocaml-wrapper: failed to execute '%s': %s\n",
                tool, strerror(errno));
        fprintf(stderr, "  Environment variable %s = '%s'\n",
                ENV_VAR_NAME, env_val ? env_val : "(not set)");
        return 127;
    }

    return result;
}
