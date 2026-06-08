#!/usr/bin/env python3
"""Genera un arquetipo base profesional Next.js con arquitectura Feature-Based enterprise."""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


# ─── CONFIG FILES ─────────────────────────────────────────────────────────────

def get_package_json(project_name: str) -> str:
    return f"""\
{{
  "name": "{project_name}",
  "version": "0.1.0",
  "private": true,
  "scripts": {{
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "lint:fix": "next lint --fix",
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "type-check": "tsc --noEmit",
    "test": "vitest",
    "test:ui": "vitest --ui",
    "test:e2e": "playwright test",
    "prepare": "husky"
  }},
  "dependencies": {{
    "next": "^15.3.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "@tanstack/react-query": "^5.62.0",
    "@tanstack/react-query-devtools": "^5.62.0",
    "zustand": "^5.0.2",
    "react-hook-form": "^7.54.0",
    "@hookform/resolvers": "^3.9.0",
    "zod": "^3.23.8",
    "class-variance-authority": "^0.7.0",
    "clsx": "^2.1.1",
    "tailwind-merge": "^2.5.5",
    "lucide-react": "^0.468.0",
    "next-themes": "^0.4.3",
    "sonner": "^1.7.0",
    "axios": "^1.7.9"
  }},
  "devDependencies": {{
    "@types/node": "^20",
    "@types/react": "^19",
    "@types/react-dom": "^19",
    "typescript": "^5",
    "tailwindcss": "^3.4.1",
    "postcss": "^8",
    "autoprefixer": "^10.0.1",
    "eslint": "^9.0.0",
    "eslint-config-next": "^15.3.0",
    "@eslint/eslintrc": "^3.2.0",
    "@typescript-eslint/eslint-plugin": "^8.0.0",
    "@typescript-eslint/parser": "^8.0.0",
    "prettier": "^3.4.0",
    "prettier-plugin-tailwindcss": "^0.6.9",
    "husky": "^9.1.7",
    "lint-staged": "^15.2.0",
    "vitest": "^2.1.0",
    "@vitejs/plugin-react": "^4.3.0",
    "@testing-library/react": "^16.1.0",
    "@testing-library/user-event": "^14.5.2",
    "@playwright/test": "^1.49.0"
  }}
}}
"""


def get_tsconfig() -> str:
    return """\
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": false,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": {
      "@/*": ["./src/*"],
      "@/components/*": ["./src/components/*"],
      "@/features/*": ["./src/features/*"],
      "@/lib/*": ["./src/lib/*"],
      "@/hooks/*": ["./src/hooks/*"],
      "@/services/*": ["./src/services/*"],
      "@/store/*": ["./src/store/*"],
      "@/styles/*": ["./src/styles/*"],
      "@/types/*": ["./src/types/*"],
      "@/config/*": ["./src/config/*"],
      "@/providers/*": ["./src/providers/*"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
"""


def get_next_config() -> str:
    return """\
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  images: {
    remotePatterns: [
      {
        protocol: 'https',
        hostname: '**',
      },
    ],
  },
  experimental: {
    typedRoutes: true,
  },
}

export default nextConfig
"""


def get_tailwind_config() -> str:
    return """\
import type { Config } from 'tailwindcss'

const config: Config = {
  darkMode: ['class'],
  content: [
    './src/pages/**/*.{js,ts,jsx,tsx,mdx}',
    './src/components/**/*.{js,ts,jsx,tsx,mdx}',
    './src/features/**/*.{js,ts,jsx,tsx,mdx}',
    './src/app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        border: 'hsl(var(--border))',
        input: 'hsl(var(--input))',
        ring: 'hsl(var(--ring))',
        background: 'hsl(var(--background))',
        foreground: 'hsl(var(--foreground))',
        primary: {
          DEFAULT: 'hsl(var(--primary))',
          foreground: 'hsl(var(--primary-foreground))',
        },
        secondary: {
          DEFAULT: 'hsl(var(--secondary))',
          foreground: 'hsl(var(--secondary-foreground))',
        },
        destructive: {
          DEFAULT: 'hsl(var(--destructive))',
          foreground: 'hsl(var(--destructive-foreground))',
        },
        muted: {
          DEFAULT: 'hsl(var(--muted))',
          foreground: 'hsl(var(--muted-foreground))',
        },
        accent: {
          DEFAULT: 'hsl(var(--accent))',
          foreground: 'hsl(var(--accent-foreground))',
        },
        popover: {
          DEFAULT: 'hsl(var(--popover))',
          foreground: 'hsl(var(--popover-foreground))',
        },
        card: {
          DEFAULT: 'hsl(var(--card))',
          foreground: 'hsl(var(--card-foreground))',
        },
      },
      borderRadius: {
        lg: 'var(--radius)',
        md: 'calc(var(--radius) - 2px)',
        sm: 'calc(var(--radius) - 4px)',
      },
    },
  },
  plugins: [],
}

export default config
"""


def get_postcss_config() -> str:
    return """\
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
"""


def get_eslint_config() -> str:
    return """\
import { dirname } from 'path'
import { fileURLToPath } from 'url'
import { FlatCompat } from '@eslint/eslintrc'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const compat = new FlatCompat({ baseDirectory: __dirname })

const eslintConfig = [
  ...compat.extends('next/core-web-vitals', 'next/typescript'),
  {
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/consistent-type-imports': ['error', { prefer: 'type-imports' }],
    },
  },
]

export default eslintConfig
"""


def get_prettier_config() -> str:
    return """\
{
  "semi": false,
  "singleQuote": true,
  "tabWidth": 2,
  "trailingComma": "es5",
  "printWidth": 100,
  "plugins": ["prettier-plugin-tailwindcss"]
}
"""


def get_prettier_ignore() -> str:
    return """\
.next
node_modules
dist
build
.husky
"""


def get_lintstaged_config() -> str:
    return """\
{
  "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
  "*.{js,jsx,json,md,yml,yaml}": ["prettier --write"]
}
"""


def get_gitignore() -> str:
    return """\
# dependencies
/node_modules
/.pnp
.pnp.js

# testing
/coverage

# next.js
/.next/
/out/

# production
/build

# misc
.DS_Store
*.pem

# debug
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# local env files
.env*.local
.env

# vercel
.vercel

# typescript
*.tsbuildinfo
next-env.d.ts
"""


def get_env_local(project_name: str) -> str:
    return f"""\
NEXTAUTH_URL=http://localhost:3000
NEXTAUTH_SECRET=dev-secret-change-in-production

# Cognito local (floci)
COGNITO_CLIENT_ID=dev-client-id
COGNITO_CLIENT_SECRET=dev-client-secret
COGNITO_ISSUER=http://localhost:9229

# API Gateway local
NEXT_PUBLIC_API_BASE_URL=http://localhost:4567/v1
"""


def get_env_example(project_name: str) -> str:
    return f"""\
# ======================================================================
# Environment Variables Template - {project_name}
# ======================================================================
# This file documents all required variables.
# The actual .env.local is pre-filled with development defaults.
# For staging/production, set real values in your deployment platform.
# ======================================================================

# App
NEXT_PUBLIC_APP_URL=https://your-domain.com
NEXT_PUBLIC_APP_NAME={project_name}
NEXT_PUBLIC_APP_ENV=production

# API
NEXT_PUBLIC_API_URL=https://api.your-domain.com/api/v1
API_SECRET_KEY=

# Auth
NEXTAUTH_URL=https://your-domain.com
NEXTAUTH_SECRET=
JWT_SECRET=

# Feature Flags
NEXT_PUBLIC_ENABLE_ANALYTICS=false
NEXT_PUBLIC_ENABLE_DEBUG=false
"""


def get_components_json() -> str:
    return """\
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "default",
  "rsc": true,
  "tsx": true,
  "tailwind": {
    "config": "tailwind.config.ts",
    "css": "src/styles/globals.css",
    "baseColor": "slate",
    "cssVariables": true
  },
  "aliases": {
    "components": "@/components",
    "utils": "@/lib/utils"
  }
}
"""


def get_husky_pre_commit() -> str:
    return """\
#!/usr/bin/env sh
. "$(dirname -- "$0")/_/husky.sh"

npx lint-staged
"""


# ─── APP LAYER ────────────────────────────────────────────────────────────────

def get_root_layout(project_name: str) -> str:
    return f"""\
import type {{ Metadata }} from 'next'
import {{ Inter }} from 'next/font/google'

import {{ Providers }} from '@/providers'
import '@/styles/globals.css'

const inter = Inter({{ subsets: ['latin'] }})

export const metadata: Metadata = {{
  title: {{
    template: `%s | {project_name}`,
    default: '{project_name}',
  }},
  description: 'Enterprise-grade Next.js application',
}}

export default function RootLayout({{
  children,
}}: {{
  children: React.ReactNode
}}) {{
  return (
    <html lang="en" suppressHydrationWarning>
      <body className={{inter.className}}>
        <Providers>{{children}}</Providers>
      </body>
    </html>
  )
}}
"""


def get_root_loading() -> str:
    return """\
export default function Loading() {
  return (
    <div className="flex h-screen w-full items-center justify-center">
      <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent" />
    </div>
  )
}
"""


def get_root_error() -> str:
    return """\
'use client'

import { useEffect } from 'react'

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  useEffect(() => {
    console.error(error)
  }, [error])

  return (
    <div className="flex h-screen flex-col items-center justify-center gap-4">
      <h2 className="text-2xl font-bold">Something went wrong</h2>
      <p className="text-muted-foreground">{error.message}</p>
      <button
        onClick={reset}
        className="rounded-md bg-primary px-4 py-2 text-primary-foreground hover:bg-primary/90"
      >
        Try again
      </button>
    </div>
  )
}
"""


def get_not_found() -> str:
    return """\
import Link from 'next/link'

export default function NotFound() {
  return (
    <div className="flex h-screen flex-col items-center justify-center gap-4">
      <h1 className="text-6xl font-bold">404</h1>
      <h2 className="text-2xl font-semibold">Page not found</h2>
      <p className="text-muted-foreground">The page you are looking for does not exist.</p>
      <Link
        href="/"
        className="rounded-md bg-primary px-4 py-2 text-primary-foreground hover:bg-primary/90"
      >
        Go home
      </Link>
    </div>
  )
}
"""


def get_public_page() -> str:
    return """\
import Link from 'next/link'

export default function HomePage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-8 p-8">
      <div className="text-center">
        <h1 className="text-4xl font-bold tracking-tight">Welcome</h1>
        <p className="mt-4 text-lg text-muted-foreground">
          Enterprise Next.js Archetype — Feature-Based Architecture
        </p>
      </div>
      <div className="flex gap-4">
        <Link
          href="/login"
          className="rounded-md bg-primary px-6 py-3 text-primary-foreground hover:bg-primary/90"
        >
          Sign in
        </Link>
        <Link
          href="/dashboard"
          className="rounded-md border px-6 py-3 hover:bg-accent"
        >
          Dashboard
        </Link>
      </div>
    </main>
  )
}
"""


def get_public_login_page() -> str:
    return """\
import type { Metadata } from 'next'

import { LoginForm } from '@/features/auth/components/login-form'

export const metadata: Metadata = { title: 'Sign in' }

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold">Sign in</h1>
          <p className="text-sm text-muted-foreground">Enter your credentials to continue</p>
        </div>
        <LoginForm />
      </div>
    </div>
  )
}
"""


def get_protected_layout() -> str:
    return """\
import { Header } from '@/components/layouts/header'
import { Sidebar } from '@/components/layouts/sidebar'

export default function ProtectedLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen overflow-hidden">
      <Sidebar />
      <div className="flex flex-1 flex-col overflow-hidden">
        <Header />
        <main className="flex-1 overflow-y-auto p-6">{children}</main>
      </div>
    </div>
  )
}
"""


def get_dashboard_page() -> str:
    return """\
import type { Metadata } from 'next'

import { DashboardStats } from '@/features/dashboard/components/dashboard-stats'

export const metadata: Metadata = { title: 'Dashboard' }

export default function DashboardPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Dashboard</h1>
        <p className="text-muted-foreground">Welcome back</p>
      </div>
      <DashboardStats />
    </div>
  )
}
"""


def get_api_health_route() -> str:
    return """\
import { NextResponse } from 'next/server'

export async function GET() {
  return NextResponse.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: process.env.npm_package_version ?? '0.0.0',
  })
}
"""


# ─── STYLES ───────────────────────────────────────────────────────────────────

def get_globals_css() -> str:
    return """\
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  :root {
    --background: 0 0% 100%;
    --foreground: 222.2 84% 4.9%;
    --card: 0 0% 100%;
    --card-foreground: 222.2 84% 4.9%;
    --popover: 0 0% 100%;
    --popover-foreground: 222.2 84% 4.9%;
    --primary: 222.2 47.4% 11.2%;
    --primary-foreground: 210 40% 98%;
    --secondary: 210 40% 96.1%;
    --secondary-foreground: 222.2 47.4% 11.2%;
    --muted: 210 40% 96.1%;
    --muted-foreground: 215.4 16.3% 46.9%;
    --accent: 210 40% 96.1%;
    --accent-foreground: 222.2 47.4% 11.2%;
    --destructive: 0 84.2% 60.2%;
    --destructive-foreground: 210 40% 98%;
    --border: 214.3 31.8% 91.4%;
    --input: 214.3 31.8% 91.4%;
    --ring: 222.2 84% 4.9%;
    --radius: 0.5rem;
  }

  .dark {
    --background: 222.2 84% 4.9%;
    --foreground: 210 40% 98%;
    --card: 222.2 84% 4.9%;
    --card-foreground: 210 40% 98%;
    --popover: 222.2 84% 4.9%;
    --popover-foreground: 210 40% 98%;
    --primary: 210 40% 98%;
    --primary-foreground: 222.2 47.4% 11.2%;
    --secondary: 217.2 32.6% 17.5%;
    --secondary-foreground: 210 40% 98%;
    --muted: 217.2 32.6% 17.5%;
    --muted-foreground: 215 20.2% 65.1%;
    --accent: 217.2 32.6% 17.5%;
    --accent-foreground: 210 40% 98%;
    --destructive: 0 62.8% 30.6%;
    --destructive-foreground: 210 40% 98%;
    --border: 217.2 32.6% 17.5%;
    --input: 217.2 32.6% 17.5%;
    --ring: 212.7 26.8% 83.9%;
  }
}

@layer base {
  * {
    @apply border-border;
  }
  body {
    @apply bg-background text-foreground;
  }
}
"""


# ─── TYPES ────────────────────────────────────────────────────────────────────

def get_global_types() -> str:
    return """\
declare global {
  type Nullable<T> = T | null
  type Optional<T> = T | undefined
  type Maybe<T> = T | null | undefined
  type ID = string
  type Timestamp = string

  interface PaginationParams {
    page: number
    limit: number
  }

  interface PaginatedResponse<T> {
    data: T[]
    total: number
    page: number
    limit: number
    totalPages: number
  }
}

export {}
"""


def get_api_types() -> str:
    return """\
export interface ApiResponse<T = unknown> {
  data: T
  message?: string
  success: boolean
}

export interface ApiError {
  message: string
  code: string
  status: number
  details?: Record<string, string[]>
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

export interface RequestConfig {
  headers?: Record<string, string>
  params?: Record<string, string | number | boolean>
  timeout?: number
  signal?: AbortSignal
}
"""


# ─── LIB LAYER ────────────────────────────────────────────────────────────────

def get_lib_utils() -> str:
    return """\
import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function formatDate(date: Date | string, locale = 'en-US'): string {
  return new Intl.DateTimeFormat(locale, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  }).format(new Date(date))
}

export function formatCurrency(amount: number, currency = 'USD', locale = 'en-US'): string {
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount)
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export function capitalize(str: string): string {
  return str.charAt(0).toUpperCase() + str.slice(1).toLowerCase()
}

export function truncate(str: string, length: number): string {
  return str.length > length ? `${str.slice(0, length)}...` : str
}
"""


def get_lib_env() -> str:
    return """\
import { z } from 'zod'

const envSchema = z.object({
  NEXT_PUBLIC_APP_URL: z.preprocess(
    (v) => (v && String(v).trim()) || 'http://localhost:3000',
    z.string().url()
  ),
  NEXT_PUBLIC_APP_NAME: z.string().min(1).default('App'),
  NEXT_PUBLIC_APP_ENV: z.enum(['development', 'staging', 'production']).default('development'),
  NEXT_PUBLIC_API_URL: z.preprocess(
    (v) => (v && String(v).trim()) || 'http://localhost:8080/api/v1',
    z.string().url()
  ),
  NEXT_PUBLIC_ENABLE_ANALYTICS: z
    .string()
    .transform((v) => v === 'true')
    .default('false'),
  NEXT_PUBLIC_ENABLE_DEBUG: z
    .string()
    .transform((v) => v === 'true')
    .default('false'),
})

const parsed = envSchema.safeParse(process.env)

if (!parsed.success) {
  console.error('❌ Invalid environment variables:', parsed.error.flatten().fieldErrors)
  throw new Error('Invalid environment variables — check .env.local')
}

export const env = parsed.data

export const isDev = env.NEXT_PUBLIC_APP_ENV === 'development'
export const isProd = env.NEXT_PUBLIC_APP_ENV === 'production'
"""


def get_lib_constants() -> str:
    return """\
export const APP_NAME = process.env.NEXT_PUBLIC_APP_NAME ?? 'App'
export const APP_URL = process.env.NEXT_PUBLIC_APP_URL ?? 'http://localhost:3000'

export const ROUTES = {
  HOME: '/',
  LOGIN: '/login',
  DASHBOARD: '/dashboard',
  SETTINGS: '/settings',
  USERS: '/users',
} as const

export const QUERY_KEYS = {
  USERS: ['users'] as const,
  USER: (id: string) => ['users', id] as const,
  DASHBOARD_STATS: ['dashboard', 'stats'] as const,
  SETTINGS: ['settings'] as const,
} as const

export const HTTP_STATUS = {
  OK: 200,
  CREATED: 201,
  NO_CONTENT: 204,
  BAD_REQUEST: 400,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  INTERNAL_SERVER_ERROR: 500,
} as const

export const PAGINATION_DEFAULTS = {
  PAGE: 1,
  LIMIT: 10,
} as const
"""


def get_lib_api_client() -> str:
    return """\
import axios, { type AxiosInstance, type AxiosRequestConfig } from 'axios'

import { env } from '@/lib/env'

import { setupInterceptors } from './interceptors'

function createApiClient(): AxiosInstance {
  const client = axios.create({
    baseURL: env.NEXT_PUBLIC_API_URL,
    timeout: 15_000,
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
  })

  setupInterceptors(client)
  return client
}

export const apiClient = createApiClient()

export async function get<T>(url: string, config?: AxiosRequestConfig): Promise<T> {
  const { data } = await apiClient.get<T>(url, config)
  return data
}

export async function post<T>(url: string, body?: unknown, config?: AxiosRequestConfig): Promise<T> {
  const { data } = await apiClient.post<T>(url, body, config)
  return data
}

export async function put<T>(url: string, body?: unknown, config?: AxiosRequestConfig): Promise<T> {
  const { data } = await apiClient.put<T>(url, body, config)
  return data
}

export async function patch<T>(url: string, body?: unknown, config?: AxiosRequestConfig): Promise<T> {
  const { data } = await apiClient.patch<T>(url, body, config)
  return data
}

export async function del<T>(url: string, config?: AxiosRequestConfig): Promise<T> {
  const { data } = await apiClient.delete<T>(url, config)
  return data
}
"""


def get_lib_api_interceptors() -> str:
    return """\
import type { AxiosInstance, InternalAxiosRequestConfig, AxiosResponse, AxiosError } from 'axios'

import { handleApiError } from './error-handler'

export function setupInterceptors(client: AxiosInstance): void {
  client.interceptors.request.use(
    (config: InternalAxiosRequestConfig) => {
      const token = getAccessToken()
      if (token) {
        config.headers.Authorization = `Bearer ${token}`
      }
      return config
    },
    (error: AxiosError) => Promise.reject(error)
  )

  client.interceptors.response.use(
    (response: AxiosResponse) => response,
    async (error: AxiosError) => {
      const originalRequest = error.config as InternalAxiosRequestConfig & { _retry?: boolean }

      if (error.response?.status === 401 && !originalRequest._retry) {
        originalRequest._retry = true
        try {
          await refreshAccessToken()
          const newToken = getAccessToken()
          if (newToken) {
            originalRequest.headers.Authorization = `Bearer ${newToken}`
          }
          return client(originalRequest)
        } catch {
          clearTokens()
          window.location.href = '/login'
        }
      }

      return Promise.reject(handleApiError(error))
    }
  )
}

function getAccessToken(): string | null {
  if (typeof window === 'undefined') return null
  return localStorage.getItem('access_token')
}

async function refreshAccessToken(): Promise<void> {
  // Implement refresh token logic
}

function clearTokens(): void {
  if (typeof window === 'undefined') return
  localStorage.removeItem('access_token')
  localStorage.removeItem('refresh_token')
}
"""


def get_lib_api_error_handler() -> str:
    return """\
import type { AxiosError } from 'axios'

import type { ApiError } from '@/types/api.types'

export class AppError extends Error {
  constructor(
    message: string,
    public readonly code: string,
    public readonly status: number,
    public readonly details?: Record<string, string[]>
  ) {
    super(message)
    this.name = 'AppError'
  }
}

export function handleApiError(error: AxiosError): AppError {
  const apiError = error.response?.data as ApiError | undefined

  if (apiError) {
    return new AppError(
      apiError.message ?? 'An unexpected error occurred',
      apiError.code ?? 'UNKNOWN_ERROR',
      error.response?.status ?? 500,
      apiError.details
    )
  }

  if (error.request) {
    return new AppError('Network error — please check your connection', 'NETWORK_ERROR', 0)
  }

  return new AppError(error.message, 'CLIENT_ERROR', 0)
}

export function isAppError(error: unknown): error is AppError {
  return error instanceof AppError
}
"""


def get_lib_api_types() -> str:
    return """\
export type { ApiResponse, ApiError, HttpMethod, RequestConfig } from '@/types/api.types'
"""


def get_lib_validations() -> str:
    return """\
import { z } from 'zod'

export const emailSchema = z.string().email('Invalid email address')

export const passwordSchema = z
  .string()
  .min(8, 'Password must be at least 8 characters')
  .regex(/[A-Z]/, 'Password must contain at least one uppercase letter')
  .regex(/[0-9]/, 'Password must contain at least one number')

export const paginationSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().positive().max(100).default(10),
})

export const idSchema = z.string().uuid('Invalid ID format')
"""


# ─── PROVIDERS ────────────────────────────────────────────────────────────────

def get_providers_index() -> str:
    return """\
'use client'

import { AuthProvider } from './auth-provider'
import { QueryProvider } from './query-provider'
import { ThemeProvider } from './theme-provider'
import { ToastProvider } from './toast-provider'

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider>
      <QueryProvider>
        <AuthProvider>
          {children}
          <ToastProvider />
        </AuthProvider>
      </QueryProvider>
    </ThemeProvider>
  )
}
"""


def get_query_provider() -> str:
    return """\
'use client'

import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ReactQueryDevtools } from '@tanstack/react-query-devtools'
import { useState } from 'react'

import { isDev } from '@/lib/env'

export function QueryProvider({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            retry: (failureCount, error) => {
              if ((error as { status?: number }).status === 404) return false
              return failureCount < 3
            },
          },
          mutations: {
            retry: false,
          },
        },
      })
  )

  return (
    <QueryClientProvider client={queryClient}>
      {children}
      {isDev && <ReactQueryDevtools initialIsOpen={false} />}
    </QueryClientProvider>
  )
}
"""


def get_theme_provider() -> str:
    return """\
'use client'

import { ThemeProvider as NextThemesProvider } from 'next-themes'
import type { ThemeProviderProps } from 'next-themes'

export function ThemeProvider({ children, ...props }: ThemeProviderProps) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="system"
      enableSystem
      disableTransitionOnChange
      {...props}
    >
      {children}
    </NextThemesProvider>
  )
}
"""


def get_auth_provider() -> str:
    return """\
'use client'

import { createContext, useContext, useEffect, useState } from 'react'

import type { AuthUser } from '@/features/auth/types/auth.types'

interface AuthContextValue {
  user: AuthUser | null
  isLoading: boolean
  isAuthenticated: boolean
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [user] = useState<AuthUser | null>(null)
  const [isLoading, setIsLoading] = useState(true)

  useEffect(() => {
    // Replace with actual session check
    setIsLoading(false)
  }, [])

  return (
    <AuthContext.Provider value={{ user, isLoading, isAuthenticated: !!user }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuthContext(): AuthContextValue {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuthContext must be used within AuthProvider')
  return ctx
}
"""


def get_toast_provider() -> str:
    return """\
'use client'

import { Toaster } from 'sonner'
import { useTheme } from 'next-themes'

export function ToastProvider() {
  const { theme } = useTheme()
  return (
    <Toaster
      theme={theme as 'light' | 'dark' | 'system'}
      position="bottom-right"
      richColors
      closeButton
    />
  )
}
"""


# ─── MIDDLEWARE ────────────────────────────────────────────────────────────────

def get_middleware() -> str:
    return """\
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const PUBLIC_PATHS = ['/', '/login', '/register', '/api/health']
const AUTH_PATHS = ['/login', '/register']

function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((path) => pathname === path || pathname.startsWith('/api/'))
}

function isAuthPath(pathname: string): boolean {
  return AUTH_PATHS.some((path) => pathname.startsWith(path))
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl
  const token = request.cookies.get('access_token')?.value

  if (!token && !isPublicPath(pathname)) {
    const loginUrl = new URL('/login', request.url)
    loginUrl.searchParams.set('callbackUrl', pathname)
    return NextResponse.redirect(loginUrl)
  }

  if (token && isAuthPath(pathname)) {
    return NextResponse.redirect(new URL('/dashboard', request.url))
  }

  return NextResponse.next()
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.png$).*)'],
}
"""


# ─── COMPONENTS ───────────────────────────────────────────────────────────────

def get_sidebar() -> str:
    return """\
'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { LayoutDashboard, Users, Settings } from 'lucide-react'

import { cn } from '@/lib/utils'
import { ROUTES } from '@/lib/constants'

const navItems = [
  { href: ROUTES.DASHBOARD, label: 'Dashboard', icon: LayoutDashboard },
  { href: ROUTES.USERS, label: 'Users', icon: Users },
  { href: ROUTES.SETTINGS, label: 'Settings', icon: Settings },
]

export function Sidebar() {
  const pathname = usePathname()

  return (
    <aside className="flex h-screen w-64 flex-col border-r bg-card">
      <div className="flex h-16 items-center border-b px-6">
        <span className="text-lg font-bold">{process.env.NEXT_PUBLIC_APP_NAME}</span>
      </div>
      <nav className="flex-1 space-y-1 p-4">
        {navItems.map(({ href, label, icon: Icon }) => (
          <Link
            key={href}
            href={href}
            className={cn(
              'flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors',
              pathname === href
                ? 'bg-primary text-primary-foreground'
                : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
            )}
          >
            <Icon className="h-4 w-4" />
            {label}
          </Link>
        ))}
      </nav>
    </aside>
  )
}
"""


def get_header() -> str:
    return """\
'use client'

import { Moon, Sun, Bell } from 'lucide-react'
import { useTheme } from 'next-themes'

export function Header() {
  const { theme, setTheme } = useTheme()

  return (
    <header className="flex h-16 items-center justify-between border-b bg-card px-6">
      <div />
      <div className="flex items-center gap-4">
        <button
          aria-label="Notifications"
          className="rounded-md p-2 hover:bg-accent"
        >
          <Bell className="h-5 w-5" />
        </button>
        <button
          aria-label="Toggle theme"
          onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
          className="rounded-md p-2 hover:bg-accent"
        >
          {theme === 'dark' ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
        </button>
      </div>
    </header>
  )
}
"""


# ─── HOOKS ────────────────────────────────────────────────────────────────────

def get_use_debounce() -> str:
    return """\
import { useEffect, useState } from 'react'

export function useDebounce<T>(value: T, delay = 300): T {
  const [debouncedValue, setDebouncedValue] = useState<T>(value)

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])

  return debouncedValue
}
"""


def get_use_local_storage() -> str:
    return """\
import { useState } from 'react'

export function useLocalStorage<T>(key: string, initialValue: T) {
  const [storedValue, setStoredValue] = useState<T>(() => {
    if (typeof window === 'undefined') return initialValue
    try {
      const item = window.localStorage.getItem(key)
      return item ? (JSON.parse(item) as T) : initialValue
    } catch {
      return initialValue
    }
  })

  const setValue = (value: T | ((val: T) => T)) => {
    try {
      const valueToStore = value instanceof Function ? value(storedValue) : value
      setStoredValue(valueToStore)
      if (typeof window !== 'undefined') {
        window.localStorage.setItem(key, JSON.stringify(valueToStore))
      }
    } catch (error) {
      console.error(error)
    }
  }

  return [storedValue, setValue] as const
}
"""


def get_use_media_query() -> str:
    return """\
import { useEffect, useState } from 'react'

export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(false)

  useEffect(() => {
    const media = window.matchMedia(query)
    setMatches(media.matches)
    const listener = (e: MediaQueryListEvent) => setMatches(e.matches)
    media.addEventListener('change', listener)
    return () => media.removeEventListener('change', listener)
  }, [query])

  return matches
}
"""


# ─── CONFIG ───────────────────────────────────────────────────────────────────

def get_app_config(project_name: str) -> str:
    return f"""\
export const appConfig = {{
  name: '{project_name}',
  description: 'Enterprise-grade Next.js application',
  version: '0.1.0',
  author: '',
  url: process.env.NEXT_PUBLIC_APP_URL ?? 'http://localhost:3000',
}}
"""


def get_nav_config() -> str:
    return """\
import type { LucideIcon } from 'lucide-react'
import { LayoutDashboard, Users, Settings } from 'lucide-react'

import { ROUTES } from '@/lib/constants'

export interface NavItem {
  href: string
  label: string
  icon: LucideIcon
  roles?: string[]
}

export const mainNav: NavItem[] = [
  { href: ROUTES.DASHBOARD, label: 'Dashboard', icon: LayoutDashboard },
  { href: ROUTES.USERS, label: 'Users', icon: Users, roles: ['admin'] },
  { href: ROUTES.SETTINGS, label: 'Settings', icon: Settings },
]
"""


# ─── STORE ────────────────────────────────────────────────────────────────────

def get_store_index() -> str:
    return """\
export { useAuthStore } from '@/features/auth/store/auth.store'
export { useUiStore } from './ui.store'
"""


def get_ui_store() -> str:
    return """\
import { create } from 'zustand'

interface UiState {
  sidebarOpen: boolean
  toggleSidebar: () => void
  setSidebarOpen: (open: boolean) => void
}

export const useUiStore = create<UiState>((set) => ({
  sidebarOpen: true,
  toggleSidebar: () => set((state) => ({ sidebarOpen: !state.sidebarOpen })),
  setSidebarOpen: (open) => set({ sidebarOpen: open }),
}))
"""


# ─── FEATURES ─────────────────────────────────────────────────────────────────

def get_auth_types() -> str:
    return """\
export interface AuthUser {
  id: string
  email: string
  name: string
  role: UserRole
  avatar?: string
}

export type UserRole = 'admin' | 'manager' | 'user'

export interface LoginCredentials {
  email: string
  password: string
}

export interface AuthTokens {
  accessToken: string
  refreshToken: string
  expiresIn: number
}

export interface AuthResponse {
  user: AuthUser
  tokens: AuthTokens
}
"""


def get_auth_schema() -> str:
    return """\
import { z } from 'zod'

import { emailSchema, passwordSchema } from '@/lib/validations'

export const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1, 'Password is required'),
})

export const registerSchema = z.object({
  name: z.string().min(2, 'Name must be at least 2 characters'),
  email: emailSchema,
  password: passwordSchema,
  confirmPassword: z.string(),
}).refine((data) => data.password === data.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
})

export type LoginInput = z.infer<typeof loginSchema>
export type RegisterInput = z.infer<typeof registerSchema>
"""


def get_auth_service() -> str:
    return """\
import { post } from '@/lib/api/client'

import type { AuthResponse, LoginCredentials } from '../types/auth.types'

export const authService = {
  async login(credentials: LoginCredentials): Promise<AuthResponse> {
    return post<AuthResponse>('/auth/login', credentials)
  },

  async logout(): Promise<void> {
    return post('/auth/logout')
  },

  async refreshToken(refreshToken: string): Promise<Pick<AuthResponse, 'tokens'>> {
    return post('/auth/refresh', { refreshToken })
  },

  async me(): Promise<AuthResponse['user']> {
    return post('/auth/me')
  },
}
"""


def get_auth_store() -> str:
    return """\
import { create } from 'zustand'
import { persist } from 'zustand/middleware'

import type { AuthUser } from '../types/auth.types'

interface AuthState {
  user: AuthUser | null
  accessToken: string | null
  isAuthenticated: boolean
  setUser: (user: AuthUser, token: string) => void
  clearAuth: () => void
}

export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      user: null,
      accessToken: null,
      isAuthenticated: false,
      setUser: (user, accessToken) => set({ user, accessToken, isAuthenticated: true }),
      clearAuth: () => set({ user: null, accessToken: null, isAuthenticated: false }),
    }),
    {
      name: 'auth-storage',
      partialize: (state) => ({ accessToken: state.accessToken }),
    }
  )
)
"""


def get_auth_hook() -> str:
    return """\
'use client'

import { useMutation } from '@tanstack/react-query'
import { useRouter } from 'next/navigation'
import { toast } from 'sonner'

import { ROUTES } from '@/lib/constants'

import { authService } from '../services/auth.service'
import { useAuthStore } from '../store/auth.store'
import type { LoginCredentials } from '../types/auth.types'

export function useAuth() {
  const router = useRouter()
  const { setUser, clearAuth, user, isAuthenticated } = useAuthStore()

  const loginMutation = useMutation({
    mutationFn: (credentials: LoginCredentials) => authService.login(credentials),
    onSuccess: ({ user, tokens }) => {
      setUser(user, tokens.accessToken)
      toast.success(`Welcome back, ${user.name}!`)
      router.push(ROUTES.DASHBOARD)
    },
    onError: (error: Error) => {
      toast.error(error.message)
    },
  })

  const logoutMutation = useMutation({
    mutationFn: authService.logout,
    onSuccess: () => {
      clearAuth()
      router.push(ROUTES.LOGIN)
    },
  })

  return {
    user,
    isAuthenticated,
    login: loginMutation.mutate,
    logout: logoutMutation.mutate,
    isLoggingIn: loginMutation.isPending,
    isLoggingOut: logoutMutation.isPending,
  }
}
"""


def get_login_form() -> str:
    return """\
'use client'

import { zodResolver } from '@hookform/resolvers/zod'
import { useForm } from 'react-hook-form'

import { useAuth } from '../hooks/use-auth'
import { loginSchema, type LoginInput } from '../schemas/auth.schema'

export function LoginForm() {
  const { login, isLoggingIn } = useAuth()

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LoginInput>({ resolver: zodResolver(loginSchema) })

  return (
    <form onSubmit={handleSubmit((data) => login(data))} className="space-y-4" noValidate>
      <div>
        <label htmlFor="email" className="block text-sm font-medium">
          Email
        </label>
        <input
          id="email"
          type="email"
          autoComplete="email"
          {...register('email')}
          className="mt-1 block w-full rounded-md border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
        />
        {errors.email && (
          <p role="alert" className="mt-1 text-xs text-destructive">
            {errors.email.message}
          </p>
        )}
      </div>

      <div>
        <label htmlFor="password" className="block text-sm font-medium">
          Password
        </label>
        <input
          id="password"
          type="password"
          autoComplete="current-password"
          {...register('password')}
          className="mt-1 block w-full rounded-md border px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
        />
        {errors.password && (
          <p role="alert" className="mt-1 text-xs text-destructive">
            {errors.password.message}
          </p>
        )}
      </div>

      <button
        type="submit"
        disabled={isLoggingIn}
        className="w-full rounded-md bg-primary py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
      >
        {isLoggingIn ? 'Signing in...' : 'Sign in'}
      </button>
    </form>
  )
}
"""


def get_users_types() -> str:
    return """\
export interface User {
  id: string
  name: string
  email: string
  role: string
  status: 'active' | 'inactive'
  createdAt: string
  updatedAt: string
}

export interface CreateUserInput {
  name: string
  email: string
  role: string
}

export interface UpdateUserInput extends Partial<CreateUserInput> {
  status?: User['status']
}
"""


def get_users_schema() -> str:
    return """\
import { z } from 'zod'

import { emailSchema } from '@/lib/validations'

export const createUserSchema = z.object({
  name: z.string().min(2, 'Name must be at least 2 characters'),
  email: emailSchema,
  role: z.enum(['admin', 'manager', 'user']),
})

export const updateUserSchema = createUserSchema.partial().extend({
  status: z.enum(['active', 'inactive']).optional(),
})

export type CreateUserInput = z.infer<typeof createUserSchema>
export type UpdateUserInput = z.infer<typeof updateUserSchema>
"""


def get_users_api() -> str:
    return """\
import { del, get, patch, post } from '@/lib/api/client'

import type { CreateUserInput, UpdateUserInput, User } from '../types/users.types'

const BASE = '/users'

export const usersApi = {
  getAll: (params?: PaginationParams) =>
    get<PaginatedResponse<User>>(BASE, { params }),

  getById: (id: string) => get<User>(`${BASE}/${id}`),

  create: (input: CreateUserInput) => post<User>(BASE, input),

  update: (id: string, input: UpdateUserInput) => patch<User>(`${BASE}/${id}`, input),

  remove: (id: string) => del<void>(`${BASE}/${id}`),
}
"""


def get_users_hook() -> str:
    return """\
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'

import { QUERY_KEYS } from '@/lib/constants'

import { usersApi } from '../api/users.api'
import type { CreateUserInput, UpdateUserInput } from '../schemas/users.schema'

export function useUsers(params?: PaginationParams) {
  return useQuery({
    queryKey: [...QUERY_KEYS.USERS, params],
    queryFn: () => usersApi.getAll(params),
  })
}

export function useUser(id: string) {
  return useQuery({
    queryKey: QUERY_KEYS.USER(id),
    queryFn: () => usersApi.getById(id),
    enabled: !!id,
  })
}

export function useCreateUser() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateUserInput) => usersApi.create(input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.USERS })
      toast.success('User created successfully')
    },
    onError: (error: Error) => toast.error(error.message),
  })
}

export function useUpdateUser() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, input }: { id: string; input: UpdateUserInput }) =>
      usersApi.update(id, input),
    onSuccess: (_, { id }) => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.USER(id) })
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.USERS })
      toast.success('User updated successfully')
    },
    onError: (error: Error) => toast.error(error.message),
  })
}

export function useDeleteUser() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: usersApi.remove,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: QUERY_KEYS.USERS })
      toast.success('User deleted successfully')
    },
    onError: (error: Error) => toast.error(error.message),
  })
}
"""


def get_dashboard_stats_component() -> str:
    return """\
import { Users, TrendingUp, Activity, DollarSign } from 'lucide-react'

const stats = [
  { label: 'Total Users', value: '—', icon: Users, delta: '+0%' },
  { label: 'Revenue', value: '—', icon: DollarSign, delta: '+0%' },
  { label: 'Active Sessions', value: '—', icon: Activity, delta: '+0%' },
  { label: 'Growth', value: '—', icon: TrendingUp, delta: '+0%' },
]

export function DashboardStats() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {stats.map(({ label, value, icon: Icon, delta }) => (
        <div key={label} className="rounded-lg border bg-card p-6">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium text-muted-foreground">{label}</p>
            <Icon className="h-4 w-4 text-muted-foreground" />
          </div>
          <p className="mt-2 text-3xl font-bold">{value}</p>
          <p className="mt-1 text-xs text-muted-foreground">{delta} from last month</p>
        </div>
      ))}
    </div>
  )
}
"""


def get_settings_types() -> str:
    return """\
export interface AppSettings {
  theme: 'light' | 'dark' | 'system'
  language: string
  notifications: NotificationSettings
}

export interface NotificationSettings {
  email: boolean
  push: boolean
  marketing: boolean
}
"""


# ─── DOCKER ───────────────────────────────────────────────────────────────────

def get_dockerfile() -> str:
    return """\
# Stage 1: Install dependencies
FROM node:20-alpine AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci

# Stage 2: Build the application
FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# Stage 3: Production runtime (minimal image)
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs && \\
    adduser  --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static   ./.next/static

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
"""


def get_jenkinsfile(org: str = "myproject") -> str:
    """Jenkinsfile del frontend: calidad + build Docker + push Gitea registry + ArgoCD (K3s).

    El frontend se despliega como pod en K3s con Ingress Traefik.
    Jenkins hace CI (build, test, imagen Docker) y escribe el nuevo tag en Git
    (bumpImageTag). ArgoCD hace CD sincronizando el Helm chart del frontend.
    """
    lib_org = "".join(c for c in org.lower() if c.isascii() and c.isalnum()) or "myproject"
    template = """\
@Library('jenkins-shared-library@main') _

// ───────────────────────────────────────────────────────────────────────────
// Jenkinsfile (frontend Next.js) — build Docker + push Gitea Package Registry
// + bumpImageTag → ArgoCD despliega como pod K3s con Ingress Traefik.
//
// Modelo de agentes: Kubernetes plugin. Corre en un pod efímero (K3s VPS en
// dev, EKS en staging/prod) con contenedores 'node' y 'kaniko' (definidos en
// org/__LIB_ORG__/podFrontend.yaml de la Shared Library).
// ───────────────────────────────────────────────────────────────────────────

pipeline {
    agent {
        kubernetes {
            defaultContainer 'node'
            yaml libraryResource('org/__LIB_ORG__/podFrontend.yaml')
        }
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        string(
            name: 'SERVICE_NAME',
            defaultValue: 'frontend',
            description: 'Nombre del repo frontend (deriva el repo en Gitea Package Registry).'
        )
        choice(
            name: 'DEPLOY_ENV',
            choices: ['dev', 'staging', 'prod'],
            description: 'Ambiente destino del despliegue.'
        )
    }

    environment {
        SERVICE_NAME = "${params.SERVICE_NAME}"
        DEPLOY_ENV   = "${params.DEPLOY_ENV}"
        IMAGE_REPO   = "${params.SERVICE_NAME}"
        K8S_NAMESPACE = "${params.DEPLOY_ENV}"
    }

    stages {
        // 1 — Checkout + IMAGE_TAG inmutable.
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    def version = sh(script: "cat package.json | grep '\"version\"' | cut -d'\"' -f4", returnStdout: true).trim()
                    def sha = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${version}-${sha}"
                    echo "IMAGE_TAG=${env.IMAGE_TAG}"
                }
            }
        }

        // 2 — Install.
        stage('Install') { steps { sh 'npm ci' } }

        // 3 — Type Check.
        stage('Type Check') { steps { sh 'npm run type-check' } }

        // 4 — Lint.
        stage('Lint') { steps { sh 'npm run lint' } }

        // 5 — Unit Tests (Vitest).
        stage('Unit Tests') { steps { sh 'npm run test' } }

        // 6 — Build Next.js (standalone para Docker).
        stage('Build') {
            steps { sh 'npm run build' }
        }

        // 7 — Imagen Docker multi-stage vía Kaniko → push a Gitea Package Registry.
        stage('Build & Push Image') {
            steps {
                buildAndPushImage(
                    service:   env.SERVICE_NAME,
                    imageRepo: env.IMAGE_REPO,
                    imageTag:  env.IMAGE_TAG
                )
            }
        }

        // 8 — Escaneo de imagen (Trivy). Falla ante CVE crítico.
        stage('Image Scan (Trivy)') {
            steps { scanImage(imageRepo: env.IMAGE_REPO, imageTag: env.IMAGE_TAG) }
        }

        // 9 — Frontera CI → CD: escribe image.repository/tag en
        //     terraform/frontend/environments/<env>/values.yaml y commitea (GitOps).
        //     ArgoCD detecta el commit y actualiza el pod K3s.
        stage('Update GitOps (image tag)') {
            steps {
                bumpImageTag(
                    service:  env.SERVICE_NAME,
                    env:      env.DEPLOY_ENV,
                    imageTag: env.IMAGE_TAG
                )
            }
        }

        // 10 — E2E (Playwright) contra la URL del pod K3s tras el sync de ArgoCD.
        stage('E2E Tests') {
            when { expression { params.DEPLOY_ENV != 'prod' } }
            steps {
                sh 'npx playwright install --with-deps'
                sh "PLAYWRIGHT_TEST_BASE_URL=${K8S_FRONTEND_URL:-http://localhost:3000} npm run test:e2e"
            }
        }
    }

    post {
        success { notify(status: 'SUCCESS', service: 'frontend', env: params.DEPLOY_ENV) }
        failure { notify(status: 'FAILURE', service: 'frontend', env: params.DEPLOY_ENV) }
    }
}
"""
    return template.replace("__LIB_ORG__", lib_org)


def get_vercel_json() -> str:
    """vercel.json con la Git integration DESACTIVADA.

    Garantiza que el único disparador de despliegues sea Jenkins (deploy vía
    Vercel CLI).
    """
    return """\
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "framework": "nextjs",
  "git": {
    "deploymentEnabled": false
  }
}
"""


def get_dockerignore() -> str:
    return """\
node_modules
.next
out
coverage

.env
.env*.local

.git
.gitignore
.husky

Dockerfile
.dockerignore
docker-compose*.yml

*.test.ts
*.test.tsx
*.spec.ts
*.spec.tsx

README.md
"""



# ─── TESTS ────────────────────────────────────────────────────────────────────

def get_vitest_config() -> str:
    return """\
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import { resolve } from 'path'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/tests/setup.ts'],
    globals: true,
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
})
"""


def get_test_setup() -> str:
    return """\
import '@testing-library/jest-dom'
"""


def get_utils_test() -> str:
    return """\
import { describe, it, expect } from 'vitest'

import { capitalize, truncate, cn } from '@/lib/utils'

describe('utils', () => {
  describe('capitalize', () => {
    it('capitalizes the first letter', () => {
      expect(capitalize('hello')).toBe('Hello')
    })
  })

  describe('truncate', () => {
    it('truncates long strings', () => {
      expect(truncate('hello world', 5)).toBe('hello...')
    })

    it('does not truncate short strings', () => {
      expect(truncate('hi', 5)).toBe('hi')
    })
  })

  describe('cn', () => {
    it('merges class names', () => {
      expect(cn('foo', 'bar')).toBe('foo bar')
    })
  })
})
"""


# ─── SCAFFOLD ORCHESTRATOR ────────────────────────────────────────────────────

def scaffold(project_name: str, org: str = "myproject") -> None:
    root = Path(project_name)
    logger.info("Creando arquetipo Next.js: %s", project_name)

    files: dict[str, str] = {
        # Root config
        "package.json": get_package_json(project_name),
        "tsconfig.json": get_tsconfig(),
        "next.config.ts": get_next_config(),
        "tailwind.config.ts": get_tailwind_config(),
        "postcss.config.js": get_postcss_config(),
        "eslint.config.mjs": get_eslint_config(),
        ".prettierrc": get_prettier_config(),
        ".prettierignore": get_prettier_ignore(),
        ".lintstagedrc.json": get_lintstaged_config(),
        ".gitignore": get_gitignore(),
        ".env.local": get_env_local(project_name),
        ".env.example": get_env_example(project_name),
        "components.json": get_components_json(),
        "vitest.config.ts": get_vitest_config(),
        ".husky/pre-commit": get_husky_pre_commit(),
        "Dockerfile": get_dockerfile(),
        ".dockerignore": get_dockerignore(),
        "Jenkinsfile": get_jenkinsfile(org),

        # Middleware (Next.js root)
        "src/middleware.ts": get_middleware(),

        # Styles
        "src/styles/globals.css": get_globals_css(),

        # Types
        "src/types/global.d.ts": get_global_types(),
        "src/types/api.types.ts": get_api_types(),

        # App layer
        "src/app/layout.tsx": get_root_layout(project_name),
        "src/app/loading.tsx": get_root_loading(),
        "src/app/error.tsx": get_root_error(),
        "src/app/not-found.tsx": get_not_found(),
        "src/app/(public)/page.tsx": get_public_page(),
        "src/app/(public)/login/page.tsx": get_public_login_page(),
        "src/app/(protected)/layout.tsx": get_protected_layout(),
        "src/app/(protected)/dashboard/page.tsx": get_dashboard_page(),
        "src/app/api/health/route.ts": get_api_health_route(),

        # Lib
        "src/lib/utils/index.ts": get_lib_utils(),
        "src/lib/env/index.ts": get_lib_env(),
        "src/lib/constants/index.ts": get_lib_constants(),
        "src/lib/validations/common.ts": get_lib_validations(),
        "src/lib/validations/index.ts": "export { emailSchema, passwordSchema, paginationSchema, idSchema } from './common'\n",
        "src/lib/api/client.ts": get_lib_api_client(),
        "src/lib/api/interceptors.ts": get_lib_api_interceptors(),
        "src/lib/api/error-handler.ts": get_lib_api_error_handler(),
        "src/lib/api/types.ts": get_lib_api_types(),

        # Providers
        "src/providers/index.tsx": get_providers_index(),
        "src/providers/query-provider.tsx": get_query_provider(),
        "src/providers/theme-provider.tsx": get_theme_provider(),
        "src/providers/auth-provider.tsx": get_auth_provider(),
        "src/providers/toast-provider.tsx": get_toast_provider(),

        # Hooks
        "src/hooks/use-debounce.ts": get_use_debounce(),
        "src/hooks/use-local-storage.ts": get_use_local_storage(),
        "src/hooks/use-media-query.ts": get_use_media_query(),

        # Config
        "src/config/app.config.ts": get_app_config(project_name),
        "src/config/nav.config.ts": get_nav_config(),

        # Store
        "src/store/index.ts": get_store_index(),
        "src/store/ui.store.ts": get_ui_store(),

        # Components
        "src/components/layouts/sidebar.tsx": get_sidebar(),
        "src/components/layouts/header.tsx": get_header(),

        # Features — auth
        "src/features/auth/types/auth.types.ts": get_auth_types(),
        "src/features/auth/schemas/auth.schema.ts": get_auth_schema(),
        "src/features/auth/services/auth.service.ts": get_auth_service(),
        "src/features/auth/store/auth.store.ts": get_auth_store(),
        "src/features/auth/hooks/use-auth.ts": get_auth_hook(),
        "src/features/auth/components/login-form.tsx": get_login_form(),

        # Features — users
        "src/features/users/types/users.types.ts": get_users_types(),
        "src/features/users/schemas/users.schema.ts": get_users_schema(),
        "src/features/users/api/users.api.ts": get_users_api(),
        "src/features/users/hooks/use-users.ts": get_users_hook(),

        # Features — dashboard
        "src/features/dashboard/components/dashboard-stats.tsx": get_dashboard_stats_component(),

        # Features — settings
        "src/features/settings/types/settings.types.ts": get_settings_types(),

        # Placeholder dirs (empty index files)
        "src/components/ui/.gitkeep": "",
        "src/components/shared/.gitkeep": "",
        "src/components/feedback/.gitkeep": "",
        "src/components/forms/.gitkeep": "",
        "src/services/.gitkeep": "",
        "src/lib/auth/.gitkeep": "",
        "src/lib/errors/.gitkeep": "",

        # Tests
        "src/tests/setup.ts": get_test_setup(),
        "src/tests/unit/lib/utils.test.ts": get_utils_test(),
    }

    total = len(files)
    logger.info("Archivos a generar: %d", total)

    for relative_path, content in files.items():
        file_path = root / relative_path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content, encoding="utf-8")
        logger.debug("Creado: %s", relative_path)

    logger.info("Arquetipo generado exitosamente en: %s", root.resolve())
    _setup_gitea_repo(project_name, root, org)
    _print_run_instructions(project_name, root)


def _setup_gitea_repo(project_name: str, root: Path, org: str = "myproject") -> None:
    import base64
    import json as _json
    import subprocess
    import urllib.error
    import urllib.request

    import os
    vps_ip = os.environ.get("VPS_IP", "")
    gitea_host = f"http://{vps_ip}:3000" if vps_ip else "http://localhost:3000"
    credentials = base64.b64encode(b"gitea-admin:gitea-admin").decode()

    try:
        urllib.request.urlopen(f"{gitea_host}/api/healthz", timeout=3)
    except Exception:
        logger.warning(
            "[Gitea] No activo en %s — crear el repo manualmente "
            "(VPS_IP=%s, base-infrastructure-builder.sh --vps-ip).", gitea_host, vps_ip or "no definido"
        )
        return

    payload = _json.dumps({
        "name": project_name,
        "private": True,
        "auto_init": False,
        "default_branch": "main",
    }).encode()
    req = urllib.request.Request(
        f"{gitea_host}/api/v1/orgs/{org}/repos",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Basic {credentials}"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        logger.info("[Gitea] Repo %s/%s creado.", org, project_name)
    except urllib.error.HTTPError as e:
        if e.code == 409:
            logger.info("[Gitea] Repo %s/%s ya existe.", org, project_name)
        elif e.code == 401:
            logger.warning(
                "[Gitea] HTTP 401: el usuario admin no existe. Correr "
                "base-infrastructure-builder.sh primero."
            )
            return
        else:
            logger.warning("[Gitea] No se pudo crear el repo: HTTP %s", e.code)
            return

    try:
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
        result = subprocess.run(["git", "config", "user.email"], cwd=root, capture_output=True)
        if result.returncode != 0:
            subprocess.run(["git", "config", "user.email", f"cicd@{org}.local"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", f"{org} CI"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", f"chore: scaffold {project_name}"], cwd=root, check=True)
        remote_url = f"{gitea_host}/{org}/{project_name}.git"
        subprocess.run(["git", "remote", "add", "origin", remote_url], cwd=root, check=False)
        logger.info("[Gitea] Remote 'origin' → %s", remote_url)
        logger.info("[Gitea] URL para Jenkins/ArgoCD: %s/%s/%s.git", gitea_host, org, project_name)
        # Auto-push con credenciales embebidas (sin guardarlas en .git/config).
        push_url = remote_url.replace("http://", "http://gitea-admin:gitea-admin@", 1)
        push = subprocess.run(
            ["git", "push", push_url, "main"], cwd=root, capture_output=True
        )
        if push.returncode == 0:
            logger.info("[Gitea] Push a %s/%s completado (rama main).", org, project_name)
        else:
            logger.info("[Gitea] Para publicar: cd %s && git push -u origin main", root)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logger.warning("[Gitea] No se pudo inicializar el repo git: %s", e)


def _print_run_instructions(project_name: str, root: Path) -> None:
    instructions = f"""
╔══════════════════════════════════════════════════════════════════════╗
║         Arquetipo Next.js listo: {project_name:<36}║
╚══════════════════════════════════════════════════════════════════════╝

 1. Entra al directorio del proyecto:
    cd {root}

 2. Instala las dependencias:
    npm install

 3. Configura las variables de entorno:
    # .env.local ya tiene defaults para desarrollo, edítalo si necesitas cambios
    # Para producción/staging consulta .env.example como referencia

 4. Configura Husky (git hooks):
    git init
    npx husky init

 5. Inicia el servidor de desarrollo:
    npm run dev

 7. Abre en el navegador:
    http://localhost:3000

────────────────────────────────────────────────────────────────────────
 Agregar componentes shadcn/ui (cuando los necesites):
    npx shadcn@latest add button input label card badge table
    # shadcn copia el código fuente a src/components/ui/ — no es una dep.
────────────────────────────────────────────────────────────────────────
 Comandos útiles:
    npm run type-check     → Verificar tipos TypeScript
    npm run lint           → Verificar reglas ESLint
    npm run format         → Formatear con Prettier
    npm test               → Ejecutar tests unitarios con Vitest
    npm run build          → Build de producción
────────────────────────────────────────────────────────────────────────
 Docker — Dockerizar la aplicación:

    # Construir la imagen
    docker build -t {project_name}:latest .

    # Ejecutar el contenedor
    docker run -d \\
      --name {project_name} \\
      -p 3000:3000 \\
      -e NEXT_PUBLIC_APP_URL=http://localhost:3000 \\
      -e NEXT_PUBLIC_API_URL=http://your-api-url/api/v1 \\
      {project_name}:latest

    # Ver logs
    docker logs -f {project_name}

    # Detener el contenedor
    docker stop {project_name} && docker rm {project_name}

  Notas importantes:
    · Las variables NEXT_PUBLIC_* se inyectan en build-time por Next.js.
      Si cambian sus valores, debes reconstruir la imagen.
    · Las variables sin NEXT_PUBLIC_ (secretos de servidor) puedes
      pasarlas con -e o con un archivo: --env-file .env.production
    · El Dockerfile usa 'output: standalone' (next.config.ts) para
      generar un bundle mínimo sin node_modules completos en producción.
────────────────────────────────────────────────────────────────────────
 Estructura generada:

  src/
  ├── app/           → App Router (layouts, pages, API routes)
  ├── components/    → Componentes reutilizables (ui, shared, layouts)
  ├── features/      → Módulos por dominio (auth, users, dashboard)
  ├── lib/           → Utilidades core (api, env, constants, utils)
  ├── hooks/         → Custom hooks globales
  ├── providers/     → Providers React globales
  ├── store/         → Estado global Zustand
  ├── config/        → Configuración de la app
  ├── types/         → Tipos globales TypeScript
  ├── styles/        → CSS global y variables de tema
  └── tests/         → Setup de testing y tests unitarios
────────────────────────────────────────────────────────────────────────
"""
    print(instructions)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="nextjs_feature_scaffold",
        description="Genera un arquetipo base Next.js con arquitectura Feature-Based enterprise.",
    )
    parser.add_argument(
        "-n", "--project-name",
        required=True,
        metavar="NAME",
        help="Nombre del proyecto (ej: my-saas-app)",
    )
    parser.add_argument(
        "--org",
        default="myproject",
        metavar="ORG",
        help="Slug del proyecto/organización. Se usa para la organización Gitea "
             "y el paquete de la Shared Library (org.<org>). Debe coincidir con el "
             "-P/--project usado en los scripts. (default: myproject)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Mostrar logs detallados (DEBUG)",
    )

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    try:
        scaffold(args.project_name, args.org)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
