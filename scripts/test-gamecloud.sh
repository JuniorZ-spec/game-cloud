#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://gamecloud.local}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -q "${expected}" "${file}"; then
    echo "Expected '${expected}' in response:"
    cat "${file}"
    exit 1
  fi
}

curl -fsS "${BASE_URL}/api/auth/healthz" > "${TMP_DIR}/auth.json"
curl -fsS "${BASE_URL}/api/pendu/healthz" > "${TMP_DIR}/pendu.json"
curl -fsS "${BASE_URL}/api/quiz/healthz" > "${TMP_DIR}/quiz.json"
curl -fsS "${BASE_URL}/api/p4/healthz" > "${TMP_DIR}/p4.json"
curl -fsS "${BASE_URL}/api/memory/healthz" > "${TMP_DIR}/memory.json"
curl -fsS "${BASE_URL}/api/scores/healthz" > "${TMP_DIR}/scores.json"

assert_contains "${TMP_DIR}/auth.json" "auth-api"
assert_contains "${TMP_DIR}/pendu.json" "pendu-api"
assert_contains "${TMP_DIR}/quiz.json" "quiz-api"
assert_contains "${TMP_DIR}/p4.json" "puissance4-api"
assert_contains "${TMP_DIR}/memory.json" "memory-api"
assert_contains "${TMP_DIR}/scores.json" "score-api"

echo "Base health checks passed."
