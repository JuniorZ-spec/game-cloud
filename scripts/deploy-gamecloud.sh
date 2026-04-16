#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl apply --validate=false -f "${ROOT_DIR}/k8s/namespace.yaml"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/postgres/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/redis/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/auth/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/pendu/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/quiz/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/puissance4/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/memory/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/scores/deployment.yaml"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/frontend/"
kubectl apply --validate=false -f "${ROOT_DIR}/k8s/ingress/ingress.yaml"

echo "Waiting for workloads..."
kubectl rollout status deployment/postgres -n gamecloud --timeout=180s
kubectl rollout status deployment/redis -n gamecloud --timeout=180s
kubectl rollout status deployment/auth-api -n gamecloud --timeout=180s
kubectl rollout status deployment/pendu-api -n gamecloud --timeout=180s
kubectl rollout status deployment/quiz-api -n gamecloud --timeout=180s
kubectl rollout status deployment/puissance4-api -n gamecloud --timeout=180s
kubectl rollout status deployment/memory-api -n gamecloud --timeout=180s
kubectl rollout status deployment/score-api -n gamecloud --timeout=180s
kubectl rollout status deployment/frontend -n gamecloud --timeout=180s

echo "GameCloud deployed."
