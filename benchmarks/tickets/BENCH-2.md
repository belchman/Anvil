# BENCH-2: Add search feature

## Requirements

Add the ability to search tasks by title substring (case-insensitive).

### API

Add `TaskStore.search(query: str) -> list[dict]` that returns tasks whose title contains the query string (case-insensitive match).

### CLI

Add `tasktrack search <query>` subcommand that prints matching tasks in the same format as `list`.

## Acceptance Criteria

- [ ] `search()` method exists on TaskStore
- [ ] Case-insensitive matching works
- [ ] CLI `search` subcommand works
- [ ] At least one test for search functionality
