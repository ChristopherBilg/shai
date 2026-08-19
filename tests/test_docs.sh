#!/bin/bash
# test_docs.sh — checks the documentation checker end to end
# Covers: tests/docs.sh — classification, per-type checks, anti-gaming, exemptions, fail-closed
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "docs"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/tests"

# --- fixtures --------------------------------------------------------------
cat >"$FIX/good-run" <<'EOF'
#!/bin/bash
# good-run — does a thing for the pipeline
# Usage: cat x | good-run
# Reads: stdin JSON
# Writes: stdout JSON
# Exit: 0 ok; 1 error
set -euo pipefail
EOF

cat >"$FIX/bad-run" <<'EOF'
#!/bin/bash
# bad-run — a runtime script missing its exit docs
# Usage: cat x | bad-run
# Reads: stdin
# Writes: stdout
set -euo pipefail
EOF

cat >"$FIX/lazy-run" <<'EOF'
#!/bin/bash
# lazy-run
# Usage: lazy-run
# Reads: x
# Writes: y
# Exit: 0
set -euo pipefail
EOF

cat >"$FIX/misnamed-run" <<'EOF'
#!/bin/bash
# misnamed-run — usage does not name the script itself
# Usage: run the thing somehow
# Reads: stdin
# Writes: stdout
# Exit: 0 ok
set -euo pipefail
EOF

cat >"$FIX/tests/test_good.sh" <<'EOF'
#!/bin/bash
# test_good.sh — checks the good widget
# Covers: good-run — basic behavior
set -uo pipefail
EOF

cat >"$FIX/tests/helper.sh" <<'EOF'
#!/bin/bash
# helper.sh — shared helper sourced by the suite
# Usage: source tests/helper.sh
set -uo pipefail
EOF

printf '# conf.yml — example workflow config for tests\nname: x\n' >"$FIX/conf.yml"
printf 'name: x\n' >"$FIX/bad.yml"
printf '# .editorconfig — shared formatting rules\nroot = true\n' >"$FIX/.editorconfig"
printf '# Title Here\n\nbody\n' >"$FIX/doc.md"
printf '## Subheading only\n\nx\n' >"$FIX/bad.md"
printf '[{"name":"t","description":"a tool","input_schema":{"properties":{"p":{"description":"a param"}}}}]\n' >"$FIX/tools.json"
printf '[{"name":"t","description":"","input_schema":{"properties":{}}}]\n' >"$FIX/bad.json"
printf '{"_comment":"copy me to $SHAI_HOME/thing.json and edit","repos":{}}\n' >"$FIX/good.json.example"
printf '{"repos":{}}\n' >"$FIX/bad.json.example"
printf '{"_comment":"short","repos":{}}\n' >"$FIX/terse.json.example"
printf 'not json at all\n' >"$FIX/broken.json.example"
printf 'just some notes\n' >"$FIX/notes.txt"
printf 'deadbeef  shellcheck\n' >"$FIX/tests/lint-tools.sha256"

cat >"$FIX/tests/test_bad.sh" <<'EOF'
#!/bin/bash
# test_bad.sh — a test file missing its Covers line
set -uo pipefail
EOF

cat >"$FIX/tests/badinfra.sh" <<'EOF'
#!/bin/bash
# badinfra.sh — an infra script missing its Usage line
set -uo pipefail
EOF

cat >"$FIX/documentation-thing" <<'EOF'
#!/bin/bash
# documentation-thing
# Usage: documentation-thing
# Reads: stdin
# Writes: stdout
# Exit: 0 ok
set -euo pipefail
EOF

printf '# conf.yaml — example .yaml variant for tests\nname: y\n' >"$FIX/conf.yaml"

mkdir -p "$FIX/prompts"
printf 'You are a helpful assistant.\n' >"$FIX/prompts/good.txt"
printf '' >"$FIX/prompts/empty.txt"

# run_docs <files...> : sets OUT and RC, running the checker inside $FIX
run_docs() {
  OUT="$(cd "$FIX" && "$DIR/tests/docs.sh" "$@" 2>&1)"
  RC=$?
}

# --- assertions ------------------------------------------------------------
run_docs good-run
assert_eq "$RC" "0" "runtime: compliant passes"
assert_contains "$OUT" "documented: good-run" "runtime: prints documented"

run_docs bad-run
assert_eq "$RC" "1" "runtime: missing Exit fails"
assert_contains "$OUT" "'# Exit:' missing" "runtime: names the missing field"

run_docs lazy-run
assert_eq "$RC" "1" "runtime: filename-only purpose fails"
assert_contains "$OUT" "purpose line" "runtime: names the purpose problem"

run_docs misnamed-run
assert_eq "$RC" "1" "runtime: Usage not naming the script fails"
assert_contains "$OUT" "does not name" "runtime: Usage-not-naming failure is the reported reason"

run_docs tests/test_good.sh
assert_eq "$RC" "0" "test: compliant passes"

run_docs tests/helper.sh
assert_eq "$RC" "0" "infra: compliant passes"

run_docs conf.yml
assert_eq "$RC" "0" "yaml: leading comment passes"
run_docs bad.yml
assert_eq "$RC" "1" "yaml: no leading comment fails"

run_docs .editorconfig
assert_eq "$RC" "0" "dotfile: leading comment passes"

run_docs doc.md
assert_eq "$RC" "0" "md: H1 passes"
run_docs bad.md
assert_eq "$RC" "1" "md: H2-only fails"

run_docs tools.json
assert_eq "$RC" "0" "json: all descriptions present passes"
run_docs bad.json
assert_eq "$RC" "1" "json: empty description fails"

run_docs good.json.example
assert_eq "$RC" "0" "json example: _comment present passes"
assert_contains "$OUT" "json example:" "json example: prints its own classification"
run_docs bad.json.example
assert_eq "$RC" "1" "json example: missing _comment fails"
assert_contains "$OUT" "_comment" "json example: names the missing key"
run_docs terse.json.example
assert_eq "$RC" "1" "json example: trivial _comment fails"
run_docs broken.json.example
assert_eq "$RC" "1" "json example: invalid JSON fails"

run_docs notes.txt
assert_eq "$RC" "1" "unknown type fails"
assert_contains "$OUT" "UNKNOWN" "unknown: names the problem"

run_docs tests/lint-tools.sha256
assert_eq "$RC" "0" "exempt file skipped"
assert_contains "$OUT" "exempt:" "exempt: prints exempt"

run_docs good-run bad-run
assert_eq "$RC" "1" "aggregate: one bad among many fails"
assert_contains "$OUT" "documented: good-run" "aggregate: still reports the good one"

run_docs tests/test_bad.sh
assert_eq "$RC" "1" "test: missing Covers fails"
assert_contains "$OUT" "Covers" "test: names the missing Covers field"

run_docs tests/badinfra.sh
assert_eq "$RC" "1" "infra: missing Usage fails"

run_docs documentation-thing
assert_eq "$RC" "1" "runtime: purpose equal to basename fails"
assert_contains "$OUT" "purpose line" "runtime: purpose-equals-basename failure is the reported reason"

run_docs conf.yaml
assert_eq "$RC" "0" ".yaml variant passes"

run_docs good-run
assert_contains "$OUT" "DOCS OK" "banner: DOCS OK printed on all-pass"

# Regression guard for the check_shell early-abort bug: the FAILING shell file
# is listed FIRST, so a passing file after it proves aggregation continues and
# the banner still prints.
run_docs bad-run good-run
assert_eq "$RC" "1" "aggregate: bad-first still fails"
assert_contains "$OUT" "documented: good-run" "aggregate: examines files after a failing shell script"
assert_contains "$OUT" "DOCS FAILED" "aggregate: prints the DOCS FAILED banner"

run_docs prompts/good.txt
assert_eq "$RC" "0" "prompt: non-empty passes"
assert_contains "$OUT" "prompt ok:" "prompt: prints prompt ok"

run_docs prompts/empty.txt
assert_eq "$RC" "1" "prompt: empty fails"
assert_contains "$OUT" "empty prompt" "prompt: names the empty problem"

# --- workflow script: runtime rules apply ---
mkdir -p "$FIX/workflows/good-wf"
cat >"$FIX/workflows/good-wf/run.sh" <<'EOF'
#!/bin/bash
# run.sh — a compliant workflow script
# Usage: run.sh <TICKET_ID>
# Reads: ANTHROPIC_API_KEY from environment
# Writes: draft PR on GitHub
# Exit: 0 on success; 1 on failure
set -euo pipefail
EOF

mkdir -p "$FIX/workflows/bad-wf"
cat >"$FIX/workflows/bad-wf/run.sh" <<'EOF'
#!/bin/bash
# run.sh — a workflow missing Exit
# Usage: run.sh <TICKET_ID>
# Reads: env
# Writes: stdout
set -euo pipefail
EOF

run_docs workflows/good-wf/run.sh
assert_eq "$RC" "0" "workflow: compliant passes"

run_docs workflows/bad-wf/run.sh
assert_eq "$RC" "1" "workflow: missing Exit fails"

# --- library file: infra rules apply ---
mkdir -p "$FIX/lib"
cat >"$FIX/lib/good-lib.sh" <<'EOF'
#!/bin/bash
# good-lib.sh — shared helpers for workflow scripts
# Usage: source lib/good-lib.sh
set -uo pipefail
EOF

cat >"$FIX/lib/bad-lib.sh" <<'EOF'
#!/bin/bash
# bad-lib.sh
set -uo pipefail
EOF

run_docs lib/good-lib.sh
assert_eq "$RC" "0" "library: compliant passes"

run_docs lib/bad-lib.sh
assert_eq "$RC" "1" "library: filename-only purpose fails"

# --- workflow policy: valid .rules array ---
mkdir -p "$FIX/workflows/good-policy"
printf '{"rules":[{"tool":"gh","action":"allow"}]}\n' >"$FIX/workflows/good-policy/policy.json"
mkdir -p "$FIX/workflows/bad-policy"
printf '{"not_rules":true}\n' >"$FIX/workflows/bad-policy/policy.json"

run_docs workflows/good-policy/policy.json
assert_eq "$RC" "0" "policy: valid .rules array passes"

run_docs workflows/bad-policy/policy.json
assert_eq "$RC" "1" "policy: missing .rules array fails"

finish
