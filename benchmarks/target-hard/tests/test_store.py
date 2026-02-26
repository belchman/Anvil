"""Happy path tests for ProductStore."""
import json
import os
import pytest
from invtrack.models import Product
from invtrack.store import ProductStore


@pytest.fixture
def store(tmp_path):
    filepath = str(tmp_path / "products.json")
    return ProductStore(filepath=filepath)


@pytest.fixture
def populated_store(store):
    store.add_product(Product(sku="WDG-001", name="Widget", price=9.99, quantity=100))
    store.add_product(Product(sku="GAD-002", name="Gadget", price=24.99, quantity=50))
    store.add_product(Product(sku="THG-003", name="Thingamajig", price=4.99, quantity=200))
    return store


def test_add_and_get(store):
    store.add_product(Product(sku="TST-001", name="Test Item", price=5.00, quantity=10))
    result = store.get_product("TST-001")
    assert result is not None
    assert result["name"] == "Test Item"
    assert result["quantity"] == 10


def test_list_products(populated_store):
    products = populated_store.list_products(page=0, per_page=10)
    assert len(products) == 3


def test_delete(populated_store):
    populated_store.delete_product("GAD-002")
    assert populated_store.get_product("GAD-002") is None
    assert populated_store.count() == 2


def test_search(populated_store):
    results = populated_store.search("widget")
    assert len(results) == 1
    assert results[0]["sku"] == "WDG-001"


def test_persistence(tmp_path):
    filepath = str(tmp_path / "products.json")
    store1 = ProductStore(filepath=filepath)
    store1.add_product(Product(sku="PER-001", name="Persist", price=1.00, quantity=5))

    store2 = ProductStore(filepath=filepath)
    result = store2.get_product("PER-001")
    assert result is not None
    assert result["name"] == "Persist"
