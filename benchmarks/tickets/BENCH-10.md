# BENCH-10: Refactor — extract Validator class, update all callers

## Problem

Input validation logic is scattered across multiple modules with no consistent pattern. As the codebase grows, each module reinvents validation differently (or skips it entirely). Extract a centralized `Validator` class and update all modules to use it.

## Expected Changes

1. Create `invtrack/validators.py` with a `Validator` class containing:
   - `validate_sku(sku: str) -> str` — validates format (3-letter prefix + dash + 3-digit number), returns cleaned SKU or raises ValueError
   - `validate_price(price: float) -> float` — ensures price >= 0
   - `validate_quantity(quantity: int) -> int` — ensures quantity >= 0
   - `validate_discount(percent: float) -> float` — clamps/validates 0-100 range
   - `validate_order_item(item: OrderItem)` — validates item fields

2. Update all callers:
   - `models.py`: use Validator in Product/OrderItem construction
   - `store.py`: validate on add_product()
   - `orders.py`: validate discount in apply_discount(), items in place_order()
   - `inventory.py`: validate quantity delta

3. Add comprehensive tests for the Validator class

## Acceptance Criteria

- [ ] `invtrack/validators.py` exists with Validator class
- [ ] At least 5 validation methods in Validator
- [ ] `models.py`, `store.py`, `orders.py`, and `inventory.py` all import and use Validator
- [ ] Tests for Validator class (at least 8 test functions)
- [ ] All existing tests pass
- [ ] No duplicate validation logic across modules
