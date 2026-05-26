# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

An SDLC automation framework that chains two things together:

1. **AI-powered documentation generation** — Claude Code skills that produce professional SDLC documents (PID → SRS → Strategic Design → Technical Design) in sequence, each reading the previous output as input.
2. **Code scaffolding scripts** — Python generators that produce complete, runnable project templates (Spring Boot hexagonal microservices or Next.js feature-based frontends).

All generated documents are written in **Spanish** (technical professional register).

## SDLC Workflow (Skill Commands)

The skills must be invoked in order. Each skill auto-discovers the previous phase's output from `docs/`.

```
/plan-pid             → docs/planning/PID-[name].md
/requirements-srs     → docs/requirements/SRS-[name].md
/strategic-design-sdd → docs/strategic-design/SDD-[name]-domain.md
                        docs/strategic-design/SDD-[name]-security.md
                        docs/strategic-design/SDD-[name]-architecture.md
/technical-design-sdd → docs/design/SDD-[name]-system.md
                        docs/design/SDD-[name]-design.md
                        docs/design/SDD-[name]-infrastructure.md
```

**Input templates:**
- `/plan-pid` — fill `.claude/formatos/input-template.md` and pass it as the argument.
- `/strategic-design-sdd` — optionally provide an ADC (Architectural Decision Context) from `.claude/formatos/input-adc-template.md` to constrain stack, infra model, quality attributes, and team capacity. Without it the skill infers defaults from the SRS.

**Skill chain dependency:** Skills do not skip phases. `/requirements-srs` requires a PID, `/strategic-design-sdd` requires an SRS, `/technical-design-sdd` requires all three Strategic Design documents.

**Skill output constraints:** No UML diagrams, no code blocks inside documents. Functional requirement IDs use `RF-001` format; non-functional use `RNF-001`. Architecture Decision Records use `ADR-001` format.

## Scaffolding Scripts

Both scripts live in `.claude/templates/` and write generated files to the current working directory.

### Spring Boot Hexagonal Microservice

```bash
python3 .claude/templates/maven_hexagonal_scaffold.py \
  -n <service-name> \
  -d <postgres|mongo> \
  -m <none|rabbit-producer|rabbit-consumer> \
  -v   # verbose/debug logging
```

Generates a multi-module Maven project (Spring Boot 3.4.1, Java 21, Project Reactor / WebFlux, R2DBC or MongoDB reactive driver, Lombok, spring-dotenv, Docker multi-stage build).

Module dependency rule — `domain` has zero external dependencies; `application` depends only on `domain`; `infrastructure` depends on `application`; entry points (`rest-api`, `app`, `rabbit-consumer`) are the composition root and depend on everything.

### Next.js Feature-Based Frontend

```bash
python3 .claude/templates/nextjs_feature_scaffold.py \
  -n <project-name> \
  -v   # verbose/debug logging
```

Generates a Next.js 15 / React 19 / TypeScript 5 app (TanStack Query 5, Zustand 5, Axios, NextAuth.js, Tailwind CSS 3, shadcn/ui, Zod, React Hook Form, Vitest, Playwright, Husky).

Key commands inside the generated project:

```bash
npm run dev          # Start dev server
npm run build        # Production build
npm run type-check   # tsc --noEmit
npm run lint:fix     # ESLint with auto-fix
npm run format       # Prettier
npm run test         # Vitest unit tests
npm run test:e2e     # Playwright E2E tests
```

**Architecture:** `app/` uses App Router with `(public)/` and `(protected)/` route groups. Each feature under `features/` is self-contained — its own types, Zod schemas, service layer, hooks, and Zustand slice. `lib/api/` provides an Axios client with automatic JWT refresh via interceptors. `lib/env/` validates environment variables with Zod at startup.

## Infrastructure Builder

```bash
bash .claude/scripts/base-infrastructure-builder.sh
```

Generates a full Terraform directory tree for the project. Requires Docker and Terraform. Creates multi-environment (`dev`/`staging`/`prod`) infrastructure modules for:

- **Frontend**: Vercel project and deployments (via `vercel` Terraform provider).
- **Backend**: AWS EKS cluster, RDS (PostgreSQL), IAM roles, Cognito user pool, API Gateway, Secrets Manager, ECR repositories.

Spins up a local `floci` Docker container that runs Terraform operations. Run this script after completing the Technical Design phase, using the infrastructure decisions from `docs/design/SDD-[name]-infrastructure.md` as inputs.

## Settings

`.claude/settings.json` has `"defaultMode": "bypassPermissions"` — Claude Code runs without permission prompts in this repo.
