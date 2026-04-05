set -uo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PERSIST_ROOT="/persist"

# Get all mount destinations, excluding /persist -> / mount
get_mount_destinations() {
  mount | while read -r line; do
    if [[ "$line" =~ [[:space:]]on[[:space:]]([^[:space:]]+)[[:space:]]type ]]; then
      local dest="${BASH_REMATCH[1]}"
      if [[ "$dest" != "/" ]]; then
        echo "$dest"
      fi
    fi
  done | sort -u
}

# Check if a path in /persist has a corresponding active mount
is_mounted() {
  local persist_path="$1"
  local expected_dest="${persist_path#"$PERSIST_ROOT"}"

  if [[ -z "$expected_dest" ]]; then
    return 1
  fi

  if echo "$MOUNT_DESTINATIONS" | grep -qx "$expected_dest"; then
    return 0
  fi

  return 1
}

# Check if this path or any of its descendants are mounted
has_mounted_descendant() {
  local persist_path="$1"

  if is_mounted "$persist_path"; then
    return 0
  fi

  local expected_prefix="${persist_path#"$PERSIST_ROOT"}"

  while IFS= read -r dest; do
    if [[ "$dest" == "$expected_prefix/"* ]]; then
      return 0
    fi
  done <<<"$MOUNT_DESTINATIONS"

  return 1
}

# Recursively scan directory for orphans
scan_directory() {
  local dir="$1"

  if has_mounted_descendant "$dir"; then
    # Has mounted descendants - recurse but don't report dir as orphan

    # BUT: if this directory ITSELF is mounted (not just descendants),
    # then don't check its contents as they're covered by the mount
    if is_mounted "$dir"; then
      return 0
    fi

    if [[ -d "$dir" ]]; then
      # Check files
      while IFS= read -r -d '' file; do
        if ! is_mounted "$file"; then
          local file_size
          file_size=$(du -sh "$file" 2>/dev/null | cut -f1 || echo "unknown")
          echo -e "${BLUE}ORPHAN FILE:${NC} $file ${YELLOW}[$file_size]${NC}"
          ((ORPHAN_COUNT++))
        fi
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null || true)

      # Recurse into subdirectories
      while IFS= read -r -d '' subdir; do
        scan_directory "$subdir"
      done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    fi
  else
    # No mounted descendants - this is an orphan
    local size
    size=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "unknown")
    echo -e "${RED}ORPHAN DIR: ${NC} $dir ${YELLOW}[$size]${NC}"
    ((ORPHAN_COUNT++))

    # Don't recurse into orphan directories - if parent is orphan,
    # children are implicitly orphans too
  fi
}

# Main
main() {
  if [[ ! -d "$PERSIST_ROOT" ]]; then
    echo -e "${RED}Error: $PERSIST_ROOT does not exist${NC}" >&2
    exit 1
  fi

  echo -e "${GREEN}Scanning for orphaned files and directories in $PERSIST_ROOT...${NC}\n"

  # Get mount destinations as global variable
  MOUNT_DESTINATIONS=$(get_mount_destinations)

  if [[ -z "$MOUNT_DESTINATIONS" ]]; then
    echo -e "${YELLOW}Warning: No mount destinations found${NC}" >&2
  else
    echo -e "${YELLOW}Active mounts (showing /persist source -> destination):${NC}"
    echo "$MOUNT_DESTINATIONS" | while read -r dest; do
      local persist_src="${PERSIST_ROOT}${dest}"
      if [[ -e "$persist_src" ]]; then
        echo "  $persist_src -> $dest"
      fi
    done | sort
    echo ""
  fi

  ORPHAN_COUNT=0

  # Check orphaned files in /persist root
  while IFS= read -r -d '' file; do
    if ! is_mounted "$file"; then
      local file_size
      file_size=$(du -sh "$file" 2>/dev/null | cut -f1 || echo "unknown")
      echo -e "${BLUE}ORPHAN FILE:${NC} $file ${YELLOW}[$file_size]${NC}"
      ((ORPHAN_COUNT++))
    fi
  done < <(find "$PERSIST_ROOT" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null || true)

  # Scan subdirectories
  while IFS= read -r -d '' subdir; do
    scan_directory "$subdir"
  done < <(find "$PERSIST_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  echo ""
  echo -e "${GREEN}Scan complete.${NC}"
  echo -e "Found ${RED}$ORPHAN_COUNT${NC} orphaned files and directories."

  if [[ $ORPHAN_COUNT -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}These files and directories exist in $PERSIST_ROOT but are not mounted anywhere.${NC}"
    echo -e "${YELLOW}They may be leftover from old configurations.${NC}"
  fi
}

main "$@"
