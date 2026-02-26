# BENCH-9: Security audit — fix all input validation gaps

## Problem

The codebase has multiple input validation gaps that could cause incorrect behavior or exploitable conditions:

1. **Unvalidated discount** (`orders.py`): `apply_discount()` accepts any float — negative values increase price, values >100 create negative totals
2. **No SKU format validation**: Products can be created with any string as SKU, violating the project convention (3-letter prefix + dash + 3-digit number)
3. **No price validation**: Negative prices are accepted
4. **No quantity validation on order items**: Zero or negative quantities are not checked

## Expected Fix

Perform a systematic audit of ALL 6 modules and fix ALL input validation gaps:

- `apply_discount()`: clamp percent to 0-100, raise ValueError for out-of-range
- Add SKU format validation in `Product.__post_init__()` or `store.add_product()`
- Add price >= 0 validation
- Add order item quantity > 0 validation
- Add appropriate error messages for each validation

## Acceptance Criteria

- [ ] `apply_discount()` rejects percent < 0 or > 100
- [ ] Invalid SKU format raises ValueError
- [ ] Negative prices rejected
- [ ] Zero/negative order item quantities rejected
- [ ] Tests for each validation rule
- [ ] All existing tests pass
