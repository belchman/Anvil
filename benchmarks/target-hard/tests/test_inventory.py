"""Happy path tests for inventory operations."""
import pytest
from invtrack.models import Product
from invtrack.store import ProductStore
from invtrack.inventory import adjust_stock, get_stock_level, get_low_stock


@pytest.fixture
def store(tmp_path):
    filepath = str(tmp_path / "products.json")
    s = ProductStore(filepath=filepath)
    s.add_product(Product(sku="INV-001", name="Bolt", price=0.50, quantity=100))
    s.add_product(Product(sku="INV-002", name="Nut", price=0.25, quantity=3))
    return s


def test_adjust_stock_add(store):
    adjust_stock(store, "INV-001", 50)
    assert get_stock_level(store, "INV-001") == 150


def test_adjust_stock_remove(store):
    adjust_stock(store, "INV-001", -30)
    assert get_stock_level(store, "INV-001") == 70


def test_adjust_stock_insufficient(store):
    with pytest.raises(ValueError, match="Insufficient stock"):
        adjust_stock(store, "INV-002", -10)


def test_low_stock(store):
    low = get_low_stock(store, threshold=5)
    assert len(low) == 1
    assert low[0]["sku"] == "INV-002"
