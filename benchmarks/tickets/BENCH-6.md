# BENCH-6: Fix mutation aliasing bug in store/inventory

## Problem

`ProductStore.get_product()` returns a direct reference to the internal cache dict instead of a copy. When `inventory.adjust_stock()` is called, it adds a `last_adjusted` field to the returned dict, which corrupts the store's cache. On the next `save()`, the unwanted field gets persisted to the JSON file.

## Steps to Reproduce

1. Create a store with product SKU "WDG-001"
2. Call `adjust_stock(store, "WDG-001", 10)`
3. Call `store.save()`
4. Reload the store from disk
5. Check product data: it now contains an unwanted `last_adjusted` field

## Root Cause

`store.py:get_product()` returns `self._cache.get(sku)` — the actual cache dict, not a copy. `inventory.py:adjust_stock()` then mutates this dict by setting `product["last_adjusted"]`.

## Expected Fix

- `store.get_product()` must return a copy (e.g., `dict(self._cache[sku])` or `copy.deepcopy`)
- OR `inventory.adjust_stock()` must not mutate the returned dict
- After fix: persisted JSON must never contain `last_adjusted` field
- All existing tests must continue to pass
- Add a test that verifies cache isolation (mutating returned dict does not affect store)

## Acceptance Criteria

- [ ] `get_product()` returns a copy, not a reference
- [ ] Persisted JSON never contains `last_adjusted`
- [ ] New test proves cache mutation isolation
- [ ] All existing tests pass
