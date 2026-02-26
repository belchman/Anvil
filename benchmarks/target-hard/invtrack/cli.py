"""CLI entry point for inventory management.

BUG 3 (pagination off-by-one): list_cmd() passes the user's 1-indexed page
number directly to store.list_products(), which uses 0-indexed pages internally.
Requesting page 1 returns the second page of results (skips first page).
"""
import argparse
import sys
from invtrack.models import Product
from invtrack.store import ProductStore
from invtrack.inventory import adjust_stock, get_low_stock
from invtrack.orders import place_order, apply_discount
from invtrack.reports import inventory_summary, export_csv


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="invtrack", description="Inventory tracker")
    sub = parser.add_subparsers(dest="command")

    add_p = sub.add_parser("add", help="Add a product")
    add_p.add_argument("sku")
    add_p.add_argument("name")
    add_p.add_argument("price", type=float)
    add_p.add_argument("--quantity", type=int, default=0)
    add_p.add_argument("--category", default="general")

    list_p = sub.add_parser("list", help="List products")
    list_p.add_argument("--page", type=int, default=1, help="Page number (1-indexed)")
    list_p.add_argument("--per-page", type=int, default=10)

    stock_p = sub.add_parser("stock", help="Adjust stock")
    stock_p.add_argument("sku")
    stock_p.add_argument("delta", type=int)

    low_p = sub.add_parser("low-stock", help="Show low stock items")
    low_p.add_argument("--threshold", type=int, default=5)

    sub.add_parser("summary", help="Inventory summary")
    sub.add_parser("export", help="Export CSV")

    search_p = sub.add_parser("search", help="Search products")
    search_p.add_argument("query")

    return parser


def list_cmd(store: ProductStore, args):
    """List products with pagination.

    BUG: Passes args.page (1-indexed from user) directly to list_products()
    which expects 0-indexed pages. Page 1 shows page index 1 = second page.
    """
    products = store.list_products(page=args.page, per_page=args.per_page)
    if not products:
        print("No products found.")
        return
    for p in products:
        print(f"  {p['sku']}: {p['name']} - ${p['price']:.2f} (qty: {p['quantity']})")


def main(argv=None):
    parser = create_parser()
    args = parser.parse_args(argv)
    store = ProductStore()

    if args.command == "add":
        product = Product(
            sku=args.sku, name=args.name, price=args.price,
            quantity=args.quantity, category=args.category,
        )
        store.add_product(product)
        print(f"Added: {args.sku}")

    elif args.command == "list":
        list_cmd(store, args)

    elif args.command == "stock":
        adjust_stock(store, args.sku, args.delta)
        print(f"Stock adjusted: {args.sku} by {args.delta}")

    elif args.command == "low-stock":
        items = get_low_stock(store, args.threshold)
        for item in items:
            print(f"  {item['sku']}: {item['name']} (qty: {item['quantity']})")

    elif args.command == "summary":
        s = inventory_summary(store)
        print(f"SKUs: {s['total_skus']}, Items: {s['total_items']}, Value: ${s['total_value']:.2f}")

    elif args.command == "export":
        print(export_csv(store))

    elif args.command == "search":
        results = store.search(args.query)
        for p in results:
            print(f"  {p['sku']}: {p['name']} - ${p['price']:.2f}")

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
