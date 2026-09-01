"""MCP tool server: reservation availability, booking, cancellation, and
rescheduling. Exposed over streamable HTTP, the same transport Rossoctl's
MCP Gateway uses to register the platform's weather-tool example.
"""
from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP

from . import store
from .store import ReservationError

PORT = int(os.environ.get("PORT", "8000"))

mcp = FastMCP("reservation-tool", host="0.0.0.0", port=PORT)


@mcp.tool()
def get_business_hours() -> dict:
    """Return the business hours and reservation length this tool enforces."""
    return {
        "days": "Monday-Friday",
        "open": "09:00",
        "close": "17:00",
        "slot_minutes": store.SLOT_MINUTES,
    }


@mcp.tool()
def check_availability(date: str) -> list[str]:
    """List open 30-minute reservation slots for one date.

    Args:
        date: Date to check, as YYYY-MM-DD.

    Returns:
        Slot start times, as HH:MM, in ascending order. Empty on a
        weekend or a fully-booked day.
    """
    try:
        return store.check_availability(date)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


@mcp.tool()
def suggest_reservation_times(count: int = 3, earliest_date: str | None = None) -> list[dict]:
    """Suggest the next open 30-minute slots, in date/time order.

    Args:
        count: How many suggestions to return. Defaults to 3.
        earliest_date: Do not suggest anything before this date
            (YYYY-MM-DD). Defaults to today.

    Returns:
        A list of {"date": "YYYY-MM-DD", "time": "HH:MM"} objects.
    """
    try:
        return store.suggest_times(count=count, earliest_date=earliest_date)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


@mcp.tool()
def book_reservation(customer_name: str, date: str, time: str) -> dict:
    """Book a 30-minute reservation for a customer at an agreed slot.

    Args:
        customer_name: Name of the customer the reservation is for.
        date: Reservation date, as YYYY-MM-DD.
        time: Reservation start time, as HH:MM. Must be a valid
            30-minute slot boundary inside business hours.

    Returns:
        The created reservation, including its id.
    """
    try:
        return store.book_reservation(customer_name, date, time)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


@mcp.tool()
def get_reservation(reservation_id: str) -> dict:
    """Look up one reservation by id."""
    try:
        return store.get_reservation(reservation_id)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


@mcp.tool()
def cancel_reservation(reservation_id: str) -> dict:
    """Cancel an existing reservation and free its slot."""
    try:
        return store.cancel_reservation(reservation_id)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


@mcp.tool()
def reschedule_reservation(reservation_id: str, new_date: str, new_time: str) -> dict:
    """Move an existing reservation to a new date and time.

    Args:
        reservation_id: Id of the reservation to move.
        new_date: New reservation date, as YYYY-MM-DD.
        new_time: New reservation start time, as HH:MM.

    Returns:
        The updated reservation.
    """
    try:
        return store.reschedule_reservation(reservation_id, new_date, new_time)
    except ReservationError as exc:
        raise ValueError(str(exc)) from exc


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
