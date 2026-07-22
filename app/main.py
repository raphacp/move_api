from uuid import UUID, uuid4
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
from scalar_fastapi import get_scalar_api_reference

app = FastAPI(
    title="API de Pedidos",
    description="Projeto base do curso do Rapha na Move Tech — Magalu × Prósper Digital Skills",
    version="1.0.0",
    docs_url=None,
    redoc_url=None,
)


@app.get("/docs", include_in_schema=False)
def docs():
    return get_scalar_api_reference(
        openapi_url=app.openapi_url,
        title=app.title,
    )


orders: dict[UUID, dict] = {}


class ItemIn(BaseModel):
    sku: str
    description: str
    quantity: int


class OrderIn(BaseModel):
    customer: str


@app.get("/health", tags=["health"])
def health():
    return {"status": "ok"}


@app.post("/orders", status_code=status.HTTP_201_CREATED, tags=["orders"])
def create_order(body: OrderIn):
    order_id = uuid4()
    orders[order_id] = {
        "id": str(order_id),
        "customer": body.customer,
        "status": "open",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "items": [],
    }
    return orders[order_id]


@app.get("/orders", tags=["orders"])
def list_orders():
    return list(orders.values())


@app.get("/orders/{order_id}", tags=["orders"])
def get_order(order_id: UUID):
    order = orders.get(order_id)
    if not order:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pedido não encontrado")
    return order


@app.post("/orders/{order_id}/items", status_code=status.HTTP_201_CREATED, tags=["items"])
def add_item(order_id: UUID, body: ItemIn):
    order = orders.get(order_id)
    if not order:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pedido não encontrado")
    item = {"id": str(uuid4()), **body.model_dump()}
    order["items"].append(item)
    return item


@app.get("/orders/{order_id}/items", tags=["items"])
def list_items(order_id: UUID):
    order = orders.get(order_id)
    if not order:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pedido não encontrado")
    return order["items"]


@app.delete("/orders/{order_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["orders"])
def cancel_order(order_id: UUID):
    order = orders.get(order_id)
    if not order:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pedido não encontrado")
    order["status"] = "cancelled"
