#!/bin/bash
# Script de test pour vérifier le fonctionnement de KEDA
# Usage: ./test-keda.sh

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

echo "=========================================="
echo "Test de KEDA - GameCloud"
echo "=========================================="
echo ""

# Test 1: Vérifier que KEDA est installé
log "Test 1: Vérification de l'installation KEDA..."
if kubectl get pods -n keda &> /dev/null; then
    success "KEDA est installé"
    kubectl get pods -n keda
else
    error "KEDA n'est pas installé"
    exit 1
fi
echo ""

# Test 2: Vérifier le HTTPScaledObject
log "Test 2: Vérification du HTTPScaledObject..."
if kubectl get httpscaledobject -n gamecloud &> /dev/null; then
    success "HTTPScaledObject trouvé"
    kubectl get httpscaledobject -n gamecloud
else
    error "HTTPScaledObject non trouvé"
    echo "Appliquez-le avec : kubectl apply -f k8s/scores/scaled-object.yaml"
    exit 1
fi
echo ""

# Test 3: Vérifier le Deployment score-api
log "Test 3: Vérification du Deployment score-api..."
if kubectl get deployment score-api -n gamecloud &> /dev/null; then
    success "Deployment score-api trouvé"
    kubectl get deployment score-api -n gamecloud
else
    error "Deployment score-api non trouvé"
    exit 1
fi
echo ""

# Test 4: Vérifier l'Ingress
log "Test 4: Vérification de l'Ingress..."
if kubectl get ingress -n gamecloud &> /dev/null; then
    success "Ingress trouvé"
    INGRESS_NAME=$(kubectl get ingress -n gamecloud -o jsonpath='{.items[0].metadata.name}')
    
    # Vérifier si l'interceptor est utilisé
    if kubectl get ingress $INGRESS_NAME -n gamecloud -o yaml | grep -q "keda-add-ons-http-interceptor-proxy"; then
        success "L'Ingress utilise bien l'interceptor KEDA"
    else
        warn "L'Ingress ne semble pas utiliser l'interceptor KEDA"
        echo "Appliquez la configuration avec : kubectl apply -f k8s/ingress/ingress-keda.yaml"
    fi
else
    error "Ingress non trouvé"
    exit 1
fi
echo ""

# Test 5: Test de connectivité
log "Test 5: Test de connectivité vers gamecloud.local..."
if curl -s http://gamecloud.local &> /dev/null; then
    success "Connectivité OK"
else
    warn "Impossible de se connecter à http://gamecloud.local"
    echo "Vérifiez que :"
    echo "  1. L'Ingress est correctement configuré"
    echo "  2. L'entrée DNS gamecloud.local pointe vers le cluster"
fi
echo ""

# Test 6: Mesurer le cold start
log "Test 6: Test du cold start..."
echo "Envoi d'une requête vers /api/scores/leaderboard..."
echo ""

START_TIME=$(date +%s%N)
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" http://gamecloud.local/api/scores/leaderboard 2>/dev/null || echo "HTTP_CODE:000")
END_TIME=$(date +%s%N)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))

if [ "$HTTP_CODE" = "200" ]; then
    success "Requête réussie en ${ELAPSED_MS}ms"
    
    if [ $ELAPSED_MS -gt 1000 ]; then
        echo "  → Cold start détecté (> 1s)"
    else
        echo "  → Pod déjà chaud"
    fi
else
    error "Requête échouée (HTTP $HTTP_CODE)"
    echo "Vérifiez les logs du pod :"
    echo "  kubectl logs -n gamecloud -l app=score-api"
fi
echo ""

# Test 7: Vérifier le nombre de replicas
log "Test 7: Vérification du nombre de replicas..."
REPLICAS=$(kubectl get deployment score-api -n gamecloud -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
success "Nombre de replicas actuel : $REPLICAS"

if [ "$REPLICAS" = "0" ]; then
    echo "  → Service en mode scale-to-zero"
elif [ "$REPLICAS" = "1" ]; then
    echo "  → Service actif avec 1 replica"
else
    echo "  → Service scale-up avec $REPLICAS replicas"
fi
echo ""

echo "=========================================="
echo "Tests terminés"
echo "=========================================="
