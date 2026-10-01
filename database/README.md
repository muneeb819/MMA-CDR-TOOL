# MBPW Database

Full schema + objects for **MMA Business Prosperity Weapon**, reverse-engineered
from the FastAPI/SQLAlchemy backend of
<https://github.com/muneeb819/MMA-Business-Prosperity-Weapon>.

| File | Target | Contents |
|---|---|---|
| `mbpw_postgres.sql` | PostgreSQL 13+ | 38 tables, 99 indexes, 6 triggers, 10 views, 9 functions, seed data, grants |
| `mbpw_sqlite.sql` | SQLite 3 (local dev) | 17 tables, 24 indexes, seed data — byte-exact `create_all()` output |

## Run

```bash
# PostgreSQL (psql required: uses \gexec / \connect / \set)
psql -U postgres -f database/mbpw_postgres.sql

# SQLite
sqlite3 mbpw.db < database/mbpw_sqlite.sql
```

Then point the backend at it:

```bash
export DATABASE_URL=postgresql://mbpw_app:<password>@localhost:5432/mbpw
```

`backend/app/models/database.py` resolves the URL in this order:
`DATABASE_URL` → `POSTGRES_URL_NON_POOLING` → `POSTGRES_URL` → `POSTGRES_PRISMA_URL`
→ fallback `sqlite://` (ephemeral in-memory).

## The 17 application tables

Declared across two files in the source repo:

| Source file | Tables |
|---|---|
| `backend/app/models/schema.py` | `leads`, `proposals`, `companies`, `contacts`, `notifications`, `connectors`, `agent_logs`, `outreach`, `outreach_states`, `knowledge_base`, `app_config`, `contact_intel`, `provider_performance`, `outreach_feedback` |
| `backend/app/routers/auth.py` | `users`, `sessions`, `audit_logs` |

The PostgreSQL file adds 21 `ref_*` lookup tables documenting the vocabularies
that the app hard-codes in Python (lead stages, ACIE lifecycle, feedback
outcomes, the 17 registered lead sources, the 4-step outreach cadence, …).

## Design decisions you should know about

**No foreign keys, no CHECK constraints by default — deliberate.**
The models mark every relationship `# FK handled at app level`, and the routers
genuinely write dangling values:

- `routers/proposals.py` writes `lead_id = ''` when `POST /api/proposals/generate`
  is called with `leadData` instead of `leadId`.
- `routers/crm.py` echoes a client-supplied `companyId` into
  `contacts.company_id` without validating it.

Adding hard constraints turns those paths into HTTP 500s. Section 13 of the
PostgreSQL file ships the constraints as an opt-in block — enable them after
cleaning your data.

**JSON columns are `jsonb`, not `json`.**
The models ask for `JSON`. `jsonb` is a drop-in superset: SQLAlchemy serialises
the Python value to JSON text and PostgreSQL coerces the unknown-typed parameter.
You additionally get GIN indexes and `@>` containment. Change every `jsonb` to
`json` if you need byte-identical `create_all()` output.

**No server-side defaults are relied upon by the app.**
None of the models declare `server_default`, so SQLAlchemy always sends an
explicit value for every column. The `DEFAULT` clauses in the DDL exist for
hand-written SQL and tooling.

**All timestamps are `TIMESTAMP WITHOUT TIME ZONE`** because the app writes naive
`datetime.utcnow()` everywhere, and the database timezone is pinned to UTC.

## Reporting objects

Views that reproduce what the Python routers compute:

| View / function | Mirrors |
|---|---|
| `v_lead_pipeline` | lead + proposal + cadence state + ACIE decision in one row |
| `v_system_stats` | `GET /api/admin/system/stats` |
| `v_pipeline_report` | `GET /api/reports/pipeline` |
| `v_platform_breakdown`, `v_country_breakdown`, `v_technology_breakdown` | `GET /api/analytics/*` |
| `v_monthly_revenue` | `GET /api/analytics/revenue` |
| `v_agent_performance` | `GET /api/analytics/agents` |
| `v_outreach_queue` | the work list `GET /api/outreach/cron` will process |
| `v_outreach_performance` | send/reply effectiveness by cadence step |
| `mbpw_compliance_gate(lead_id)` | `services/acie/compliance.py:gate_status` |
| `mbpw_can_send(lead_id)` | `services/acie/compliance.py:can_send` |
| `mbpw_compute_next_due(lead_id)` | `services/outreach_automation.py:compute_next_due` |
| `mbpw_provider_reliability(p)` | `services/acie/learn.py:provider_reliability` |
| `mbpw_confidence_tier(score)` | `services/acie/constants.py` thresholds |
| `mbpw_email_syntax_ok(email)` | `services/outreach_service.py:is_email_deliverable` (syntax only — no MX lookup) |

## Known upstream issue this schema surfaces

`Lead.technologies.any(tech)` in `routers/leads.py` and `routers/search.py`, and
`KnowledgeEntry.tags.any(tag)` in `routers/knowledge.py`, raise
`AttributeError: ... has no attribute 'any'` under SQLAlchemy 2.x for a JSON
column on PostgreSQL. `leads.py` swallows the exception with a Python-side
fallback; `search.py` and `knowledge.py` do not, so those endpoints 500 when the
filter is supplied.

`v_technology_breakdown` is the SQL replacement:

```sql
SELECT * FROM v_technology_breakdown WHERE technology = 'react';
-- or directly:
SELECT id FROM leads WHERE technologies @> '["react"]'::jsonb;
```

## First superadmin

The app never creates default credentials — `models/seed.py` requires
`ADMIN_INITIAL_PASSWORD`. Either start the API with that variable set, or insert
the row yourself with a passlib bcrypt digest (see Section 11.6 of the
PostgreSQL file).
