# BENCH-7: Add rollback to order processing

## Problem

`orders.place_order()` calls `inventory.adjust_stock()` for each line item sequentially. If the Nth item fails (e.g., out of stock), items 1 through N-1 have already been decremented. There is no rollback, leaving inventory in an inconsistent state.

## Steps to Reproduce

1. Create products A (qty=10), B (qty=10), C (qty=2)
2. Place order with items: A(qty=5), B(qty=5), C(qty=5)
3. Item C fails (insufficient stock)
4. Check: A now has qty=5, B has qty=5 — both decremented with no order placed

## Expected Fix

- `place_order()` must be atomic: either ALL items succeed or NONE are decremented
- If any item fails, all previously decremented items must be rolled back
- The order status should remain "pending" (not "confirmed") on failure
- Add tests proving rollback works correctly

## Acceptance Criteria

- [ ] Partial order failure rolls back all previously decremented stock
- [ ] Order status remains "pending" on failure
- [ ] New test: multi-item order where last item fails, verify all stock restored
- [ ] All existing tests pass
