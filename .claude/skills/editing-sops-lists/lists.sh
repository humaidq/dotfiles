#!/usr/bin/env bash
# Work with the encrypted router lists in secrets/router/ without fighting sops.
#
# The lists are sops *binary* files: plain text going in, plain text coming out,
# with sops handling only the envelope. That makes them editable but not
# greppable, and the tools in modules/router/ (fetch-v2ray-nodes.py and
# friends) want real files on disk. Hence `checkout` and `commit`.
#
#   lists.sh ls                     what exists, and whether a checkout is dirty
#   lists.sh edit <name>            $EDITOR on one list, re-encrypted on save
#   lists.sh cat <name>             decrypt one list to stdout
#   lists.sh grep <pattern> [name]  search across every list, or one
#   lists.sh checkout [name]        decrypt into .lists-work/ for tooling
#   lists.sh commit [name]          re-encrypt from .lists-work/, if changed
#   lists.sh diff [name]            what checkout would change on commit
#   lists.sh discard                delete .lists-work/
#   lists.sh rotate                 sops updatekeys after a .sops.yaml change
#
# `name` is the file name with or without the custom- prefix and .txt suffix:
# `blocklist`, `custom-blocklist`, and `custom-blocklist.txt` all work.
set -euo pipefail

repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
dir="$repo/secrets/router"
work="$repo/.lists-work"

die() { echo "lists.sh: $*" >&2; exit 1; }

# Accepts blocklist / custom-blocklist / custom-blocklist.txt.
resolve() {
  local want=$1 f
  for f in "$dir"/*.txt; do
    local b; b=$(basename "$f")
    if [ "$b" = "$want" ] || [ "$b" = "$want.txt" ] ||
       [ "$b" = "custom-$want.txt" ] || [ "${b%.txt}" = "$want" ]; then
      printf '%s' "$b"; return 0
    fi
  done
  die "no list matching '$want'. Try: lists.sh ls"
}

names() { for f in "$dir"/*.txt; do basename "$f"; done; }

cmd_ls() {
  printf '%-36s %8s  %s\n' NAME LINES STATE
  for b in $(names); do
    local lines state="encrypted"
    lines=$(sops -d "$dir/$b" | grep -cv '^[[:space:]]*#\|^[[:space:]]*$' || true)
    if [ -f "$work/$b" ]; then
      if sops -d "$dir/$b" | cmp -s - "$work/$b"; then state="checked out, clean"
      else state="checked out, MODIFIED"; fi
    fi
    printf '%-36s %8s  %s\n' "$b" "$lines" "$state"
  done
}

cmd_edit() {
  [ $# -ge 1 ] || die "edit needs a list name"
  local b; b=$(resolve "$1")
  # sops handles the decrypt/edit/re-encrypt cycle and never writes plaintext
  # to disk. This is the right way to change one or two lines.
  sops "$dir/$b"
  echo "lists.sh: edited $b — remember the unit restart (see lists.nix restartUnits)" >&2
}

cmd_cat() {
  [ $# -ge 1 ] || die "cat needs a list name"
  sops -d "$dir/$(resolve "$1")"
}

# The reason a plain `grep secrets/router/` finds nothing.
cmd_grep() {
  [ $# -ge 1 ] || die "grep needs a pattern"
  local pattern=$1; shift
  local targets
  if [ $# -ge 1 ]; then targets=$(resolve "$1"); else targets=$(names); fi
  local found=1
  for b in $targets; do
    local hits
    hits=$(sops -d "$dir/$b" | grep -nEi -- "$pattern" || true)
    if [ -n "$hits" ]; then
      found=0
      while IFS= read -r line; do printf '%s:%s\n' "$b" "$line"; done <<< "$hits"
    fi
  done
  return $found
}

cmd_checkout() {
  mkdir -p "$work"
  # Anything that decrypts a secret to disk must not be committable.
  if ! grep -qxF '.lists-work/' "$repo/.gitignore" 2>/dev/null; then
    echo '.lists-work/' >> "$repo/.gitignore"
    echo "lists.sh: added .lists-work/ to .gitignore" >&2
  fi
  local targets
  if [ $# -ge 1 ]; then targets=$(resolve "$1"); else targets=$(names); fi
  for b in $targets; do
    sops -d "$dir/$b" > "$work/$b"
    printf 'checked out %s\n' "$b"
  done
  chmod -R go-rwx "$work"
  echo "lists.sh: plaintext in $work — 'lists.sh commit' when done, 'discard' to drop" >&2
}

cmd_diff() {
  local targets
  if [ $# -ge 1 ]; then targets=$(resolve "$1"); else targets=$(names); fi
  for b in $targets; do
    [ -f "$work/$b" ] || continue
    if ! sops -d "$dir/$b" | diff -u --label "$b (encrypted)" --label "$b (working)" - "$work/$b"; then
      :
    fi
  done
}

cmd_commit() {
  [ -d "$work" ] || die "nothing checked out"
  local targets
  if [ $# -ge 1 ]; then targets=$(resolve "$1"); else targets=$(names); fi
  for b in $targets; do
    [ -f "$work/$b" ] || continue
    if sops -d "$dir/$b" | cmp -s - "$work/$b"; then
      printf 'unchanged   %s\n' "$b"
      continue
    fi
    # Encrypt in place at the destination path: sops matches creation_rules on
    # the path of the file it is encrypting, so `sops -e working > dest` picks
    # the wrong rule (or none) and fails. Copy first, encrypt second.
    cp "$work/$b" "$dir/$b"
    sops --encrypt --in-place "$dir/$b"
    sops -d "$dir/$b" | cmp -s - "$work/$b" || die "$b: round-trip mismatch, not committed cleanly"
    printf 're-encrypted %s\n' "$b"
  done
}

cmd_discard() { rm -rf "$work"; echo "lists.sh: removed $work"; }

cmd_rotate() {
  # After editing .sops.yaml (a new host key, a key removed) every affected
  # file has to be rewritten or the new host cannot decrypt and the old one
  # still can.
  for b in $(names); do
    sops updatekeys --yes "$dir/$b" && printf 'rekeyed %s\n' "$b"
  done
}

case "${1:-}" in
  ls)       shift; cmd_ls "$@" ;;
  edit)     shift; cmd_edit "$@" ;;
  cat)      shift; cmd_cat "$@" ;;
  grep)     shift; cmd_grep "$@" ;;
  checkout) shift; cmd_checkout "$@" ;;
  commit)   shift; cmd_commit "$@" ;;
  diff)     shift; cmd_diff "$@" ;;
  discard)  shift; cmd_discard "$@" ;;
  rotate)   shift; cmd_rotate "$@" ;;
  *) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 1 ;;
esac
