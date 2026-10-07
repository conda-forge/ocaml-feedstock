(* Validate the base relocation table of a PE32+ image: blocks must have
   strictly ascending page RVAs and every entry must be ABSOLUTE (0) or
   DIR64 (10). Usage: ocaml pe_reloc_check.ml <exe> *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 1) fmt

let data =
  if Array.length Sys.argv <> 2 then fail "usage: pe_reloc_check.ml <exe>"
  else begin
    let ic = open_in_bin Sys.argv.(1) in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    s
  end

let u16 o = Char.code data.[o] lor (Char.code data.[o + 1] lsl 8)
let u32 o = u16 o lor (u16 (o + 2) lsl 16)

let () =
  if String.length data < 0x40 then fail "file too small for a PE image"

let pe = u32 0x3c
let () =
  if pe + 24 > String.length data || String.sub data pe 4 <> "PE\000\000" then
    fail "missing PE signature"

let nsec = u16 (pe + 6)
let opt_size = u16 (pe + 20)
let opt = pe + 24
let () = if u16 opt <> 0x20b then fail "not a PE32+ image"

let reloc_rva = u32 (opt + 112 + (5 * 8))
let reloc_size = u32 (opt + 112 + (5 * 8) + 4)

let file_offset rva =
  let rec find i =
    if i >= nsec then fail "reloc RVA 0x%x not in any section" rva
    else begin
      let s = opt + opt_size + (i * 40) in
      let va = u32 (s + 12) in
      let span = max (u32 (s + 8)) (u32 (s + 16)) in
      if rva >= va && rva < va + span then u32 (s + 20) + (rva - va)
      else find (i + 1)
    end
  in
  find 0

let () =
  if reloc_size = 0 then (print_endline "reloc table ok: 0 blocks, 0 entries"; exit 0);
  let start = file_offset reloc_rva in
  if start + reloc_size > String.length data then fail "reloc directory overruns file";
  let blocks = ref 0 and entries = ref 0 and prev = ref (-1) and pos = ref 0 in
  while !pos < reloc_size do
    let b = start + !pos in
    if !pos + 8 > reloc_size then fail "truncated block header at +0x%x" !pos;
    let page = u32 b and size = u32 (b + 4) in
    if size < 8 || size land 1 <> 0 || !pos + size > reloc_size then
      fail "bad BlockSize %d at +0x%x" size !pos;
    if page <= !prev then
      fail "block at +0x%x: PageRVA 0x%x not above previous 0x%x" !pos page !prev;
    for i = 0 to ((size - 8) / 2) - 1 do
      let e = u16 (b + 8 + (i * 2)) in
      let ty = e lsr 12 in
      if ty <> 0 && ty <> 10 then
        fail "block at +0x%x entry %d: type %d (raw 0x%04x)" !pos i ty e;
      incr entries
    done;
    prev := page;
    incr blocks;
    pos := !pos + size
  done;
  Printf.printf "reloc table ok: %d blocks, %d entries\n" !blocks !entries
