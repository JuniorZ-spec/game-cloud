#!/usr/bin/env bash
set -euo pipefail

kubectl apply --validate=false -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Sur Kind, le port hote est mappe sur le control-plane.
# On force donc le controller sur le noeud ingress-ready pour garantir
# que le point d'entree local reponde bien.
#
# Sur certaines machines, le ClusterIP de l'API Kubernetes (10.96.0.1)
# devient instable depuis le pod ingress-nginx. On force donc aussi
# le controller a joindre l'API via l'IP du noeud hote sur le port 6443.
kubectl patch deployment ingress-nginx-controller \
  -n ingress-nginx \
  --type strategic \
  -p '{
    "spec": {
      "template": {
        "spec": {
          "nodeSelector": {
            "kubernetes.io/os": "linux",
            "ingress-ready": "true"
          },
          "containers": [
            {
              "name": "controller",
              "env": [
                {
                  "name": "KUBERNETES_SERVICE_HOST",
                  "valueFrom": {
                    "fieldRef": {
                      "fieldPath": "status.hostIP"
                    }
                  }
                },
                {
                  "name": "KUBERNETES_SERVICE_PORT",
                  "value": "6443"
                },
                {
                  "name": "KUBERNETES_SERVICE_PORT_HTTPS",
                  "value": "6443"
                }
              ]
            }
          ]
        }
      }
    }
  }'

kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=240s
