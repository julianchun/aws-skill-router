#!/usr/bin/env bash
# This runs `claude -p` 9 times (3 environments × 3 runs) and costs a small amount of API usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROUTER_SKILL_DIR="$REPO_ROOT/skills/aws"
ROUTER_SKILL_MD="$ROUTER_SKILL_DIR/SKILL.md"

SKILLS_DIR=""
SKILLS_CSV=""
RUNS=3
KEEP_TMP=0
AUTO_YES=0
INCLUDE_USER_CONFIG=0

usage() {
  cat <<'EOF'
Usage: scripts/measure-tokens.sh [OPTIONS]

Measures prompt tokens per request across three isolated temporary environments:
  A-baseline  No skills installed
  B-official  Official AWS skills installed
  C-router    Only the aws-skill-router skill installed (renamed to aws-router-test)

Options:
  --skills-dir DIR        Copy every subdirectory containing SKILL.md from DIR into B-official
  --skills "a,b,c"        Comma-separated official skill names to install via add-skill
                          (default: unique names from skills/aws/SKILL.md shortcut table)
  --runs N                Number of runs per environment (default: 3)
  --include-user-config   Include user-level settings, skills, and plugins
                          (omits --setting-sources project,local)
  --keep                  Keep the temporary directory after completion
  --yes                   Skip confirmation prompt
  -h, --help              Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skills-dir)
      if [ "$#" -lt 2 ]; then
        echo "Error: --skills-dir requires an argument." >&2
        exit 1
      fi
      SKILLS_DIR="$2"
      shift 2
      ;;
    --skills)
      if [ "$#" -lt 2 ]; then
        echo "Error: --skills requires an argument." >&2
        exit 1
      fi
      SKILLS_CSV="$2"
      shift 2
      ;;
    --runs)
      if [ "$#" -lt 2 ]; then
        echo "Error: --runs requires an argument." >&2
        exit 1
      fi
      RUNS="$2"
      shift 2
      ;;
    --include-user-config)
      INCLUDE_USER_CONFIG=1
      shift
      ;;
    --keep)
      KEEP_TMP=1
      shift
      ;;
    --yes)
      AUTO_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -n "$SKILLS_DIR" ] && [ -n "$SKILLS_CSV" ]; then
  echo "Error: --skills-dir and --skills cannot be used together." >&2
  exit 1
fi

case "$RUNS" in
  ''|*[!0-9]*)
    echo "Error: --runs must be a positive integer." >&2
    exit 1
    ;;
esac
RUNS=$((10#$RUNS))
if [ "$RUNS" -lt 1 ]; then
  echo "Error: --runs must be at least 1." >&2
  exit 1
fi

TOTAL_CALLS=$((RUNS * 3))
echo "This runs \`claude -p\` ${TOTAL_CALLS} times (3 environments × ${RUNS} runs) and costs a small amount of API usage."
if [ "$INCLUDE_USER_CONFIG" -eq 1 ]; then
  echo "Settings mode: including user config (default Claude Code setting sources)"
else
  echo "Settings mode: isolated (--setting-sources project,local)"
fi

if [ "$AUTO_YES" -ne 1 ]; then
  printf 'Continue? [y/N] '
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

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

check_cmd claude
check_cmd jq
check_cmd git

if [ -z "$SKILLS_DIR" ]; then
  check_aws_cli_version
elif [ ! -d "$SKILLS_DIR" ]; then
  echo "Error: --skills-dir does not exist or is not a directory: $SKILLS_DIR" >&2
  exit 1
fi

if [ ! -f "$ROUTER_SKILL_MD" ]; then
  echo "Error: router SKILL.md not found: $ROUTER_SKILL_MD" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
  if [ "$KEEP_TMP" -eq 1 ]; then
    echo "Kept temporary directory: $TMP_ROOT"
  else
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

for env_name in A-baseline B-official C-router; do
  mkdir -p "$TMP_ROOT/$env_name"
  (cd "$TMP_ROOT/$env_name" && git init -q)
done

extract_router_skill_names() {
  local skill_file="$1"
  local out_file="$2"
  local awk_status=0

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
  ' "$skill_file" | LC_ALL=C sort -u > "$out_file" || awk_status=$?

  if [ "$awk_status" -ne 0 ] || [ ! -s "$out_file" ]; then
    echo "Error: failed to extract skill names from $skill_file" >&2
    exit 1
  fi
}

# Populate B-official
mkdir -p "$TMP_ROOT/B-official/.claude/skills"

if [ -n "$SKILLS_DIR" ]; then
  for d in "$SKILLS_DIR"/*; do
    if [ -d "$d" ] && [ -f "$d/SKILL.md" ]; then
      cp -RL "$d" "$TMP_ROOT/B-official/.claude/skills/"
    fi
  done
else
  SKILL_LIST_FILE="$TMP_ROOT/skill_list.txt"
  if [ -n "$SKILLS_CSV" ]; then
    printf '%s\n' "$SKILLS_CSV" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | LC_ALL=C sort -u > "$SKILL_LIST_FILE"
    if [ ! -s "$SKILL_LIST_FILE" ]; then
      echo "Error: --skills produced an empty list." >&2
      exit 1
    fi
  else
    extract_router_skill_names "$ROUTER_SKILL_MD" "$SKILL_LIST_FILE"
  fi

  FAKE_HOME="$TMP_ROOT/home"
  mkdir -p "$FAKE_HOME/.claude"

  while IFS= read -r skill_name; do
    echo "Installing official skill: $skill_name"
    HOME="$FAKE_HOME" aws agent-toolkit add-skill \
      --skill-name "$skill_name" \
      --agent claude-code \
      --region us-east-1 \
      --no-sign-request
  done < "$SKILL_LIST_FILE"

  MISSING_SKILLS_FILE="$TMP_ROOT/missing_skills.txt"
  : > "$MISSING_SKILLS_FILE"
  while IFS= read -r skill_name; do
    if [ ! -f "$FAKE_HOME/.claude/skills/$skill_name/SKILL.md" ]; then
      echo "$skill_name" >> "$MISSING_SKILLS_FILE"
    fi
  done < "$SKILL_LIST_FILE"

  if [ -s "$MISSING_SKILLS_FILE" ]; then
    echo "Error: add-skill did not install SKILL.md for requested skill(s):" >&2
    while IFS= read -r missing_name; do
      echo "  $missing_name" >&2
    done < "$MISSING_SKILLS_FILE"
    exit 1
  fi

  if [ -d "$FAKE_HOME/.claude/skills" ]; then
    for d in "$FAKE_HOME/.claude/skills"/*; do
      if [ -d "$d" ] && [ -f "$d/SKILL.md" ]; then
        cp -RL "$d" "$TMP_ROOT/B-official/.claude/skills/"
      fi
    done
  fi
fi

b_skill_count=0
for d in "$TMP_ROOT/B-official/.claude/skills"/*; do
  if [ -d "$d" ] && [ -f "$d/SKILL.md" ]; then
    b_skill_count=$((b_skill_count + 1))
  fi
done

if [ "$b_skill_count" -eq 0 ]; then
  echo "Error: B-official contains 0 skills." >&2
  exit 1
fi
echo "B-official contains $b_skill_count skill(s)."

# Populate C-router
mkdir -p "$TMP_ROOT/C-router/.claude/skills"
cp -R "$ROUTER_SKILL_DIR" "$TMP_ROOT/C-router/.claude/skills/aws-router-test"
ROUTER_COPY_MD="$TMP_ROOT/C-router/.claude/skills/aws-router-test/SKILL.md"
ROUTER_REWRITTEN="$TMP_ROOT/SKILL.rewritten.md"

awk '
  BEGIN { in_fm = 0; replaced = 0 }
  NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
  in_fm && /^---[[:space:]]*$/ { in_fm = 0; print; next }
  in_fm && !replaced && /^name:[[:space:]]*aws[[:space:]]*$/ {
    print "name: aws-router-test"
    replaced = 1
    next
  }
  { print }
  END { if (!replaced) exit 2 }
' "$ROUTER_COPY_MD" > "$ROUTER_REWRITTEN"
mv "$ROUTER_REWRITTEN" "$ROUTER_COPY_MD"

run_env() {
  local label="$1"
  local dir="$2"
  local out_file="$3"
  local i stdout_file stderr_file rc tokens result_text subtype
  local claude_args=(-p "Reply with exactly: OK" --output-format json --max-turns 1)
  if [ "$INCLUDE_USER_CONFIG" -ne 1 ]; then
    claude_args+=(--setting-sources project,local)
  fi

  : > "$out_file"
  for ((i = 1; i <= RUNS; i++)); do
    stdout_file="$TMP_ROOT/${label}_run_${i}.json"
    stderr_file="$TMP_ROOT/${label}_run_${i}.err"
    echo "Running $label ($i/$RUNS)..."
    rc=0
    (
      cd "$dir"
      claude "${claude_args[@]}"
    ) > "$stdout_file" 2> "$stderr_file" || rc=$?

    if [ "$rc" -ne 0 ]; then
      echo "Error: claude exited with status $rc in $label (run $i)." >&2
      if [ -s "$stderr_file" ]; then
        echo "--- stderr ---" >&2
        cat "$stderr_file" >&2
      fi
      if [ -s "$stdout_file" ]; then
        echo "--- stdout ---" >&2
        cat "$stdout_file" >&2
      fi
      exit 1
    fi

    if ! jq -e 'type == "object"' "$stdout_file" >/dev/null 2>"$TMP_ROOT/jq.err"; then
      echo "Error: failed to parse JSON object from claude output in $label (run $i)." >&2
      cat "$TMP_ROOT/jq.err" >&2
      echo "--- stdout ---" >&2
      cat "$stdout_file" >&2
      exit 1
    fi

    result_text="$(jq -r '(.result // .error // "") | if type == "string" then . else tojson end' "$stdout_file" 2>/dev/null || true)"

    if jq -e '.is_error == true' "$stdout_file" >/dev/null 2>&1; then
      echo "Error: claude returned an error in $label (run $i): ${result_text:-unknown error}" >&2
      echo "--- stdout ---" >&2
      cat "$stdout_file" >&2
      exit 1
    fi

    subtype="$(jq -r '.subtype // ""' "$stdout_file" 2>/dev/null || true)"
    if [ "$subtype" != "success" ]; then
      echo "Error: claude did not return subtype \"success\" (got \"${subtype:-<missing>}\") in $label (run $i)${result_text:+: $result_text}" >&2
      echo "--- stdout ---" >&2
      cat "$stdout_file" >&2
      exit 1
    fi

    if ! tokens="$(jq -er '
      if (.usage | type) != "object" then
        error("missing .usage object")
      else
        ((.usage.input_tokens // 0)
         + (.usage.cache_creation_input_tokens // 0)
         + (.usage.cache_read_input_tokens // 0))
      end
    ' "$stdout_file" 2>"$TMP_ROOT/jq.err")"; then
      echo "Error: failed to parse .usage from claude output in $label (run $i)${result_text:+: $result_text}" >&2
      cat "$TMP_ROOT/jq.err" >&2
      echo "--- stdout ---" >&2
      cat "$stdout_file" >&2
      exit 1
    fi

    case "$tokens" in
      ''|*[!0-9]*)
        echo "Error: unexpected non-numeric token total ($tokens) in $label (run $i)." >&2
        echo "--- stdout ---" >&2
        cat "$stdout_file" >&2
        exit 1
        ;;
    esac

    if [ "$((10#$tokens))" -eq 0 ]; then
      echo "Error: claude returned 0 prompt tokens in $label (run $i)${result_text:+: $result_text}" >&2
      echo "--- stdout ---" >&2
      cat "$stdout_file" >&2
      exit 1
    fi

    echo "$tokens" >> "$out_file"
  done
}

calc_median() {
  local file="$1"
  sort -n "$file" | awk '
    { a[NR] = $1 }
    END {
      if (NR == 0) exit 1
      if (NR % 2 == 1) {
        print a[(NR + 1) / 2]
      } else {
        printf "%.0f\n", int((a[NR / 2] + a[NR / 2 + 1] + 1) / 2)
      }
    }
  '
}

format_runs() {
  local file="$1"
  tr '\n' ',' < "$file" | sed 's/,$//; s/,/, /g'
}

check_variance() {
  local label="$1"
  local file="$2"
  local min_val max_val
  min_val="$(sort -n "$file" | head -n 1)"
  max_val="$(sort -n "$file" | tail -n 1)"
  if [ "$min_val" != "$max_val" ]; then
    echo "WARNING: Run totals differed within $label (min=$min_val, max=$max_val)." >&2
  fi
}

A_FILE="$TMP_ROOT/A-baseline.totals"
B_FILE="$TMP_ROOT/B-official.totals"
C_FILE="$TMP_ROOT/C-router.totals"

run_env "A-baseline" "$TMP_ROOT/A-baseline" "$A_FILE"
run_env "B-official" "$TMP_ROOT/B-official" "$B_FILE"
run_env "C-router" "$TMP_ROOT/C-router" "$C_FILE"

med_a="$(calc_median "$A_FILE")"
med_b="$(calc_median "$B_FILE")"
med_c="$(calc_median "$C_FILE")"

runs_a="$(format_runs "$A_FILE")"
runs_b="$(format_runs "$B_FILE")"
runs_c="$(format_runs "$C_FILE")"

diff_ba=$((med_b - med_a))
diff_ca=$((med_c - med_a))
diff_bc=$((med_b - med_c))

echo ""
printf '%-14s | %-30s | %s\n' "Environment" "Per-run prompt tokens" "Median"
printf '%-14s-+-%-30s-+-%s\n' "--------------" "------------------------------" "----------"
printf '%-14s | %-30s | %s\n' "A-baseline" "$runs_a" "$med_a"
printf '%-14s | %-30s | %s\n' "B-official" "$runs_b" "$med_b"
printf '%-14s | %-30s | %s\n' "C-router" "$runs_c" "$med_c"
echo ""
echo "Official skills overhead (B - A): $diff_ba tokens ($b_skill_count skills)"
echo "Router overhead          (C - A): $diff_ca tokens"
echo "Net saving per request   (B - C): $diff_bc tokens"

check_variance "A-baseline" "$A_FILE"
check_variance "B-official" "$B_FILE"
check_variance "C-router" "$C_FILE"
