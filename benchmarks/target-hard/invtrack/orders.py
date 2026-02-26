"""Order processing.

BUG 2 (no rollback): place_order() decrements stock per line item sequentially.
If item N fails (out of stock), items 1..N-1 are already decremented with no
rollback, leaving inventory in an inconsistent state.

BUG 5 (unvalidated discount): apply_discount() does not clamp percent to 0-100.
Negative values increase price. Values > 100 create negative totals.
"""
from invtrack.models import Order, OrderItem
from invtrack.store import ProductStore
from invtrack.inventory import adjust_stock, check_availability


def place_order(store: ProductStore, order: Order) -> Order:
    """Process an order by decrementing stock for each line item.

    BUG: No rollback. If the 3rd item is out of stock, items 1-2 are already
    decremented. Stock becomes inconsistent.
    """
    for item in order.items:
        if not check_availability(store, item.sku, item.quantity):
            raise ValueError(f"Insufficient stock for {item.sku}")
        adjust_stock(store, item.sku, -item.quantity)

    order.status = "confirmed"
    return order


def cancel_order(store: ProductStore, order: Order) -> Order:
    """Cancel an order and restore stock."""
    if order.status != "confirmed":
        raise ValueError(f"Cannot cancel order in status: {order.status}")

    for item in order.items:
        adjust_stock(store, item.sku, item.quantity)

    order.status = "cancelled"
    return order


def apply_discount(order: Order, percent: float) -> Order:
    """Apply a discount percentage to an order.

    BUG: No validation on percent. Negative values increase price.
    Values > 100 create negative totals.
    """
    order.discount_percent = percent
    return order


def get_order_summary(order: Order) -> dict:
    return {
        "order_id": order.order_id,
        "items": len(order.items),
        "total": order.total,
        "status": order.status,
        "discount": f"{order.discount_percent}%",
    }
