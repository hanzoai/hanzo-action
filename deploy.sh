#!/usr/bin/env bash
set -euo pipefail

# Hanzo Deploy Action
# Deploys a container image or triggers a build on the Hanzo PaaS platform.

API="${PLATFORM_API_URL:-https://platform.hanzo.ai}"
IAM_TOKEN="${HANZO_TOKEN}"
ORG="${INPUT_ORG}"
PROJECT="${INPUT_PROJECT}"
ENV="${INPUT_ENV}"
IMAGE="${INPUT_IMAGE:-}"
CONTAINER="${INPUT_CONTAINER:-${GITHUB_REPOSITORY##*/}}"
TRIGGER="${INPUT_TRIGGER:-false}"
REPLICAS="${INPUT_REPLICAS:-1}"
PORT="${INPUT_PORT:-8080}"
WAIT="${INPUT_WAIT:-true}"
TIMEOUT="${INPUT_TIMEOUT:-300}"

BASE_URL="${API}/v1/org/${ORG}/project/${PROJECT}/env/${ENV}/container"
SESSION_TOKEN=""
AUTH_HEADER=""

log() { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }
fail() { echo "::error::$1"; exit 1; }

# -------------------------------------------------------------------------
# Exchange IAM token for PaaS session
# -------------------------------------------------------------------------
login() {
    log "Authenticating with PaaS"

    local resp
    resp=$(curl -sS -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"provider\":\"hanzo\",\"accessToken\":\"${IAM_TOKEN}\"}" \
        "${API}/v1/auth/login") || true

    local http_code body
    http_code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$http_code" -ge 400 ]]; then
        fail "PaaS login failed (HTTP ${http_code}): ${body}"
    fi

    SESSION_TOKEN=$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('at', ''))
" 2>/dev/null) || true

    if [[ -z "$SESSION_TOKEN" ]]; then
        fail "PaaS login returned no session token"
    fi

    echo "::add-mask::${SESSION_TOKEN}"
    AUTH_HEADER="Authorization: Bearer ${SESSION_TOKEN}"
    echo "Authenticated successfully"
    endlog
}

# -------------------------------------------------------------------------
# Find existing container by name
# -------------------------------------------------------------------------
find_container() {
    local resp
    resp=$(curl -sS -w "\n%{http_code}" \
        -H "${AUTH_HEADER}" \
        "${BASE_URL}" 2>&1) || true

    local http_code body
    http_code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$http_code" -ge 400 ]]; then
        return 1
    fi

    # Try to find container by name in the response
    local cid
    cid=$(echo "$body" | python3 -c "
import sys, json
data = json.load(sys.stdin)
containers = data if isinstance(data, list) else data.get('containers', data.get('data', []))
for c in containers:
    if c.get('name') == '${CONTAINER}':
        print(c.get('_id', c.get('iid', c.get('id', ''))))
        break
" 2>/dev/null) || true

    echo "$cid"
}

# -------------------------------------------------------------------------
# Create or update container
# -------------------------------------------------------------------------
deploy_image() {
    log "Deploying image ${IMAGE} as ${CONTAINER}"

    local cid
    cid=$(find_container)

    local payload
    if [[ -n "$cid" ]]; then
        echo "Updating existing container ${cid}..."
        payload=$(python3 -c "
import json
p = {
    'repoOrRegistry': 'registry',
    'registry': {'image': '${IMAGE}'},
    'deploymentConfig': {'desiredReplicas': ${REPLICAS}},
    'networking': {'containerPort': ${PORT}},
}
print(json.dumps(p))
")
        local resp
        resp=$(curl -sS -w "\n%{http_code}" \
            -X PUT \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${BASE_URL}/${cid}") || true

        local http_code
        http_code=$(echo "$resp" | tail -1)
        if [[ "$http_code" -ge 400 ]]; then
            fail "Failed to update container (HTTP ${http_code})"
        fi
        echo "container-id=${cid}" >> "$GITHUB_OUTPUT"
    else
        echo "Creating new container ${CONTAINER}..."
        payload=$(python3 -c "
import json
p = {
    'name': '${CONTAINER}',
    'type': 'deployment',
    'repoOrRegistry': 'registry',
    'registry': {'image': '${IMAGE}'},
    'deploymentConfig': {'desiredReplicas': ${REPLICAS}},
    'networking': {'containerPort': ${PORT}},
}
print(json.dumps(p))
")
        local resp
        resp=$(curl -sS -w "\n%{http_code}" \
            -X POST \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "${BASE_URL}") || true

        local http_code body
        http_code=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')

        if [[ "$http_code" -ge 400 ]]; then
            fail "Failed to create container (HTTP ${http_code}): ${body}"
        fi

        cid=$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('_id', d.get('iid', d.get('id', ''))))
" 2>/dev/null) || true

        echo "container-id=${cid}" >> "$GITHUB_OUTPUT"
    fi

    echo "status=success" >> "$GITHUB_OUTPUT"
    echo "Container deployed: ${CONTAINER} (${cid})"
    endlog
}

# -------------------------------------------------------------------------
# Trigger build for linked repo
# -------------------------------------------------------------------------
trigger_build() {
    log "Triggering build for ${CONTAINER}"

    local cid
    cid=$(find_container)

    if [[ -z "$cid" ]]; then
        fail "Container '${CONTAINER}' not found. Create it first or use 'image' input."
    fi

    local resp
    resp=$(curl -sS -w "\n%{http_code}" \
        -X POST \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        "${BASE_URL}/${cid}/trigger") || true

    local http_code
    http_code=$(echo "$resp" | tail -1)

    if [[ "$http_code" -ge 400 ]]; then
        fail "Failed to trigger build (HTTP ${http_code})"
    fi

    echo "container-id=${cid}" >> "$GITHUB_OUTPUT"
    echo "status=success" >> "$GITHUB_OUTPUT"
    echo "Build triggered for ${CONTAINER}"
    endlog
}

# -------------------------------------------------------------------------
# Wait for deployment
# -------------------------------------------------------------------------
wait_for_ready() {
    local cid="$1"
    if [[ -z "$cid" || "$WAIT" != "true" ]]; then
        return 0
    fi

    log "Waiting for deployment to be ready (timeout: ${TIMEOUT}s)"

    local start elapsed
    start=$(date +%s)

    while true; do
        elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -ge $TIMEOUT ]]; then
            echo "::warning::Deployment wait timed out after ${TIMEOUT}s"
            echo "status=timeout" >> "$GITHUB_OUTPUT"
            endlog
            return 0
        fi

        local resp
        resp=$(curl -sS \
            -H "${AUTH_HEADER}" \
            "${BASE_URL}/${cid}" 2>/dev/null) || true

        local avail
        avail=$(echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('status', {}).get('availableReplicas', 0))
" 2>/dev/null) || avail=0

        if [[ "$avail" -ge "$REPLICAS" ]]; then
            echo "Deployment ready (${avail}/${REPLICAS} replicas)"
            echo "status=success" >> "$GITHUB_OUTPUT"
            endlog
            return 0
        fi

        echo "Waiting... (${elapsed}s elapsed, ${avail}/${REPLICAS} ready)"
        sleep 5
    done
}

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
echo "Hanzo Deploy Action"
echo "  Platform: ${API}"
echo "  Org: ${ORG}"
echo "  Project: ${PROJECT}"
echo "  Environment: ${ENV}"
echo "  Container: ${CONTAINER}"

# Validate required inputs
[[ -z "$IAM_TOKEN" ]] && fail "api-key input is required"
[[ -z "$ORG" ]] && fail "org input is required"
[[ -z "$PROJECT" ]] && fail "project input is required"
[[ -z "$ENV" ]] && fail "env input is required"
[[ ! "$REPLICAS" =~ ^[0-9]+$ ]] && fail "replicas must be a number"
[[ ! "$PORT" =~ ^[0-9]+$ ]] && fail "port must be a number"
[[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] && fail "timeout must be a number"

# Mask token in logs
echo "::add-mask::${IAM_TOKEN}"

# Exchange IAM token for PaaS session
login

if [[ "$TRIGGER" == "true" ]]; then
    trigger_build
    cid=$(find_container)
    wait_for_ready "$cid"
elif [[ -n "$IMAGE" ]]; then
    deploy_image
    cid=$(grep "container-id=" "$GITHUB_OUTPUT" 2>/dev/null | tail -1 | cut -d= -f2) || true
    wait_for_ready "${cid:-}"
else
    fail "Either 'image' or 'trigger: true' input is required"
fi

echo "Done."
