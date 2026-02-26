"""Happy path tests for order processing."""
import pytest
from invtrack.models import Product, Order, OrderItem
from invtrack.store import ProductStore
from invtrack.orders import place_order, get_order_summary


@pytest.fixture
def store(tmp_path):
    filepath = str(tmp_path / "products.json")
    s = ProductStore(filepath=filepath)
    s.add_product(Product(sku="ORD-A", name="Alpha", price=10.00, quantity=50))
    s.add_product(Product(sku="ORD-B", name="Beta", price=20.00, quantity=30))
    return s


def test_place_order(store):
    order = Order(
        order_id="O-001",
        items=[OrderItem(sku="ORD-A", quantity=2, unit_price=10.00)],
    )
    result = place_order(store, order)
    assert result.status == "confirmed"


def test_order_summary(store):
    order = Order(
        order_id="O-002",
        items=[
            OrderItem(sku="ORD-A", quantity=1, unit_price=10.00),
            OrderItem(sku="ORD-B", quantity=1, unit_price=20.00),
        ],
    )
    place_order(store, order)
    summary = get_order_summary(order)
    assert summary["total"] == 30.00
    assert summary["items"] == 2
