"""JSON persistence layer with in-memory cache.

BUG 1 (mutation aliasing): get_product() returns the cache dict reference
directly instead of a copy. Callers that mutate the returned dict corrupt
the cache, and the next save() persists unwanted fields.
"""
import json
import os
from invtrack.models import Product


class ProductStore:
    def __init__(self, filepath: str = "products.json"):
        self._filepath = filepath
        self._cache: dict[str, dict] = {}
        self._load()

    def _load(self):
        if os.path.exists(self._filepath):
            with open(self._filepath) as f:
                data = json.load(f)
            self._cache = {p["sku"]: p for p in data.get("products", [])}

    def save(self):
        products = list(self._cache.values())
        with open(self._filepath, "w") as f:
            json.dump({"products": products}, f, indent=2)

    def add_product(self, product: Product):
        self._cache[product.sku] = product.to_dict()
        self.save()

    def get_product(self, sku: str) -> dict | None:
        """Get product data by SKU.

        BUG: Returns the actual cache dict, not a copy. Any mutation by the
        caller (e.g. adding fields) corrupts the cache and gets persisted.
        """
        return self._cache.get(sku)

    def update_product(self, sku: str, updates: dict):
        if sku not in self._cache:
            raise KeyError(f"Product not found: {sku}")
        self._cache[sku].update(updates)
        self.save()

    def delete_product(self, sku: str):
        if sku not in self._cache:
            raise KeyError(f"Product not found: {sku}")
        del self._cache[sku]
        self.save()

    def list_products(self, page: int = 0, per_page: int = 10) -> list[dict]:
        """List products with pagination.

        BUG 3 (pagination): Uses 0-indexed pages internally. The CLI passes
        user-facing 1-indexed page numbers directly without subtracting 1,
        so page 1 from the CLI actually skips the first page of results.
        """
        all_products = list(self._cache.values())
        start = page * per_page
        end = start + per_page
        return all_products[start:end]

    def count(self) -> int:
        return len(self._cache)

    def search(self, query: str) -> list[dict]:
        results = []
        q = query.lower()
        for p in self._cache.values():
            if q in p.get("name", "").lower() or q in p.get("sku", "").lower():
                results.append(p)
        return results
