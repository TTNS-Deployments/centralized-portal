# Project progress: Morpheus centralized portal

## Context
- A single portal page giving access to TTBS tools and the four AI agent demos.
- Repo: https://github.com/TTNS-Deployments/centralized-portal (public, branch `main`).
- Deployment pattern and Azure constraints come from `DEMO_DEPLOYMENT_HANDOFF.md` in
  https://github.com/TTNS-Deployments/Call-Center-Analysis.

## Decisions
- The portal is one static file, `index.html`. The login, home and section pages are views switched by the URL hash.
- **AI Agents** keeps its name. Its page shows four demo tiles that open the demo apps in a new tab.
- The login is a prototype check that runs in the browser (SHA-256 hashes in the page). **Entra ID is not used for the first cut**, by the user's decision.
- Hosting: a new Linux web app on the **existing B1 plan** shared with the demos (`ccai-demo-gqausd-web-plan`, resource group `Vaibhav.Chaudhary`, Central India). The script never modifies that plan.
- Naming follows the demo repos: `<solutionPrefix>-<environmentName>-<suffix>-web`, with suffix = `take(uniqueString(resourceGroup().id, prefix, env), 6)`. The prefix is `portal` and the environment is `demo` (`Deployment/environments/demo.env`). ARM calculates the suffix through a deployment that creates no resources (`portal-demo-naming`). Tags: `solution=centralized-portal`, `environment=demo`.
- Deployment: Cloud Shell only has management-API tokens, so the code isn't uploaded. The web app downloads `index.html` from raw GitHub, pinned to a commit through the `PORTAL_SOURCE_URL` app setting, when it starts. `deploy.sh` updates that setting and restarts the app.

## Status (2026-11-26)
- [x] AI Agents page with four demo tiles
- [x] `Deployment/scripts/deploy.sh` (only syntax-checked locally; not yet run on Azure)
- [ ] First deployment from Cloud Shell
- [ ] Check in the browser: log in, open AI Agents, open each demo

## Next steps
- Run the deploy command from the README in Cloud Shell and check the printed URL.
- Later: App Service Authentication with Entra ID for the portal and the demos.
