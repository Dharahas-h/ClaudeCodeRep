#!/usr/bin/env bash
#
# afk-loop.sh — Autonomous "pick up work" loop.
#
# Repeatedly invokes Claude Code (with full permissions) to grab the next
# available issue, then runs the test suite.
#
# The loop exits when Claude reports "NO AFK ISSUES".
#
# Usage:
#   ./scripts/afk-loop.sh [max_iterations]
#
# Env overrides:
#   MAX_ITERS   hard cap on iterations (default: 100, or $1 if given)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAX_ITERS="${1:-${MAX_ITERS:-100}}"
DONE_SENTINEL="NO AFK ISSUES"
LOG_DIR="$REPO_ROOT/.scratch/.afk-logs"
mkdir -p "$LOG_DIR"

read -r -d '' BASE_PROMPT <<'PROMPT'

Picking up work

Features live under .scratch/<feature-slug>/, each with a PRD.md and an
issues/ directory of dependency-numbered issues. .scratch/README.md lists
features in priority order.

Status strings use the canonical triage labels in
.claude/docs/triage-labels.md (ready-for-agent, ready-for-human,
wontfix). Do not invent new status strings.

Read .scratch/README.md. Consider features top-down; skip any marked
wontfix.

Within the highest-priority remaining feature, pick an issue whose
Status: ready-for-agent AND whose every "Blocked by" issue is complete
(all acceptance-criteria checkboxes ticked). Prefer the lowest-numbered
eligible issue.

If that feature has no eligible issue (all complete, blocked, or already
claimed), move to the next feature in the index.

Never start a blocked issue, a ready-for-human / HITL issue, or an issue in
a wontfix feature.

Before starting, add a ## Comments note claiming the issue so parallel
agents do not collide. An issue is complete when every acceptance-criteria
checkbox is ticked; when a feature's issues are all complete, remove it from
the backlog table in .scratch/README.md.

Append what you did (decisions, deviations, follow-ups) to the ## Comments
section at the bottom of the issue file.

When there is no eligible issue left in any feature, respond with exactly the
following text and nothing else: NO AFK ISSUES

PROMPT

run_tests() {
    local out_file="$1"
    local rc=0

    {
        echo "===== backend: pytest ====="
        if [[ -x "$REPO_ROOT/.venv/bin/pytest" ]]; then
            (
                cd "$REPO_ROOT/backend" &&
                "$REPO_ROOT/.venv/bin/pytest" -q
            )
        else
            (
                cd "$REPO_ROOT/backend" &&
                python -m pytest -q
            )
        fi
    } >>"$out_file" 2>&1 || rc=$?

    {
        echo
        echo "===== frontend: npm test ====="
        (
            cd "$REPO_ROOT/frontend" &&
            npm test --silent
        )
    } >>"$out_file" 2>&1 || rc=$?

    return $rc
}

prompt="$BASE_PROMPT"
iter=0

while (( iter < MAX_ITERS )); do
    iter=$((iter + 1))
    stamp="$(date +%Y%m%d-%H%M%S)"
    claude_log="$LOG_DIR/iter-${iter}-${stamp}.claude.log"
    test_log="$LOG_DIR/iter-${iter}-${stamp}.tests.log"

    echo "==================================================================="
    echo "[afk-loop] Iteration $iter/$MAX_ITERS ($stamp)"
    echo "==================================================================="

    # Invoke Claude with full permissions, streaming to console + log.
    claude \
        -p "$prompt" \
        --dangerously-skip-permissions \
        2>&1 | tee "$claude_log"

    if grep -qF "$DONE_SENTINEL" "$claude_log"; then
        echo "[afk-loop] '$DONE_SENTINEL' received — no more work. Exiting."
        exit 0
    fi

    echo "[afk-loop] Running tests..."

    if run_tests "$test_log"; then
        echo "[afk-loop] Tests passed."
        prompt="$BASE_PROMPT"
    else
        echo "[afk-loop] Tests FAILED — re-prompting Claude to fix them."

        failure_output="$(tail -n 200 "$test_log")"

        prompt=$(cat <<EOF
The test suite is failing after the last change. Fix the failing tests before
picking up any new work. Do NOT report "$DONE_SENTINEL" while tests are red.

Below is the test output (tail):

$failure_output

Once the tests pass, continue with the normal work-pickup process:

$BASE_PROMPT
EOF
)
    fi
done

echo "[afk-loop] Reached MAX_ITERS ($MAX_ITERS) — stopping."
exit 0