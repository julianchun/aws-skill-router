#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SKILL_FILE="$REPO_ROOT/skills/aws/SKILL.md"

usage() {
  cat <<'EOF'
Usage: scripts/check-skill-names.sh [--print-names] [path/to/SKILL.md]

Verifies that every skill name listed in the "## Frequently used skill names"
table exists in the official Agent Toolkit for AWS catalog.

Options:
  --print-names  Print unique skill names from the table (sorted, one per line)
                 and exit 0 without contacting AWS.

Environment variables:
  CATALOG_FILE  Optional path to a whitespace/newline-separated list of catalog
                skill names (for offline testing).
EOF
}

PRINT_NAMES=false
SKILL_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --print-names)
      PRINT_NAMES=true
      shift
      ;;
    --)
      shift
      if [ "$#" -gt 0 ]; then
        if [ -n "$SKILL_FILE" ] || [ "$#" -gt 1 ]; then
          usage >&2
          exit 1
        fi
        SKILL_FILE="$1"
        shift
      fi
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$SKILL_FILE" ]; then
        usage >&2
        exit 1
      fi
      SKILL_FILE="$1"
      shift
      ;;
  esac
done

if [ -z "$SKILL_FILE" ]; then
  SKILL_FILE="$DEFAULT_SKILL_FILE"
fi

if [ ! -f "$SKILL_FILE" ]; then
  echo "Error: SKILL.md not found: $SKILL_FILE" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SKILLS_RAW="$TMP_DIR/skills_raw.txt"
SKILLS_SORTED="$TMP_DIR/skills_sorted.txt"
CATALOG_SORTED="$TMP_DIR/catalog_sorted.txt"
MISSING_FILE="$TMP_DIR/missing.txt"

# Extract backtick-quoted skill names from the last non-empty column of the
# "## Frequently used skill names" table.
awk_status=0
awk '
  BEGIN {
    in_section = 0
    found_section = 0
    seen_sep = 0
  }
  /^## Frequently used skill names[[:space:]]*$/ {
    in_section = 1
    found_section = 1
    next
  }
  in_section && /^## / {
    in_section = 0
    next
  }
  in_section && /^\|/ {
    if ($0 ~ /^\|([[:space:]]*:?-+:?[[:space:]]*\|)+[[:space:]]*$/) {
      seen_sep = 1
      next
    }
    if (!seen_sep) {
      # Skip table header row before the separator.
      next
    }
    n = split($0, cells, "|")
    cell = ""
    for (i = n; i >= 1; i--) {
      if (cells[i] ~ /[^[:space:]]/) {
        cell = cells[i]
        break
      }
    }
    while (match(cell, /`[^`]+`/)) {
      tok = substr(cell, RSTART + 1, RLENGTH - 2)
      if (tok ~ /^[a-z0-9]+(-[a-z0-9]+)*$/) {
        print tok
      }
      cell = substr(cell, RSTART + RLENGTH)
    }
  }
  END {
    if (!found_section || !seen_sep) {
      exit 2
    }
  }
' "$SKILL_FILE" > "$SKILLS_RAW" || awk_status=$?

if [ "$awk_status" -eq 2 ]; then
  echo "Error: \"## Frequently used skill names\" table not found in $SKILL_FILE" >&2
  exit 1
elif [ "$awk_status" -ne 0 ]; then
  echo "Error: failed to parse $SKILL_FILE" >&2
  exit 1
fi

LC_ALL=C sort -u "$SKILLS_RAW" > "$SKILLS_SORTED"
skill_count="$(wc -l < "$SKILLS_SORTED" | tr -d '[:space:]')"

if [ "$skill_count" -eq 0 ]; then
  echo "Error: zero skill names found in \"## Frequently used skill names\" table in $SKILL_FILE" >&2
  exit 1
fi

if [ "$PRINT_NAMES" = true ]; then
  cat "$SKILLS_SORTED"
  exit 0
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

if [ -n "${CATALOG_FILE:-}" ]; then
  if [ ! -f "$CATALOG_FILE" ]; then
    echo "Error: CATALOG_FILE not found: $CATALOG_FILE" >&2
    exit 1
  fi
  tr -s '[:space:]' '\n' < "$CATALOG_FILE" | sed '/^$/d' | LC_ALL=C sort -u > "$CATALOG_SORTED"
else
  check_aws_cli_version
  catalog_raw="$(aws agent-toolkit list-available-skills --region us-east-1 --no-sign-request --query "skills[].name" --output text)"
  printf '%s\n' "$catalog_raw" | tr -s '[:space:]' '\n' | sed '/^$/d' | LC_ALL=C sort -u > "$CATALOG_SORTED"
fi

catalog_count="$(wc -l < "$CATALOG_SORTED" | tr -d '[:space:]')"
if [ "$catalog_count" -eq 0 ]; then
  echo "Error: catalog skill list is empty." >&2
  exit 1
fi

LC_ALL=C comm -23 "$SKILLS_SORTED" "$CATALOG_SORTED" > "$MISSING_FILE"

if [ -s "$MISSING_FILE" ]; then
  echo "Missing skill names (not found in catalog):" >&2
  while IFS= read -r missing_name; do
    echo "  $missing_name" >&2
  done < "$MISSING_FILE"
  exit 1
fi

echo "OK: $skill_count skill names found in catalog ($catalog_count available)"
