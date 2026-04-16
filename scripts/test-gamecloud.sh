#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://gamecloud.local}"
CURL_RESOLVE="${CURL_RESOLVE:-}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

curl_check() {
  local output_file="$1"
  local url="$2"

  if [[ -n "${CURL_RESOLVE}" ]]; then
    curl -fsS --resolve "${CURL_RESOLVE}" "${url}" > "${output_file}"
  else
    curl -fsS "${url}" > "${output_file}"
  fi
}

assert_contains() {
  local file="$1"
  local expected="$2"

  if ! grep -q "${expected}" "${file}"; then
    echo "Expected '${expected}' in response:"
    cat "${file}"
    exit 1
  fi
}

curl_check "${TMP_DIR}/auth.json" "${BASE_URL}/api/auth/healthz"
curl_check "${TMP_DIR}/pendu.json" "${BASE_URL}/api/pendu/healthz"
curl_check "${TMP_DIR}/quiz.json" "${BASE_URL}/api/quiz/healthz"
curl_check "${TMP_DIR}/p4.json" "${BASE_URL}/api/p4/healthz"
curl_check "${TMP_DIR}/memory.json" "${BASE_URL}/api/memory/healthz"
curl_check "${TMP_DIR}/scores.json" "${BASE_URL}/api/scores/healthz"

assert_contains "${TMP_DIR}/auth.json" "auth-api"
assert_contains "${TMP_DIR}/pendu.json" "pendu-api"
assert_contains "${TMP_DIR}/quiz.json" "quiz-api"
assert_contains "${TMP_DIR}/p4.json" "puissance4-api"
assert_contains "${TMP_DIR}/memory.json" "memory-api"
assert_contains "${TMP_DIR}/scores.json" "score-api"

echo "Base health checks passed."
