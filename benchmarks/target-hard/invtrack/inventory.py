"""Stock management operations.

BUG 1 (mutation aliasing): adjust_stock() gets a product dict from store,
mutates it by adding a 'last_adjusted' field, and returns it. Because
store.get_product() returns the cache reference (not a copy), this mutation
corrupts the store's cache. The unwanted field gets persisted on next save().
"""
from datetime import datetime
from invtrack.store import ProductStore


def adjust_stock(store: ProductStore, sku: str, delta: int) -> dict:
    """Adjust stock quantity by delta (positive = add, negative = remove).

    Returns the updated product dict.
    """
    product = store.get_product(sku)
    if product is None:
        raise KeyError(f"Product not found: {sku}")

    new_qty = product["quantity"] + delta
    if new_qty < 0:
        raise ValueError(f"Insufficient stock for {sku}: have {product['quantity']}, need {abs(delta)}")

    store.update_product(sku, {"quantity": new_qty})

    # BUG: This mutates the cache dict directly because get_product()
    # returns a reference, not a copy. 'last_adjusted' gets persisted.
    product["last_adjusted"] = datetime.now().isoformat()
    return product


def get_stock_level(store: ProductStore, sku: str) -> int:
    product = store.get_product(sku)
    if product is None:
        raise KeyError(f"Product not found: {sku}")
    return product["quantity"]


def get_low_stock(store: ProductStore, threshold: int = 5) -> list[dict]:
    """Return products with quantity below threshold."""
    low = []
    for p in store.list_products(page=0, per_page=1000):
        if p.get("quantity", 0) < threshold:
            low.append(p)
    return low


def check_availability(store: ProductStore, sku: str, needed: int) -> bool:
    """Check if enough stock is available."""
    try:
        level = get_stock_level(store, sku)
        return level >= needed
    except KeyError:
        return False
