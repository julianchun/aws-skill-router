#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-skill-names.sh"
SKILL_FILE="$REPO_ROOT/skills/aws/SKILL.md"
SNAPSHOT_FILE="$REPO_ROOT/catalog/skill-names.txt"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

usage() {
  cat <<'EOF'
Usage: scripts/sync-catalog.sh

Compares the router table and catalog/skill-names.txt snapshot against the
official Agent Toolkit for AWS catalog, updates the working tree, and writes
a Markdown PR body.

Environment variables:
  CATALOG_JSON   Optional path to a catalog JSON file (same shape as
                 `aws agent-toolkit list-available-skills --output json`)
                 for offline testing.
  PR_BODY_FILE   Optional path to write the Markdown PR body
                 (defaults to sync-pr-body.md in a temporary directory).
  GITHUB_OUTPUT  Optional GitHub Actions output file; appends
                 changed, skill_changed, and version.
  SYNC_ALLOW_LARGE_CHANGE
                 Set to 1 to bypass the partial-catalog safety guard (aborts if
                 the catalog drops below 50% of the snapshot count or removes
                 more than 5 table names in one run).
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not found." >&2
  exit 1
fi

for req_file in "$CHECK_SCRIPT" "$SKILL_FILE" "$PLUGIN_JSON"; do
  if [ ! -f "$req_file" ]; then
    echo "Error: required file not found: $req_file" >&2
    exit 1
  fi
done

current_version="$(jq -r '.version // empty' "$PLUGIN_JSON")"
if ! printf '%s\n' "$current_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: invalid or missing version in $PLUGIN_JSON: '$current_version'" >&2
  exit 1
fi

check_aws_cli_version() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI not found. Install AWS CLI >= 2.35.0." >&2
    exit 1
  fi

  local ver_output ver major minor
  ver_output="$(aws --version 2>&1 || true)"
  ver="$(printf '%s\n' "$ver_output" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^aws-cli\//) {
          sub(/^aws-cli\//, "", $i)
          print $i
          exit
        }
      }
    }
  ')"

  if [ -z "$ver" ]; then
    echo "Error: could not parse AWS CLI version from: $ver_output" >&2
    exit 1
  fi

  IFS='.' read -r major minor _ <<< "$ver"

  case "$major" in
    ''|*[!0-9]*)
      echo "Error: unexpected AWS CLI version format: $ver" >&2
      exit 1
      ;;
  esac
  case "$minor" in
    ''|*[!0-9]*)
      echo "Error: unexpected AWS CLI version format: $ver" >&2
      exit 1
      ;;
  esac

  major=$((10#$major))
  minor=$((10#$minor))

  if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
    echo "Error: AWS CLI >= 2.35.0 is required (found aws-cli/$ver)." >&2
    exit 1
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CATALOG_JSON_FILE="$TMP_DIR/catalog.json"
CATALOG_NAMES_SORTED="$TMP_DIR/catalog_names.txt"
TABLE_NAMES_SORTED="$TMP_DIR/table_names.txt"
PREV_SNAPSHOT_SORTED="$TMP_DIR/prev_snapshot.txt"
REMOVED_FROM_TABLE="$TMP_DIR/removed_from_table.txt"
ADDED_FILE="$TMP_DIR/added.txt"
DROPPED_FILE="$TMP_DIR/dropped.txt"
TMP_SKILL_FILE="$TMP_DIR/SKILL.md"
TMP_PLUGIN_JSON="$TMP_DIR/plugin.json"

if [ -n "${CATALOG_JSON:-}" ]; then
  if [ ! -f "$CATALOG_JSON" ]; then
    echo "Error: CATALOG_JSON not found: $CATALOG_JSON" >&2
    exit 1
  fi
  cp "$CATALOG_JSON" "$CATALOG_JSON_FILE"
else
  check_aws_cli_version
  aws agent-toolkit list-available-skills --region us-east-1 --no-sign-request --output json > "$CATALOG_JSON_FILE"
fi

if ! jq -e 'type == "object" and (.skills | type == "array")' "$CATALOG_JSON_FILE" >/dev/null 2>&1; then
  echo "Error: catalog JSON must be an object with a 'skills' array." >&2
  exit 1
fi

jq -r '.skills[] | select(type == "object" and (.name | type == "string") and (.name | length > 0)) | .name' \
  "$CATALOG_JSON_FILE" | LC_ALL=C sort -u > "$CATALOG_NAMES_SORTED"

catalog_count="$(wc -l < "$CATALOG_NAMES_SORTED" | tr -d '[:space:]')"
if [ "$catalog_count" -eq 0 ]; then
  echo "Error: catalog contains zero skills; refusing to sync." >&2
  exit 1
fi

"$CHECK_SCRIPT" --print-names "$SKILL_FILE" > "$TABLE_NAMES_SORTED"
LC_ALL=C comm -23 "$TABLE_NAMES_SORTED" "$CATALOG_NAMES_SORTED" > "$REMOVED_FROM_TABLE"

initialised=false
snapshot_changed=false
: > "$ADDED_FILE"
: > "$DROPPED_FILE"

prev_snapshot_count=0
if [ ! -f "$SNAPSHOT_FILE" ]; then
  initialised=true
  snapshot_changed=true
else
  sed '/^$/d' "$SNAPSHOT_FILE" | LC_ALL=C sort -u > "$PREV_SNAPSHOT_SORTED"
  prev_snapshot_count="$(wc -l < "$PREV_SNAPSHOT_SORTED" | tr -d '[:space:]')"
  LC_ALL=C comm -23 "$CATALOG_NAMES_SORTED" "$PREV_SNAPSHOT_SORTED" > "$ADDED_FILE"
  LC_ALL=C comm -13 "$CATALOG_NAMES_SORTED" "$PREV_SNAPSHOT_SORTED" > "$DROPPED_FILE"
  if ! cmp -s "$SNAPSHOT_FILE" "$CATALOG_NAMES_SORTED"; then
    snapshot_changed=true
  fi
fi

removed_count="$(wc -l < "$REMOVED_FROM_TABLE" | tr -d '[:space:]')"

if [ "${SYNC_ALLOW_LARGE_CHANGE:-0}" != "1" ]; then
  if [ "$initialised" = false ] && [ "$prev_snapshot_count" -gt 0 ] && [ $((catalog_count * 2)) -lt "$prev_snapshot_count" ]; then
    echo "Error: catalog count (${catalog_count}) is below 50% of snapshot count (${prev_snapshot_count}); refusing to sync. Set SYNC_ALLOW_LARGE_CHANGE=1 to override." >&2
    exit 1
  fi
  if [ "$removed_count" -gt 5 ]; then
    echo "Error: sync would remove ${removed_count} skill names from the router table (max allowed: 5); refusing to sync. Set SYNC_ALLOW_LARGE_CHANGE=1 to override." >&2
    exit 1
  fi
fi

skill_changed=false
final_version="$current_version"

if [ -s "$REMOVED_FROM_TABLE" ]; then
  awk_status=0
  awk -v removed_file="$REMOVED_FROM_TABLE" '
    BEGIN {
      in_section = 0
      seen_sep = 0
      remaining_rows = 0
    }
    FILENAME == removed_file {
      if ($0 != "") removed[$0] = 1
      next
    }
    /^## Frequently used skill names[[:space:]]*$/ {
      in_section = 1
      print
      next
    }
    in_section && /^## / {
      in_section = 0
      print
      next
    }
    in_section && /^\|/ {
      if ($0 ~ /^\|([[:space:]]*:?-+:?[[:space:]]*\|)+[[:space:]]*$/) {
        seen_sep = 1
        print
        next
      }
      if (!seen_sep) {
        print
        next
      }
      n = split($0, cells, "|")
      col_idx = 0
      for (i = n; i >= 1; i--) {
        if (cells[i] ~ /[^[:space:]]/) {
          col_idx = i
          break
        }
      }
      if (col_idx == 0) {
        print
        next
      }
      cell = cells[col_idx]
      m = split(cell, parts, ",")
      kept_count = 0
      row_modified = 0
      rebuilt = ""
      for (j = 1; j <= m; j++) {
        item = parts[j]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
        if (item == "") continue
        tok = ""
        if (item ~ /^`[a-z0-9]+(-[a-z0-9]+)*`$/) {
          tok = substr(item, 2, length(item) - 2)
        }
        if (tok != "" && (tok in removed)) {
          row_modified = 1
          continue
        }
        if (kept_count > 0) {
          rebuilt = rebuilt ", " item
        } else {
          rebuilt = item
        }
        kept_count++
      }
      if (!row_modified) {
        remaining_rows++
        print
        next
      }
      if (kept_count == 0) {
        next
      }
      cells[col_idx] = " " rebuilt " "
      line = cells[1]
      for (i = 2; i <= n; i++) {
        line = line "|" cells[i]
      }
      remaining_rows++
      print line
      next
    }
    {
      print
    }
    END {
      if (remaining_rows == 0) {
        exit 3
      }
    }
  ' "$REMOVED_FROM_TABLE" "$SKILL_FILE" > "$TMP_SKILL_FILE" || awk_status=$?

  if [ "$awk_status" -eq 3 ]; then
    echo "Error: removing missing skills would leave the router table empty in $SKILL_FILE" >&2
    exit 1
  elif [ "$awk_status" -ne 0 ]; then
    echo "Error: failed to update $SKILL_FILE" >&2
    exit 1
  fi

  if cmp -s "$SKILL_FILE" "$TMP_SKILL_FILE"; then
    echo "Error: expected $SKILL_FILE to change after removing missing table skills." >&2
    exit 1
  fi

  skill_changed=true
  IFS='.' read -r v_major v_minor v_patch <<< "$current_version"
  final_version="${v_major}.${v_minor}.$((10#$v_patch + 1))"

  jq --indent 2 --arg v "$final_version" '.version = $v' "$PLUGIN_JSON" > "$TMP_PLUGIN_JSON"

  if ! awk '
    FILENAME == ARGV[1] { orig[++n1] = $0; next }
    { updated[++n2] = $0 }
    END {
      if (n1 != n2) exit 1
      diffs = 0
      for (i = 1; i <= n1; i++) {
        if (orig[i] != updated[i]) {
          diffs++
          if (orig[i] !~ /^[[:space:]]*"version":[[:space:]]*"/ || updated[i] !~ /^[[:space:]]*"version":[[:space:]]*"/) {
            exit 1
          }
        }
      }
      if (diffs != 1) exit 1
    }
  ' "$PLUGIN_JSON" "$TMP_PLUGIN_JSON"; then
    echo "Error: updating $PLUGIN_JSON changed more than the version line." >&2
    exit 1
  fi
fi

# Apply changes in the working tree
if [ "$snapshot_changed" = true ]; then
  mkdir -p "$(dirname "$SNAPSHOT_FILE")"
  cp "$CATALOG_NAMES_SORTED" "$SNAPSHOT_FILE"
fi

if [ "$skill_changed" = true ]; then
  cp "$TMP_SKILL_FILE" "$SKILL_FILE"
  cp "$TMP_PLUGIN_JSON" "$PLUGIN_JSON"
  CATALOG_FILE="$CATALOG_NAMES_SORTED" "$CHECK_SCRIPT" "$SKILL_FILE"
fi

changed=false
if [ "$snapshot_changed" = true ] || [ "$skill_changed" = true ]; then
  changed=true
fi

# Write Markdown PR body
if [ -z "${PR_BODY_FILE:-}" ]; then
  pr_body_dir="$(mktemp -d)"
  PR_BODY_FILE="$pr_body_dir/sync-pr-body.md"
else
  mkdir -p "$(dirname "$PR_BODY_FILE")"
fi

{
  if [ "$initialised" = true ]; then
    printf 'Catalog snapshot `catalog/skill-names.txt` was initialised (%s skills).\n\n' "$catalog_count"
  fi

  printf '## Removed from router table (no longer in catalog)\n\n'
  if [ -s "$REMOVED_FROM_TABLE" ]; then
    while IFS= read -r name; do
      printf -- '- `%s`\n' "$name"
    done < "$REMOVED_FROM_TABLE"
  else
    printf 'None.\n'
  fi

  printf '\n## New skills in catalog (consider adding to the table)\n\n'
  if [ "$initialised" = true ]; then
    printf 'None (catalog snapshot initialised).\n'
  elif [ -s "$ADDED_FILE" ]; then
    while IFS= read -r name; do
      desc="$(jq -r --arg name "$name" '
        ([.skills[] | select(.name == $name) | .description] | first) // ""
      ' "$CATALOG_JSON_FILE" | tr '\r\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//')"
      if [ -n "$desc" ]; then
        printf -- '- `%s` — %s\n' "$name" "$desc"
      else
        printf -- '- `%s`\n' "$name"
      fi
    done < "$ADDED_FILE"
  else
    printf 'None.\n'
  fi

  printf '\n## Dropped from catalog\n\n'
  if [ "$initialised" = true ]; then
    printf 'None (catalog snapshot initialised).\n'
  elif [ -s "$DROPPED_FILE" ]; then
    while IFS= read -r name; do
      printf -- '- `%s`\n' "$name"
    done < "$DROPPED_FILE"
  else
    printf 'None.\n'
  fi

  printf '\n## Version bump\n\n'
  if [ "$skill_changed" = true ]; then
    printf 'Bumped `.claude-plugin/plugin.json` version from `%s` to `%s`.\n' "$current_version" "$final_version"
  else
    printf 'None (current version: `%s`).\n' "$final_version"
  fi

  printf '\n---\n\n'
  printf 'Please review all changes before merging. New catalog skills are not added to `skills/aws/SKILL.md` automatically.\n'
} > "$PR_BODY_FILE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'changed=%s\n' "$changed"
    printf 'skill_changed=%s\n' "$skill_changed"
    printf 'version=%s\n' "$final_version"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$initialised" = true ]; then
  echo "Catalog snapshot initialised ($catalog_count skills)."
else
  added_count="$(wc -l < "$ADDED_FILE" | tr -d '[:space:]')"
  dropped_count="$(wc -l < "$DROPPED_FILE" | tr -d '[:space:]')"
  removed_count="$(wc -l < "$REMOVED_FROM_TABLE" | tr -d '[:space:]')"
  echo "Catalog sync complete: changed=$changed skill_changed=$skill_changed version=$final_version (catalog=$catalog_count, added=$added_count, dropped=$dropped_count, removed_from_table=$removed_count)"
fi
echo "PR body written to: $PR_BODY_FILE"
