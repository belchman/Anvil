"""Reporting and CSV export.

BUG 4 (stale import): This module imports Product from models.py but also has
a leftover reference to store.Product in export_csv(). It works because store.py
imports Product from models (so store.Product resolves via the module's namespace),
but it breaks if store.py is refactored to stop importing Product.
"""
import csv
import io
from invtrack.models import Product
from invtrack import store as store_module


def inventory_summary(product_store) -> dict:
    """Generate a summary of current inventory."""
    all_products = product_store.list_products(page=0, per_page=10000)
    total_items = sum(p.get("quantity", 0) for p in all_products)
    total_value = sum(p.get("price", 0) * p.get("quantity", 0) for p in all_products)
    categories = set(p.get("category", "general") for p in all_products)

    return {
        "total_skus": len(all_products),
        "total_items": total_items,
        "total_value": round(total_value, 2),
        "categories": sorted(categories),
    }


def export_csv(product_store) -> str:
    """Export inventory to CSV format.

    BUG: Uses store_module.Product instead of the directly imported Product.
    Works by accident because store.py imports Product from models, making
    store_module.Product resolve. Breaks if store.py stops importing Product.
    """
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["SKU", "Name", "Price", "Quantity", "Category"])

    all_products = product_store.list_products(page=0, per_page=10000)
    for p in all_products:
        # BUG: This reference to store_module.Product is a stale coupling
        # that should use the directly imported Product instead
        product_obj = store_module.Product.from_dict(p)
        writer.writerow([
            product_obj.sku,
            product_obj.name,
            product_obj.price,
            product_obj.quantity,
            product_obj.category,
        ])

    return output.getvalue()


def low_stock_report(product_store, threshold: int = 5) -> list[dict]:
    """Return products below stock threshold."""
    all_products = product_store.list_products(page=0, per_page=10000)
    return [
        {"sku": p["sku"], "name": p["name"], "quantity": p["quantity"]}
        for p in all_products
        if p.get("quantity", 0) < threshold
    ]
