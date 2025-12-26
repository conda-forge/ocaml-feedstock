(* No-op stripdebug replacement for cross-compilation
   Original stripdebug tries to EXECUTE the target binary, which won't run on build machine.
   This version just copies the file without stripping debug info. *)

let copy_file src dst =
  let ic = open_in_bin src in
  let oc = open_out_bin dst in
  let buf = Bytes.create 4096 in
  let rec loop () =
    match input ic buf 0 4096 with
    | 0 -> ()
    | n -> output oc buf 0 n; loop ()
  in
  loop ();
  close_in ic;
  close_out oc

let () =
  if Array.length Sys.argv < 3 then (
    Printf.eprintf "Usage: %s <source> <destination>\n" Sys.argv.(0);
    exit 1
  );
  copy_file Sys.argv.(1) Sys.argv.(2)
