fix_ocamlrun_shebang() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local shebang
  shebang=$(head -n 1 "$file")

  if [[ "$shebang" == "#!/"*"bin/sh" ]]; then
    local exec_line
    exec_line=$(sed -n '2p' "$file")

    if [[ "$exec_line" =~ exec.*ocamlrun.*\"\$0\".*\"\$@\" ]]; then
      # Sibling ocamlrun when one ships beside the file (native bin), else PATH (cross bin)
      if [[ -x "$(dirname "$file")/ocamlrun" ]]; then
        sed -i '2s|.*|exec "$(dirname "$0")/ocamlrun" "$0" "$@"|' "$file"
      else
        sed -i '2s|.*|exec ocamlrun "$0" "$@"|' "$file"
      fi
    fi

  elif [[ "$shebang" == "#!"*"ocamlrun"* ]]; then
    if [[ "$file" == */lib/ocaml-cross-compilers/* ]]; then
      # Cross tree: env would find the wrong ocamlrun, so use the sh launcher
      # form (same layout OCaml emits for long paths) and resolve it above
      sed -i '1s|.*|#!/bin/sh\
exec ocamlrun "$0" "$@"|' "$file"
      fix_ocamlrun_shebang "$file"
    else
      # Direct ocamlrun shebang: replace with env
      sed -i '1s|.*|#!/usr/bin/env ocamlrun|' "$file"
    fi
  fi
}
