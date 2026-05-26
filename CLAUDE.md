# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

An SDLC automation framework that chains two things together:

1. **AI-powered documentation generation** — Claude Code skills that produce professional SDLC documents (PID → SRS → Strategic Design → Technical Design) in sequence, each reading the previous output as input.
2. **Code scaffolding scripts** — Python generators that produce complete, runnable project templates (Spring Boot hexagonal microservices or Next.js feature-based frontends).

## SDLC Workflow (Skill Commands)

The skills are meant to be invoked in order. Each skill auto-discovers the previous phase's output from the `docs/` directory.

```
/plan-pid           → docs/planning/PID-[name].md
/requirements-srs   → docs/requirements/SRS-[name].md
/strategic-design-sdd → docs/strategic-design/ (3 files: domain, security, architecture)
/technical-design-sdd → docs/design/ (3 files: system, design, infrastructure)
```

Input templates for `/plan-pid` are in `.claude/formatos/input-template.md`. For strategic design, the ADC (Architectural Decision Context) template is in `.claude/formatos/input-adc-template.md`.

## Scaffolding Scripts

Both scripts are in `.claude/templates/` and write generated project files to the current working directory.

### Spring Boot Hexagonal Microservice

```bash
python .claude/templates/maven_hexagonal_scaffold.py \
  -n <service-name> \
  -d <postgres|mongo> \
  -m <none|rabbit-producer|rabbit-consumer> \
  -v   # verbose/debug logging
```

Generates a multi-module Maven project using hexagonal architecture (Ports & Adapters):
- **domain/** — entities and value objects
- **application/use-cases/** — business logic
- **infrastructure/driven-adapters/** — DB adapter (R2DBC/MongoDB) + optional RabbitMQ
- **infrastructure/entry-points/rest-api/** — REST controllers
- **infrastructure/entry-points/app/** — Spring Boot application root
- **infrastructure/entry-points/rabbit-consumer/** — optional message consumer

Stack: Spring Boot 3.4.1, Java 21, Project Reactor, Lombok, spring-dotenv, Docker multi-stage build.

### Next.js Feature-Based Frontend

```bash
python .claude/templates/nextjs_feature_scaffold.py \
  -n <project-name> \
  -v   # verbose/debug logging
```

Generates a Next.js 15 app with feature-based architecture. Key generated commands (inside output project):

```bash
npm run dev          # Start dev server
npm run build        # Production build
npm run type-check   # tsc --noEmit
npm run lint         # ESLint
npm run lint:fix     # ESLint with auto-fix
npm run format       # Prettier
npm run test         # Vitest
npm run test:ui      # Vitest UI
npm run test:e2e     # Playwright
```

Stack: Next.js 15, React 19, TypeScript 5, TanStack Query 5, Zustand 5, Axios, NextAuth.js, Tailwind CSS 3, shadcn/ui, Zod, React Hook Form, Vitest, Playwright, Husky.

Generated structure inside `src/`:
- `app/` — App Router with `(public)/` and `(protected)/` route groups
- `features/` — Feature modules (auth, users, dashboard, settings), each with types, schemas, services, hooks, store
- `lib/api/` — Axios HTTP client with interceptors and token refresh
- `lib/env/` — Zod-validated environment variables
- `providers/` — Context providers (Auth, Query, Theme, Toast)
- `store/` — Zustand stores

## Architecture Notes

**Skill chain dependency**: Each skill reads the previous phase's Markdown output. Do not skip phases — `/requirements-srs` expects a PID to exist, `/strategic-design-sdd` expects an SRS, etc.

**Hexagonal scaffold dependency rule**: `domain` has no dependencies on other modules. `application` depends on `domain`. `infrastructure` depends on `application`. Entry points (`rest-api`, `app`, `rabbit-consumer`) are the composition root.

**Next.js scaffold**: The API client in `lib/api/` uses Axios interceptors for automatic JWT refresh. Auth state lives in Zustand; server-fetched data lives in React Query. Features are self-contained — each feature owns its own types, Zod schemas, service layer, hooks, and store slice.

## Settings

`.claude/settings.json` has `"defaultMode": "bypassPermissions"` — Claude Code runs without permission prompts in this repo.
