# LocalHub architecture

LocalHub is designed as a modular TypeScript monorepo with React Native/Expo as the primary mobile client, Next.js modules for web/admin dashboards, a modular REST API, PostgreSQL/Prisma as the long-term relational system of record, object storage for media, a Redis/Valkey-compatible queue layer for background jobs, and provider abstractions for maps, payments, messaging and AI.

## Live deployment note

The AppDeploy environment used for this live build provides managed app persistence and realtime primitives. The deployed vertical slice uses those primitives so the demo is genuinely functional. The checked-in `prisma/schema.prisma` is the migration-ready relational model for the production PostgreSQL deployment described by the product specification.

## Core bounded modules

auth, users, locations, catalog, stores, marketplace, cart, orders, payments, services, bookings, delivery, chat, reviews, verification, notifications, commissions, AI and admin.

## State integrity

Order and booking transitions are server-owned. Client input is treated as untrusted. Prices are read server-side before order creation. Payment providers must use idempotency keys and webhooks in production.

## Location/privacy

Store public service areas and approximate distance. Never expose private customer addresses to public listings. Location permissions are opt-in and user-controlled.

## AI safety

The AI layer receives platform data and is forbidden from inventing inventory, prices, workers or transaction completion. Transactional actions require explicit user confirmation outside the AI response.

## Scaling path

Start modular. Extract search, notifications, payments, delivery, chat and AI into independent services only when operational metrics justify it.