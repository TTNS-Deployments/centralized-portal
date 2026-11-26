#!/usr/bin/env bash
# Deploys the Morpheus centralized portal to Azure App Service.
#
# Run it from Azure Cloud Shell (Bash):
#   cd ~ && (git clone https://github.com/TTNS-Deployments/centralized-portal.git 2>/dev/null || true) \
#     && cd ~/centralized-portal && git pull && bash Deployment/scripts/deploy.sh -e demo
#
# How it works
# - Cloud Shell can only get tokens for the Azure management API, so zip deploy, Kudu and publish profiles
#   don't work. This script only uses management calls.
# - The portal is a single static page (index.html) in a public GitHub repo. The web app downloads that page
#   from GitHub, pinned to a commit, every time it starts, then serves it with pm2.
#   A deployment is just: point the app setting at the latest commit, then restart.
# - Names follow the same convention as the demo apps: <prefix>-<env>-<suffix>-web, with
#   suffix = take(uniqueString(resourceGroup().id, prefix, env), 6), computed by ARM itself.
# - The web app runs on the existing B1 Linux plan shared with the demo apps. This script never changes
#   that plan or any other app.
#
# Usage: deploy.sh [-e <env>] [--app-name <name>] [--branch <branch>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$SCRIPT_DIR/../environments"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Options (command-line flags win over the environment file)
ENV="demo"
CLI_APP_NAME=""
CLI_BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -e|--env)      ENV="$2"; shift 2 ;;
    --app-name)    CLI_APP_NAME="$2"; shift 2 ;;
    --branch)      CLI_BRANCH="$2"; shift 2 ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             fail "Unknown option: $1" ;;
  esac
done

ENV_FILE="$ENV_DIR/$ENV.env"
[ -f "$ENV_FILE" ] || fail "No environment file $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"
[ -n "$CLI_BRANCH" ] && BRANCH="$CLI_BRANCH"
: "${RESOURCE_GROUP:?set in $ENV_FILE}" "${SOLUTION_PREFIX:?}" "${ENVIRONMENT_NAME:?}" "${EXISTING_PLAN_NAME:?}" "${REPO:?}" "${BRANCH:?}"
EXISTING_PLAN_RESOURCE_GROUP="${EXISTING_PLAN_RESOURCE_GROUP:-$RESOURCE_GROUP}"
SOLUTION_TAG="${SOLUTION_TAG:-$SOLUTION_PREFIX}"

command -v az >/dev/null || fail "Azure CLI not found. Run this in Azure Cloud Shell (Bash)."
if [ -n "${AZURE_SUBSCRIPTION:-}" ]; then az account set --subscription "$AZURE_SUBSCRIPTION"; fi
SUB_ID=$(az account show --query id -o tsv) || fail "Not signed in to Azure. Run: az login"
say "Environment: $ENV | Subscription: $(az account show --query name -o tsv) | Resource group: $RESOURCE_GROUP"

[ "$(az group exists -n "$RESOURCE_GROUP")" = "true" ] || fail "Resource group $RESOURCE_GROUP does not exist."

# ---------------------------------------------------------------------------------------------
say "Finding the shared App Service plan $EXISTING_PLAN_NAME"
PLAN_ID=$(az appservice plan show -g "$EXISTING_PLAN_RESOURCE_GROUP" -n "$EXISTING_PLAN_NAME" --query id -o tsv 2>/dev/null || true)
[ -n "$PLAN_ID" ] || fail "App Service plan $EXISTING_PLAN_NAME not found in $EXISTING_PLAN_RESOURCE_GROUP."
echo "    $(az appservice plan show --ids "$PLAN_ID" --query "join(' | ', [name, sku.name, location, kind])" -o tsv)"

# ---------------------------------------------------------------------------------------------
if [ -n "$CLI_APP_NAME" ]; then
  APP_NAME="$CLI_APP_NAME"
else
  say "Computing the resource name suffix (same formula as the demo templates)"
  NAMING_TEMPLATE=$(mktemp --suffix .json)
  cat > "$NAMING_TEMPLATE" <<'JSON'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": { "solutionPrefix": { "type": "string" }, "environmentName": { "type": "string" } },
  "resources": [],
  "outputs": {
    "suffix": {
      "type": "string",
      "value": "[take(uniqueString(resourceGroup().id, parameters('solutionPrefix'), parameters('environmentName')), 6)]"
    }
  }
}
JSON
  SUFFIX=$(az deployment group create -g "$RESOURCE_GROUP" -n "${SOLUTION_PREFIX}-${ENVIRONMENT_NAME}-naming" \
             --template-file "$NAMING_TEMPLATE" \
             --parameters solutionPrefix="$SOLUTION_PREFIX" environmentName="$ENVIRONMENT_NAME" \
             --query properties.outputs.suffix.value -o tsv)
  rm -f "$NAMING_TEMPLATE"
  [ -n "$SUFFIX" ] || fail "Could not compute the name suffix."
  APP_NAME="$(printf '%s' "$SOLUTION_PREFIX" | tr '[:upper:]' '[:lower:]')-${ENVIRONMENT_NAME}-${SUFFIX}-web"
fi
echo "    Web app name: $APP_NAME"

# ---------------------------------------------------------------------------------------------
say "Finding the latest commit on $REPO@$BRANCH"
SHA=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/$BRANCH" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || true)
if [ -z "$SHA" ] && git rev-parse HEAD >/dev/null 2>&1; then
  SHA=$(git rev-parse HEAD)   # fall back to the local clone
fi
[ -n "$SHA" ] || fail "Could not find the latest commit of $REPO."
SOURCE_URL="https://raw.githubusercontent.com/$REPO/$SHA/index.html"
echo "    Commit: $SHA"
curl -fsSL -o /dev/null "$SOURCE_URL" || fail "index.html is not reachable at $SOURCE_URL. Is the repo public and pushed?"

# ---------------------------------------------------------------------------------------------
TAGS=(solution="$SOLUTION_TAG" environment="$ENVIRONMENT_NAME")
if az webapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null 2>&1; then
  say "Web app $APP_NAME already exists. Updating it."
else
  # Newest Node LTS runtime App Service offers on Linux (Node only serves the static files)
  RUNTIME=$(az webapp list-runtimes --os linux -o tsv 2>/dev/null | grep -E '^NODE:[0-9]+-lts$' | sort -t: -k2 -V | tail -1 || true)
  RUNTIME="${RUNTIME:-NODE:22-lts}"
  say "Creating web app $APP_NAME ($RUNTIME) on the shared plan"
  az webapp create -g "$RESOURCE_GROUP" -p "$PLAN_ID" -n "$APP_NAME" --runtime "$RUNTIME" --tags "${TAGS[@]}" -o none \
    || fail "Could not create $APP_NAME. If the name is taken, rerun with --app-name <another-name>."
fi
WEB_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query id -o tsv)
az tag update --resource-id "$WEB_ID" --operation Merge --tags "${TAGS[@]}" -o none

say "Configuring the web app"
az webapp update -g "$RESOURCE_GROUP" -n "$APP_NAME" --https-only true -o none
az webapp config set -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none \
  --always-on true \
  --ftps-state Disabled \
  --startup-file 'curl -fsSL "$PORTAL_SOURCE_URL" -o /tmp/index.html && mv /tmp/index.html /home/site/wwwroot/index.html || echo "Portal download failed, serving the last copy"; pm2 serve /home/site/wwwroot --no-daemon'

say "Pointing the app at commit ${SHA:0:7}"
az webapp config appsettings set -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none --settings \
  PORTAL_SOURCE_URL="$SOURCE_URL" \
  PORTAL_COMMIT="$SHA" \
  SCM_DO_BUILD_DURING_DEPLOYMENT=false

say "Restarting"
az webapp restart -g "$RESOURCE_GROUP" -n "$APP_NAME" -o none

# ---------------------------------------------------------------------------------------------
HOST=$(az webapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" --query defaultHostName -o tsv)
URL="https://$HOST"
say "Waiting for $URL to serve commit ${SHA:0:7} (the first start on B1 can take a minute or two)"
EXPECTED=$(curl -fsSL "$SOURCE_URL" | sha256sum | cut -d' ' -f1)
for i in $(seq 1 30); do
  GOT=$(curl -fsS --max-time 20 "$URL/" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)
  if [ "$GOT" = "$EXPECTED" ]; then
    say "Done. The portal is live at: $URL"
    exit 0
  fi
  sleep 10
done

cat <<EOF

The deployment finished, but $URL is not serving the new page yet.
- Wait a minute and open it in the browser.
- If it still fails, open $APP_NAME in the Azure portal, go to Monitoring > Log stream, and run this script again.
EOF
exit 1
