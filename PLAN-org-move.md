# Plan: Restore `community-code-review` After Org Move (slopsmith → got-feedback)

A step-by-step guide a lesser agent can follow. All repo edits and local verification come first; everything requiring human judgment (secrets, PAT rotation, runner registration, redeploying to other repos) is at the very end.

## Context

The `community-code-review` repo moved GitHub orgs: `slopsmith` → `got-feedback`. The git remote already points to the new home (`git@github.com:got-feedback/community-code-review.git`), but ~12 in-repo strings still hard-code the old name across docs, image refs, a workflow, and a local `.env`. Additionally the OCR review job currently fires on `pull_request` open/sync/reopen as well as comments — per the owner, it must **only** run when someone references it in a PR comment.

Two affected image registries are referenced in repo:
- `ghcr.io/slopsmith/coordinator:latest` — referenced by `docker-compose.yml` (leader stack)
- `ghcr.io/slopsmith/volunteer:latest` (+ `:cuda|:rocm|:vulkan|:intel`) — referenced by docs, server.py upgrade hint, and the volunteer's own model-folder README

The CI build workflows (`build-coordinator.yml`, `build-volunteer.yml`) derive the registry path from `${{ github.repository_owner }}`, so they auto-adapt after the next push to `main`. No edit needed there.

## Goal (Definition of "Done")

1. No string `slopsmith` remains anywhere in the repo except in intentional historical context (e.g. git log).
2. The OCR review workflow triggers **only** on a PR comment containing `/open-code-review` or `@open-code-review` — not on PR open/sync/reopen.
3. A freshly rebuilt coordinator container starts cleanly and the integration test (`./scripts/test.sh`, MOCK_MODE) passes, proving the coordinator accepts connections and relays inference.
4. Human-only follow-ups (PAT rotation, org secrets, runner re-registration, redeploying the workflow to target repos, notifying volunteers) are clearly listed at the end for the owner to perform.

## Pre-flight (quick agent self-checks before starting)

Run these read-only checks; abort and report if results differ from what's documented here.

```bash
cd /home/mogul/Documents/Code/feedback/community-code-review

# 1. Confirm we are on the new remote
git remote -v
# Expect: origin -> git@github.com:got-feedback/community-code-review.git

# 2. Confirm working tree is clean
git status
# Expect: nothing to commit, working tree clean, on main

# 3. Confirm full inventory of stale strings (should match the list in Step 1)
grep -rln "slopsmith" . | grep -v "^./\.git/"
```

If any of the above fails, **stop and ask the human** — do not attempt to fix.

## Step 1 — Replace remaining `slopsmith` strings (mechanical find/replace)

Find/replace `slopsmith` → `got-feedback` in **each** of these files. Use the surrounding context shown to target the exact occurrences; do **not** touch unrelated `ghcr.io/ggml-org/...` (llama.cpp base image) references.

| File | Line(s) | What to change |
|------|---------|----------------|
| `.env` | 6 | `GITHUB_ORG_NAME=slopsmith` → `GITHUB_ORG_NAME=got-feedback` |
| `LICENSE.md` | 3 | `Copyright (c) 2026 slopsmith` → `Copyright (c) 2026 got-feedback` |
| `coordinator/server.py` | 241 | `ghcr.io/slopsmith/volunteer:latest` → `ghcr.io/got-feedback/volunteer:latest` (inside the upgrade-hint log string) |
| `docker-compose.yml` | 3 | `image: ghcr.io/slopsmith/coordinator:latest` → `ghcr.io/got-feedback/coordinator:latest` |
| `docs/VOLUNTEER_SETUP.md` | 30, 31, 32, 33, 51, 61, 199, 246 | Every `ghcr.io/slopsmith/volunteer` → `ghcr.io/got-feedback/volunteer` (8 occurrences) |
| `setup.sh` | 264 | `https://github.com/slopsmith/community-code-review/...` → `https://github.com/got-feedback/community-code-review/...` |
| `scripts/test.sh` | 67 | `--build-arg ORG_NAME=slopsmith` → `--build-arg ORG_NAME=got-feedback` |
| `volunteer/MODEL_README.md` | 32, 36, 37 | `ghcr.io/slopsmith/...` and `github.com/slopsmith/...` → `ghcr.io/got-feedback/...` and `github.com/got-feedback/...` |

**Do not edit**:
- `.env.example` — already uses the `<your-github-org>` placeholder, no `slopsmith`.
- `.github/workflows/build-coordinator.yml`, `build-volunteer.yml` — registry path built from `${{ github.repository_owner }}`, which is now `got-feedback` automatically.
- `.github/workflows/deploy-ocr.yml` — uses `${{ github.repository }}` dynamically.
- `coordinator/Dockerfile` / `volunteer/Dockerfile` — the `ORG_NAME` build-arg is supplied at build time; the Dockerfiles themselves contain only the `${ORG_NAME}` placeholder. (`scripts/test.sh` is the only place that hard-codes the build-arg value, already covered above.)
- `ARCHITECTURE.md` — only references `ghcr.io/ggml-org/llama.cpp` (unrelated base image). No `slopsmith`.

After editing, verify:

```bash
grep -rln "slopsmith" . | grep -v "^./\.git/"
# Expect: empty output
```

## Step 2 — Change the OCR workflow to trigger only on PR comment references

The deployed source workflow lives at `workflows/ocr-review.yml`; an identical copy lives at `.github/workflows/ocr-review.yml` (the self-deployed version). **Edit both files identically** so a future `deploy-ocr` run doesn't reintroduce the old trigger.

In each file, remove the `pull_request:` trigger block entirely, keeping only the `issue_comment:` trigger. The top of the file should change from:

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]
```

to:

```yaml
on:
  issue_comment:
    types: [created]
```

The existing `if:` guard already restricts the `issue_comment` path to comments starting with `/open-code-review` or `@open-code-review` on pull-request issues — leave it unchanged. No other edits to the workflow body are needed.

After editing, verify both files no longer mention `pull_request:` in the trigger section and still contain the `issue_comment` block and the `/open-code-review` / `@open-code-review` guard:

```bash
grep -n "pull_request\|issue_comment\|open-code-review" workflows/ocr-review.yml .github/workflows/ocr-review.yml
```

## Step 3 — Validate via the integration test (proves the coordinator accepts connections)

The repo ships a deterministic integration test (`scripts/test.sh`) that builds both images from source, starts an isolated coordinator + mock volunteer on a private Docker network, and confirms:
- coordinator `/health` responds (HTTP 200 with `{"status": ...}`)
- volunteer registers and shows up on `GET /volunteers`
- `POST /v1/chat/completions` returns a `choices` array (i.e. the coordinator is **accepting connections and relaying inference**)

Run it:

```bash
cd /home/mogul/Documents/Code/feedback/community-code-review

# Clean up any leftover test containers/networks, then run the test
docker rm -f ccr-test-volunteer ccr-test-coordinator 2>/dev/null
docker network rm ccr-test-net 2>/dev/null
./scripts/test.sh
```

The script sets `set -euo pipefail` and exits non-zero on any failure, so a 0 exit code + the `✅ ALL TESTS PASSED` banner is the success criterion. This exercises the code paths touched in Steps 1 (the `ORG_NAME` build-arg) without needing a GPU or the real model (MOCK_MODE=1 default).

### If the integration test fails

- **Coordinator health check timed out** — inspect `docker logs ccr-test-coordinator`. Most likely cause: a Python syntax/import error introduced by the edit in Step 1 to `coordinator/server.py`. The only edit there is a string literal on line 241, so re-check that the quotes around the log string are intact.
- **Volunteer did not register** — inspect `docker logs ccr-test-volunteer`. The Step 1 edit to `scripts/test.sh` only changes a build-arg used in OCI labels; it cannot break registration. If this still fails, the cause is elsewhere and not introduced by this plan — report to the human.
- **Unit tests FAILED** — the volunteer image build runs before unit tests; if the build itself failed the script will already have exited. If `pytest` reports failures, they are pre-existing and out of scope for this org-rename work — capture the output and report to the human, but proceed no further.

Do **not** run the full (GPU) smoke test from `setup.sh` here — that requires a real GPU and downloads ~19GB of model. It belongs in the human-driven follow-up.

## Step 4 — Run the static checks the project uses

There is no `package.json`, no `ruff`/`mypy` config, and no lint script in this repo. The project's only automated gate is the integration test in Step 3 plus the unit tests (`tests/test_agent_state_machine.py`) which `scripts/test.sh` already runs as Step 2 of its flow. So no additional lint/typecheck commands are needed.

If you are aware of any local pre-commit hooks (`.pre-commit-config.yaml`) in the near future, run them too — but as of this writing none exist in the repo.

## Step 5 — Commit (but do NOT push)

Stage the changes in coherent commits so the human can review:

```bash
git add -p   # Select hunks deliberately; group by concern:
```

Suggested commit grouping:

1. **One commit**: `rename: slopsmith → got-feedback across docs, images, and config`
   - `.env`, `LICENSE.md`, `docker-compose.yml`, `coordinator/server.py`,
     `docs/VOLUNTEER_SETUP.md`, `setup.sh`, `scripts/test.sh`, `volunteer/MODEL_README.md`
2. **One commit**: `ci: restrict OCR workflow to /open-code-review comment trigger`
   - `workflows/ocr-review.yml`, `.github/workflows/ocr-review.yml`

Stop here. Do **not** push, do **not** open a PR. The human decides when to push (push triggers the org-wide `build-coordinator.yml` / `build-volunteer.yml` workflows that publish new images to `ghcr.io/got-feedback/...` — this only works once the GHCR package visibility/permissions are configured for the new org, a human action in Step 6).

---

# Human-driven follow-ups (DO NOT automate)

Hand these back to the owner once Steps 1–5 are complete and verified locally.

## 6. Rotate the exposed PAT

The current `.env` contains a live `GITHUB_PAT` value (`ghp_…`). Treat it as compromised — it lived in a tracked-adjacent file across the org move. Revoke it at https://github.com/settings/tokens and generate replacements for both secrets the system needs:

1. **Runner PAT** (admin:org scope on the new `got-feedback` org) — used by `docker-compose.yml`'s `runner` service to register the self-hosted org runner. Place it in `.env` as `GITHUB_PAT`.
2. **Deploy PAT** (repo + workflow scopes) — used by `.github/workflows/deploy-ocr.yml` and the self-deploy step. Store it as the **org Actions secret** `PROPAGATION_TOKEN` (see Step 8).

## 7. Container registry / images

Pushing to `main` triggers `build-coordinator.yml` and `build-volunteer.yml`, which publish to `ghcr.io/got-feedback/coordinator` and `ghcr.io/got-feedback/volunteer`. Ensure:

- The `got-feedback` org's GitHub Container Registry has package visibility set so volunteers can `docker pull ghcr.io/got-feedback/volunteer:latest` **publicly** (mirroring the public docker pull we documented). Check at `https://github.com/orgs/got-feedback/packages?tab=visibility`.
- The old `ghcr.io/slopsmith/...` images are either left up (harmless, but confusing) or deleted from `https://github.com/slopsmith?tab=packages`. Leaving them up is the safer default — some volunteers may still be running the old image.

If for any reason you don't want to wait for CI to rebuild images, you can build+tag locally and `docker push` them, but that bypasses the audit trail CI provides.

## 8. Re-create organization Actions secrets

The OCR workflow deployed into target repos reads the org secret `OCR_COORDINATOR_SECRET`, and the deploy workflow reads `PROPAGATION_TOKEN`. With the org move these secrets don't auto-migrate. Re-create both at:

- `https://github.com/organizations/got-feedback/settings/secrets/actions`

| Secret | Value | Used by |
|--------|-------|---------|
| `OCR_COORDINATOR_SECRET` | the `COORDINATOR_SECRET` value from your `.env` (already present — no need to regenerate) | `ocr-review.yml` (deployed into target repos) |
| `PROPAGATION_TOKEN` | the PAT from Step 6.2 (`repo` + `workflow` scopes) | `deploy-ocr.yml` |

## 9. Re-register the self-hosted runner against the new org

The `runner` service in `docker-compose.yml` registers itself against `ORG_NAME` from `.env` using the runner PAT. Because we updated `GITHUB_ORG_NAME=got-feedback` in `.env` (Step 1), simply bringing the stack down and back up will re-register against the new org:

```bash
cd /home/mogul/Documents/Code/feedback/community-code-review
./teardown.sh              # stops coordinator + runner + Tailscale Funnel
# (rotate PAT into .env now if you haven't already — Step 6.1)
docker compose pull        # pulls new got-feedback/* images once CI has published them
docker compose up -d
```

Confirm the runner shows up as **Idle** at:
`https://github.com/organizations/got-feedback/settings/actions/runners`

(If `teardown.sh` also stops the Tailscale Funnel, re-run `./setup.sh` — it detects the existing `.env` and skips re-generating secrets, only restarting the stack and Funnel. The printed coordinator URL and volunteer secret must match what's already in `.env` and what was shared with existing volunteers.)

## 10. Verify the coordinator is accepting connections from the outside

Once the stack is back up and the Tailscale Funnel URL is restored:

```bash
# From the leader machine
curl -sf https://<your-machine>.<your-tailnet>.ts.net/health

# Should return JSON with "status" — same shape the integration test checked
# locally in Step 3, but now over the public Funnel URL volunteers reach.
```

If that returns healthy JSON, the coordinator is **live and accepting connections**.

## 11. (Optional) Redeploy the OCR workflow to target repos

The existing `ocr-review.yml` deployed into each `got-feedback/*` repo is the **old** version (auto-fires on PR open/sync/reopen). To roll out the comment-only trigger repo-by-repo:

- Go to `https://github.com/got-feedback/community-code-review/actions/workflows/deploy-ocr.yml`
- Click **Run workflow**, optionally specifying a single `repo_name` first to validate, then again with it empty to deploy to all org repos.
- Merge the resulting bot PR in each target repo.

This only works after Step 8 (`PROPAGATION_TOKEN` must exist). Hold off until the human is ready to roll the change out broadly.

## 12. Notify existing volunteers

Anything they're running has the old `ghcr.io/slopsmith/volunteer:latest` image cached and the old `https://github.com/slopsmith/community-code-review/...` URL bookmarked. Send them:

- New volunteer setup link: `https://github.com/got-feedback/community-code-review/blob/main/docs/VOLUNTEER_SETUP.md`
- The unchanged `COORDINATOR_SECRET` (no need to rotate it — it was never in the org move's blast radius)
- The unchanged coordinator URL (Tailscale Funnel hostname is org-agnostic)
- Instruction to: `docker pull ghcr.io/got-feedback/volunteer:latest` then stop+remove+rerun their container with the same env vars as before.

Old volunteers will keep working against the live coordinator using cached old images, so this is non-urgent — but the upgrade-hint log line (`coordinator/server.py:241`) only emits the new `ghcr.io/got-feedback/volunteer:latest` URL once they reconnect post-push.

---

# Summary of agent-executable work

- Step 1: find/replace `slopsmith` → `got-feedback` in 8 files (full list with line numbers above).
- Step 2: edit `workflows/ocr-review.yml` and `.github/workflows/ocr-review.yml` to remove the `pull_request:` trigger (call-trigger only).
- Step 3: run `./scripts/test.sh`; expect `✅ ALL TESTS PASSED` (prove coordinator accepts connections).
- Step 4: no separate lint/typecheck to run.
- Step 5: stage commits (one rename, one CI trigger change). Do not push.

# Summary of human-only work (deferred to the end)

- 6: Rotate the exposed runner PAT; generate the deploy PAT.
- 7: Confirm GHCR package visibility for `ghcr.io/got-feedback/*`.
- 8: Recreate org Actions secrets (`OCR_COORDINATOR_SECRET`, `PROPAGATION_TOKEN`).
- 9: `teardown.sh` → updated `.env`/images → `docker compose up -d`; verify runner appears as Idle under the new org.
- 10: `curl` the public Funnel `/health` endpoint to confirm live acceptance of connections.
- 11: (Optional) Run `deploy-ocr.yml` to roll the comment-only trigger out to target repos; merge bot PRs.
- 12: Notify existing volunteers of the new image URL and setup link.