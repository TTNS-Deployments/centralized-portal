#!/usr/bin/env bash
# Deploys the Morpheus centralized portal to Azure App Service.
#
# Run it from Azure Cloud Shell (Bash):
#   cd ~ && (git clone https://github.com/TTNS-Deployments/centralized-portal.git 2>/dev/null || true) \
#     && cd ~/centralized-portal && git pull && bash Deployment/scripts/deploy.sh
#
# How it works
# - Cloud Shell can only get tokens for the Azure management API, so zip deploy, Kudu and publish profiles
#   don't work. This script only uses management calls.
# - The portal is a single static page (index.html) in a public GitHub repo. The web app downloads that page
#   from GitHub, pinned to a commit, every time it starts, then serves it with pm2.
#   A deployment is just: point the app setting at the latest commit, then restart.
# - The web app runs on the existing B1 Linux plan shared with the demo apps. This script never changes
#   that plan or any other app.
#
# Override any of these with environment variables, for example: APP_NAME=my-portal bash Deployment/scripts/deploy.sh
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-Vaibhav.Chaudhary}"
SHARED_PLAN_APP="${SHARED_PLAN_APP:-ccai-demo-gqausd-web}"   # an existing web app whose plan the portal shares
REPO="${REPO:-TTNS-Deployments/centralized-portal}"
BRANCH="${BRANCH:-main}"
APP_NAME="${APP_NAME:-}"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || fail "Azure CLI not found. Run this in Azure Cloud Shell (Bash)."

SUB_ID=$(az account show --query id -o tsv) || fail "Not signed in to Azure. Run: az login"
say "Subscription: $(az account show --query name -o tsv) ($SUB_ID)"

# Web app names are global. Derive a stable, unique-enough name from the subscription.
if [ -z "$APP_NAME" ]; then
  APP_NAME="morpheus-portal-$(printf '%s' "$SUB_ID" | sha1sum | cut -c1-6)"
fi

# ---------------------------------------------------------------------------------------------
say "Finding the App Service plan used by $SHARED_PLAN_APP"
PLAN_ID=$(az webapp show -g "$RESOURCE_GROUP" -n "$SHARED_PLAN_APP" --query serverFarmId -o tsv 2>/dev/null) \
  || fail "Could not find web app $SHARED_PLAN_APP in resource group $RESOURCE_GROUP."
PLAN_INFO=$(az appservice plan show --ids "$PLAN_ID" --query "[name, sku.name, kind]" -o tsv | tr '\t\n' '  ')
echo "    Plan: $PLAN_INFO"

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
if az webapp show -g "$RESOURCE_GROUP" -n "$APP_NAME" >/dev/null 2>&1; then
  say "Web app $APP_NAME already exists. Updating it."
else
  # Newest Node LTS runtime App Service offers on Linux (Node only serves the static files)
  RUNTIME=$(az webapp list-runtimes --os linux -o tsv 2>/dev/null | grep -E '^NODE:[0-9]+-lts$' | sort -t: -k2 -V | tail -1 || true)
  RUNTIME="${RUNTIME:-NODE:22-lts}"
  say "Creating web app $APP_NAME ($RUNTIME) on the shared plan"
  az webapp create -g "$RESOURCE_GROUP" -p "$PLAN_ID" -n "$APP_NAME" --runtime "$RUNTIME" -o none \
    || fail "Could not create $APP_NAME. If the name is taken, rerun with APP_NAME=<another-name>."
fi

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
- If it still fails, open the web app in the Azure portal, go to Monitoring > Log stream, and run this script again.
EOF
exit 1
