# Frontend Guidelines

## Overview
<!-- TODO: Frontend architecture philosophy and key patterns -->

## Design System
<!-- Design tokens, component library, theme -->

### Colors
<!-- Primary, secondary, semantic colors -->

### Typography
<!-- Font families, sizes, weights, line heights -->

### Spacing
<!-- Spacing scale and usage guidelines -->

## Component Architecture
<!-- Component hierarchy, naming conventions, file structure -->

### Component Categories
- **Layout Components:**
- **UI Components:**
- **Feature Components:**
- **Page Components:**

### Component Template
```
ComponentName/
  index.ts          # Public exports
  ComponentName.tsx # Main component
  ComponentName.test.tsx
  ComponentName.styles.ts
```

## State Management
<!-- Global state approach, when to use local vs global state -->

### State Categories

| Category | Scope | Examples | Tool |
|----------|-------|----------|------|
| UI State | Component | open/closed, selected tab | Local state |
| Form State | Form | field values, validation | Form library or local |
| Server State | Global | API responses, cached data | Data fetching library |
| URL State | Global | route params, query strings | Router |
| Global App State | Global | auth, theme, feature flags | State management library |

### Guidelines
- Prefer local state by default; lift to parent only when siblings need it
- Server state should use a cache-first approach with background revalidation
- URL state is the source of truth for anything that should survive a page refresh
- Avoid duplicating server state into global app state

## Routing
<!-- Route structure, guards, lazy loading -->

### Route Structure

| Route Type | Pattern | Guard |
|-----------|---------|-------|
| Public | `/login`, `/signup` | Redirect if authed |
| Protected | `/dashboard`, `/settings` | Redirect if not authed |
| Role-gated | `/admin/*` | Check role claim |
| Shared | `/`, `/about` | None |

### Guidelines
- Code-split each route for smaller initial bundle
- Provide a 404 fallback route at the end of the route config
- Show loading states during lazy route resolution
- Keep route definitions in a single file for discoverability

## Forms
<!-- Form library, validation approach, error display -->

### Architecture
- **Controlled inputs:** use when you need real-time validation or derived state
- **Uncontrolled inputs:** use for simple forms where you only need values on submit

### Validation Rules

| Rule | Client | Server | Example |
|------|--------|--------|---------|
| Required | Yes | Yes | "Field is required" |
| Format | Yes | Yes | Email, phone regex |
| Uniqueness | No | Yes | Username taken |
| Business logic | No | Yes | Insufficient balance |

### Guidelines
- Display errors inline below the relevant field
- Validate on blur for immediate feedback, on submit for full validation
- Debounce expensive validations (e.g., uniqueness checks) at 300-500ms
- Support optimistic submission where possible (disable button, show spinner)

## Accessibility (a11y)
<!-- WCAG level, keyboard navigation, screen reader requirements -->

- Minimum WCAG level:
- Keyboard navigation:
- ARIA patterns:
- Focus management:

## Responsive Design
<!-- Breakpoints, mobile-first approach -->

| Breakpoint | Width | Target |
|-----------|-------|--------|
| | | |

## Performance
<!-- Bundle size budget, lazy loading, image optimization -->

- Bundle size budget:
- Code splitting strategy:
- Image format:

## Error Handling
<!-- Error boundaries, user-facing error messages, fallback UI -->

### Error Categories

| Category | Example | Recovery |
|----------|---------|----------|
| Network | Timeout, offline | Retry with backoff |
| Auth | 401, 403 | Redirect to login |
| Validation | 422 | Show field errors |
| Server | 500 | Show fallback UI |
| Not Found | 404 | Show 404 page |

### Guidelines
- Use error boundaries to catch render errors and show fallback UI
- Implement a global error handler for unhandled promise rejections
- Show user-friendly messages; log technical details to the console or monitoring
- Never expose stack traces or internal error codes to the user

## Testing Strategy
<!-- Unit tests, integration tests, visual regression -->

### Testing Pyramid
- **Unit:** pure functions, utils, hooks (fast, high coverage)
- **Component:** render + interaction (medium speed, covers UI logic)
- **Integration:** page-level flows with mocked APIs (slower, covers wiring)
- **E2E:** critical user journeys only (slowest, covers real browser behavior)

### Visual Regression
- Capture screenshots on CI for key pages and components
- Set a diff threshold (e.g., 0.1%) to catch unintended changes
- Review visual diffs as part of the PR process

## Code Style & Linting

### Naming Conventions
- **Components:** PascalCase (`UserProfile`, `SearchBar`)
- **Hooks:** useCamelCase (`useAuth`, `useFetchData`)
- **Utilities:** camelCase (`formatDate`, `parseQuery`)
- **Constants:** UPPER_SNAKE_CASE (`MAX_RETRIES`, `API_BASE_URL`)
- **Files:** match the primary export (component files PascalCase, utility files camelCase)

### Import Ordering
1. External packages (framework, libraries)
2. Internal aliases (e.g., `@/components`, `@/utils`)
3. Relative imports (parent, sibling, child)
4. Style imports

### Guidelines
- Use consistent formatting enforced by a formatter (Prettier or equivalent)
- Enable strict linting rules and treat warnings as errors in CI

## CSS Architecture

### Methodology
Choose one and apply consistently: BEM, CSS Modules, or utility-first (e.g., Tailwind).

### Responsive Breakpoints

| Name | Width | Target |
|------|-------|--------|
| sm | 640px | Mobile landscape |
| md | 768px | Tablet |
| lg | 1024px | Desktop |
| xl | 1280px | Large desktop |

### Z-Index Scale
Use a fixed scale to avoid z-index wars:

| Layer | Z-Index | Usage |
|-------|---------|-------|
| Base | 0 | Default content |
| Dropdown | 100 | Menus, popovers |
| Sticky | 200 | Sticky headers |
| Overlay | 300 | Modals backdrop |
| Modal | 400 | Modal content |
| Toast | 500 | Notifications |

### Spacing Scale
Use a consistent spacing scale (e.g., 4px base): 0, 1 (4px), 2 (8px), 3 (12px), 4 (16px), 6 (24px), 8 (32px), 12 (48px), 16 (64px).

## Internationalization (i18n)

### Guidelines
- Externalize all user-facing strings into translation files
- Never concatenate strings for translated text (use interpolation)
- Format dates, numbers, and currencies using locale-aware formatters
- Support RTL layouts if targeting RTL languages
- Keep translation keys descriptive: `auth.login.submitButton` not `btn1`

## Related Documents
- **Feeds into:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)
- **Informed by:** [APP_FLOW.md](APP_FLOW.md)
