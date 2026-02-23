# Data Models

## Overview
<!-- TODO: Brief description of the data architecture -->

## Entity Relationship Diagram
<!-- ASCII or reference to diagram file -->

## Entities

### Entity 1
<!-- Repeat this block for each entity -->

| Field | Type | Required | Description | Constraints |
|-------|------|----------|-------------|-------------|
| id | | Yes | Primary key | |
| | | | | |

**Relationships:**
- Has many:
- Belongs to:

**Indexes:**
-

### Entity 2
<!-- Add more entities as needed -->

## Enums & Constants
<!-- Shared enumerations used across entities -->

| Enum | Values | Used By |
|------|--------|---------|
| | | |

## Data Validation Rules
<!-- Business-level validation beyond type constraints -->

## Migration Strategy
<!-- How schema changes are managed -->

## Seeding & Default Data
<!-- Initial data required for the application to function -->

## Data Retention & Archival
<!-- Policies for data lifecycle management -->

## Privacy & PII
<!-- Which fields contain personally identifiable information -->

| Entity | Field | PII Type | Encryption | Retention |
|--------|-------|----------|------------|-----------|
| | | | | |

## Indexing Strategy
<!-- Standard index types to consider for each entity -->

| Index | Columns | Type | Purpose |
|-------|---------|------|---------|
| Primary | id | B-tree | Lookups |
| Unique | email | B-tree | Constraint |
| Composite | (tenant_id, created_at) | B-tree | Filtered sort |
| Full-text | name, description | GIN/FTS | Search |

## Entity Template (Extended)

### Relationships
- **belongs_to:** parent entity (foreign key on this table)
- **has_many:** child entities (foreign key on child table)
- **many_to_many:** peer entities (join table required)

### Soft Delete Pattern
Use a `deleted_at` timestamp column instead of hard deletes:
- `NULL` = active record
- Timestamp = soft-deleted record
- Add default scope to exclude soft-deleted records
- Add index on `deleted_at` for filtered queries

### Audit Trail
Every entity should include:
- `created_at` (timestamp, set on insert, never modified)
- `updated_at` (timestamp, set on every update)
- `created_by` (user ID or system identifier)
- `updated_by` (user ID or system identifier)

## Common Query Patterns

### List with Pagination
```
SELECT * FROM entity
WHERE tenant_id = ?
ORDER BY created_at DESC
LIMIT ? OFFSET ?
```
Prefer cursor-based pagination (WHERE id < ?) for large datasets.

### Search with Filters
```
SELECT * FROM entity
WHERE tenant_id = ?
  AND status = ?
  AND name ILIKE ?
ORDER BY relevance DESC
```
Use full-text index for search fields, B-tree for filter fields.

### Aggregate Counts
```
SELECT status, COUNT(*) FROM entity
WHERE tenant_id = ?
GROUP BY status
```
Consider materialized views or counter caches for frequently accessed counts.

### Eager Loading Relationships
Always eager-load relationships to avoid N+1 queries:
- List views: include belongs_to references
- Detail views: include has_many collections
- Reports: use joins or subqueries, never loop queries

## Related Documents
- **Feeds into:** [API_SPEC.md](API_SPEC.md), [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)
- **Informed by:** [APP_FLOW.md](APP_FLOW.md)
