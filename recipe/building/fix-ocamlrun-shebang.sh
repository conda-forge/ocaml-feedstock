fix_ocamlrun_shebang() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local shebang
  shebang=$(head -n 1 "$file")
  echo "DEBUG: shebang='$shebang'"

  if [[ "$shebang" == "#!/"*"bin/sh" ]]; then
    local exec_line
    exec_line=$(sed -n '2p' "$file")
    echo "DEBUG: exec_line='$exec_line'"

    if [[ "$exec_line" =~ exec.*ocamlrun.*\"\$0\".*\"\$@\" ]]; then
      echo "DEBUG: MATCHED - running sed"
      sed -i '2s|.*|exec "$(dirname "$0")/ocamlrun" "$0" "$@"|' "$file"
    else
      echo "DEBUG: NO MATCH"
    fi

  elif [[ "$shebang" == "#!"*"ocamlrun"* ]]; then
    # Direct ocamlrun shebang: replace with env
    sed -i '1s|.*|#!/usr/bin/env ocamlrun|' "$file"
  fi
}
