"""Data models for inventory tracking."""
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class Product:
    sku: str
    name: str
    price: float
    quantity: int = 0
    category: str = "general"
    created_at: str = field(default_factory=lambda: datetime.now().isoformat())

    def to_dict(self) -> dict:
        return {
            "sku": self.sku,
            "name": self.name,
            "price": self.price,
            "quantity": self.quantity,
            "category": self.category,
            "created_at": self.created_at,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Product":
        return cls(
            sku=data["sku"],
            name=data["name"],
            price=data["price"],
            quantity=data.get("quantity", 0),
            category=data.get("category", "general"),
            created_at=data.get("created_at", datetime.now().isoformat()),
        )


@dataclass
class OrderItem:
    sku: str
    quantity: int
    unit_price: float

    @property
    def subtotal(self) -> float:
        return self.quantity * self.unit_price


@dataclass
class Order:
    order_id: str
    items: list[OrderItem] = field(default_factory=list)
    status: str = "pending"
    discount_percent: float = 0.0
    created_at: str = field(default_factory=lambda: datetime.now().isoformat())

    @property
    def total(self) -> float:
        subtotal = sum(item.subtotal for item in self.items)
        discount = subtotal * (self.discount_percent / 100.0)
        return subtotal - discount

    def to_dict(self) -> dict:
        return {
            "order_id": self.order_id,
            "items": [
                {"sku": i.sku, "quantity": i.quantity, "unit_price": i.unit_price}
                for i in self.items
            ],
            "status": self.status,
            "discount_percent": self.discount_percent,
            "created_at": self.created_at,
        }
