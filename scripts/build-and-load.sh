#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gamecloud}"
SERVICES=(frontend auth-api pendu-api quiz-api puissance4-api memory-api score-api)

for service in "${SERVICES[@]}"; do
  echo "==> Building ${service}"
  docker build -t "gamecloud/${service}:v1" "${ROOT_DIR}/services/${service}"

  echo "==> Loading ${service} into Kind"
  kind load docker-image "gamecloud/${service}:v1" --name "${CLUSTER_NAME}"
done

echo "Build and load completed."
