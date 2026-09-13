---
title: Use skills when starting work with the product and its projects
---

# 🔵⋯ Common Project Rules
Session memory, the product plan, and pickup notes live on the external
rb-drive — not in this repo. Don't start cold; resume.

## 🟠⋯ Session lifecycle
- **Start** — `session-block-pick-up minimal generalist`: loads prior memory, the ship plan, and what to pick up
- **Before designing or building anything** — `conduct-product-dimensions`
- **End** — `session-block-wrap-up`: writes memory and pickup notes back

### 🟣⋯ The exemption has to speak
Skip Start or the dimensions pass only for a throwaway one-off — and **say which, before your first edit or design note**. Silence is not an exemption. It's a skip.
> One-off, skipping `<start | dimensions>`: `<why>`.

Trigger on your first action, not on whether the request sounded like a feature.
*"Lower the contrast of the background color of workspaces"* got built and handed back as a one-off, then earned a ship-plan entry and exposed a latent defect. Nothing about the request looked like that.

**Refuse this rationalization:** *"I'll run the pass afterwards if it turns out to matter."* → A pass over an existing implementation ratifies rather than verifies. A gate downstream of the thing it gates is not a gate.

## 🟠⋯ Where it lives (reference — the skills above resolve these for you)
`prj-use` fills `<PROJECT_NAME>`. If a path here ever disagrees with reality, trust the skill.

### 🟣⋯ Session block — `rb-drive/agents/<PROJECT_NAME>/`
- **Core Memories:** `agents-core-memories.md`
- **Turning Memories:** `agents-turning-memories.md`
- **Find My Bearings:** `agents-find-my-bearings.md`
- **Agent & Human Shared Understanding:** `agents-shared-understanding.md`
- **What to pick up next session:** `agents-pickup.md`

### 🟣⋯ Product — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Product/Feature Ship Plan:** `product-ship-plan.md`
- **Released Features:** `product-ship-released.md`

### 🟣⋯ Project — `rb-drive/projects/<PROJECT_NAME>/06_plan-execute/`
- **Project Workblock Plan:** `project-wb-plan.md`

---

# 🔵⋯ Custom Project Rules
This project's own rules — add them here. Everything above is common to every project, and `prj-setup retrofit` rewrites it.

## 🟠⋯ Release ownership — ours is `rbf/`, upstream's is the root
- Log user-facing fork changes with `docs-to-changelog <scope> rbf/CHANGELOG.md` — always pass the path, or the entry lands in this repo's default changelog doc
- Keep fork release notes in `rbf/CHANGELOG.md`, and what the positioning, terms, use, features in `rbf/README.md`; leave the root equivalents aligned with upstream
- Treat `rbf/RBF_VERSION` as the fork's release version — never bump upstream's own version manifest (`package.json`, `Cargo.toml`, …) for a fork release
- Keep `rbf/RBF_VERSION`, the top version heading in `rbf/CHANGELOG.md`, the feature brief, the ship plan, and the released test-suite entries on one version
