# shellcheck shell=sh
# Cross-compiler deactivation — restore native state and clean up

# Ensure native mode before cleanup
if type ocaml_use_native >/dev/null 2>&1; then
  ocaml_use_native
fi

unset -f ocaml_use_cross 2>/dev/null || true
unset -f ocaml_use_native 2>/dev/null || true

unset _OCAML_NATIVE_CC _OCAML_NATIVE_AS _OCAML_NATIVE_AR
unset _OCAML_NATIVE_LD _OCAML_NATIVE_RANLIB
unset _OCAML_NATIVE_MKEXE _OCAML_NATIVE_MKDLL
unset _OCAML_NATIVE_OCAMLLIB _OCAML_NATIVE_OCAML_PREFIX
unset _OCAML_CROSS_TARGET _OCAML_CROSS_TARGET_ID _OCAML_CROSS_PREFIX
unset _OCAML_CROSS_CC _OCAML_CROSS_AS _OCAML_CROSS_AR
unset _OCAML_CROSS_LD _OCAML_CROSS_RANLIB
unset _OCAML_CROSS_MKEXE _OCAML_CROSS_MKDLL
unset OCAML_CROSS_TARGET OCAML_CROSS_PREFIX OCAML_CROSS_MODE
