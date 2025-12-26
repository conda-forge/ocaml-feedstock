#!/bin/bash
# Patch utils/config.generated.ml for cross-compilation
# Source this file with: source "${RECIPE_DIR}/building/patch-config-generated.sh"

# Patch config.generated.ml for runtime paths
# Uses environment variables for relocatable binaries (expanded at runtime)
#
# Arguments:
#   $1 - config file path (usually utils/config.generated.ml)
#   $2 - platform type ("macos" or "linux")
#   $3 - optional model (e.g., "ppc64le" for PowerPC)
#
# Required environment variables:
#   _NEEDS_DL - set to 1 for Linux platforms requiring -ldl
patch_config_generated() {
  local config_file="$1"
  local platform_type="$2"
  local model="${3:-}"

  echo "Patching ${config_file} for ${platform_type} platform..."

  # Common patches (both platforms)
  sed -i \
    -e 's/^let asm = .*/let asm = {|\$AS|}/' \
    -e 's/^let c_compiler = .*/let c_compiler = {|\$CC|}/' \
    -e 's/^let mkexe = .*/let mkexe = {|\$CC|}/' \
    "$config_file"

  # Platform-specific patches
  if [[ "${platform_type}" == "macos" ]]; then
    sed -i \
      -e 's/^let mkdll = .*/let mkdll = {|\$CC -shared -undefined dynamic_lookup|}/' \
      -e 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared -undefined dynamic_lookup|}/' \
      "$config_file"
  else
    # Linux
    sed -i \
      -e 's/^let mkdll = .*/let mkdll = {|\$CC -shared|}/' \
      -e 's/^let mkmaindll = .*/let mkmaindll = {|\$CC -shared|}/' \
      -e 's/^let native_c_libraries = {|\(.*\)|}/let native_c_libraries = {|\1 -ldl|}/' \
      "$config_file"
  fi

  # Architecture-specific model (currently only ppc64le)
  if [[ -n "${model}" ]]; then
    sed -i "s/^let model = .*/let model = {|${model}|}/" "$config_file"
  fi

  # Linux-only: Patch ar to use $AR environment variable (relocatable)
  if [[ "${platform_type}" == "linux" ]]; then
    sed -i 's/^let ar = .*/let ar = {|\$AR|}/' "$config_file"
  fi

  echo "Patching ${config_file} complete."
}

# Patch Makefile.config for cross-compilation linker flags
# Arguments:
#   $1 - platform type ("macos" or "linux")
#
# Required environment variables:
#   _NEEDS_DL - set to 1 for Linux platforms requiring -ldl
patch_makefile_config() {
  local platform_type="$1"

  if [[ "${_NEEDS_DL}" == "1" ]]; then
    echo "Adding -ldl to NATIVECCLIBS in Makefile.config..."
    sed -i 's/^\(NATIVECCLIBS=.*\)$/\1 -ldl/' Makefile.config
  fi
}
