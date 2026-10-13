fix_ocamlrun_shebang() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local shebang
  shebang=$(head -n 1 "$file")

  if [[ "$shebang" == "#!/"*"bin/sh" ]]; then
    local exec_line
    exec_line=$(sed -n '2p' "$file")

    if [[ "$exec_line" =~ exec.*ocamlrun.*\"\$0\".*\"\$@\" ]]; then
      # Sibling ocamlrun when present (native bin), else PATH (cross bin ships none)
      sed -i '2s#.*#r="$(dirname "$0")/ocamlrun"; [ -x "$r" ] || r=ocamlrun; exec "$r" "$0" "$@"#' "$file"
    fi

  elif [[ "$shebang" == "#!"*"ocamlrun"* ]]; then
    # Direct ocamlrun shebang: replace with env
    sed -i '1s|.*|#!/usr/bin/env ocamlrun|' "$file"
  fi
}
