# BENCH-8: Fix pagination off-by-one bug

## Problem

`ProductStore.list_products()` uses 0-indexed pages internally. The CLI (`cli.py:list_cmd()`) passes the user's 1-indexed `--page` argument directly without converting. When a user requests `--page 1`, they get the second page of results (page index 1), skipping the first page entirely.

## Steps to Reproduce

1. Add 15 products to the store
2. Run: `invtrack list --page 1 --per-page 10`
3. Expected: products 1-10 (first page)
4. Actual: products 11-15 (second page) — first page skipped

## Root Cause

`cli.py:list_cmd()` passes `args.page` (1-indexed) directly to `store.list_products(page=args.page)`, but `list_products()` expects 0-indexed pages.

## Expected Fix

- Either convert in CLI: `store.list_products(page=args.page - 1, ...)`
- OR change `list_products()` to accept 1-indexed pages (and update all callers)
- Add pagination tests that verify page 1 returns the first page of results
- Test edge cases: page 0/negative, page beyond results

## Acceptance Criteria

- [ ] `--page 1` returns the first page of results
- [ ] New test: 15+ products, verify page 1 and page 2 return correct items
- [ ] All existing tests pass
