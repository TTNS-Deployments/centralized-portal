# Morpheus Centralized Portal

A single place to reach the team's tools and AI agent demos.

The portal is one static page, `index.html`, containing the login screen, the home page and a page for each section. The **AI Agents** page links out to the four demo web apps. Each demo opens in a new tab.

| Demo | URL |
|---|---|
| Call Center Analysis | https://ccai-demo-gqausd-web.azurewebsites.net/auth/login?next=/ |
| Chatbot | https://chatbot-web-wewqam.azurewebsites.net |
| Advanced Search | https://advsrch-demo-i5iesm-web.azurewebsites.net |
| Document Intelligence | https://docint-demo-tvv62x-web.azurewebsites.net |

> **Note:** the login is a prototype check that runs in the browser. It does not secure the portal or the demo apps. Because this repo is public, the password hashes in `index.html` are public too. Use App Service Authentication (Microsoft Entra ID) before wider rollout.

## Run locally

Open `index.html` in a browser. No build step is needed.

## Deploy (Azure Cloud Shell)

Open Azure Cloud Shell in **Bash** mode and paste:

```bash
cd ~ && (git clone https://github.com/TTNS-Deployments/centralized-portal.git 2>/dev/null || true) && cd ~/centralized-portal && git pull && bash Deployment/scripts/deploy.sh
```

Run the same command again whenever you push changes. It is safe to rerun.

What the script does (`Deployment/scripts/deploy.sh`):
1. Finds the B1 Linux App Service plan used by `ccai-demo-gqausd-web` in resource group `Vaibhav.Chaudhary`.
2. Creates the web app `morpheus-portal-<6 characters>` on that plan if it doesn't exist yet, using the newest Node LTS runtime.
3. Points the app at the latest commit on `main`. On every start, the app downloads `index.html` from GitHub for that commit and serves it with pm2.
4. Restarts the app, waits until it serves the new page, and prints the URL.

It uses only Azure management API calls, because zip deploy, Kudu and publish profiles don't work from this Cloud Shell. It never changes the shared plan or the demo apps.

Optional overrides: `APP_NAME=<name>`, `RESOURCE_GROUP=<rg>`, `BRANCH=<branch>`, for example:

```bash
APP_NAME=my-portal bash Deployment/scripts/deploy.sh
```

### Hosting summary

| Setting | Value |
|---|---|
| Service | Azure App Service (Linux), shared B1 plan `ccai-demo-gqausd-web-plan`, Central India |
| Web app | `morpheus-portal-<suffix>` (the script prints the exact name and URL) |
| Runtime | Node LTS, used only to serve the static file through `pm2 serve` |
| Code source | `PORTAL_SOURCE_URL` app setting: raw GitHub URL of `index.html`, pinned to a commit |

## Adding a new demo

In `index.html`, find the `data-view="agents"` section and copy one of the `<a class="tile" …>` blocks. Change the `href`, the name and the icon. Then commit, push and run the deploy command again.
