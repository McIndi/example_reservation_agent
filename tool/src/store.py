"""In-memory reservation store and availability logic.

Business hours: Monday-Friday, 09:00-17:00, server local time. Every
reservation is fixed at 30 minutes. State lives in this process's memory
only, and resets when the tool pod restarts - see the README's
Limitations section before using this for anything but a demo.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta

BUSINESS_START_MINUTES = 9 * 60
BUSINESS_END_MINUTES = 17 * 60
SLOT_MINUTES = 30
DATE_FMT = "%Y-%m-%d"


class ReservationError(ValueError):
    """Raised for any request that breaks a scheduling rule."""


@dataclass
class Reservation:
    id: str
    customer_name: str
    date: str  # YYYY-MM-DD
    time: str  # HH:MM, 30-minute slot start
    status: str = "booked"  # booked | cancelled


_RESERVATIONS: dict[str, Reservation] = {}


def _slot_starts() -> list[str]:
    """Every 30-minute slot start time in one business day, as HH:MM."""
    starts = []
    minutes = BUSINESS_START_MINUTES
    while minutes + SLOT_MINUTES <= BUSINESS_END_MINUTES:
        starts.append(f"{minutes // 60:02d}:{minutes % 60:02d}")
        minutes += SLOT_MINUTES
    return starts


SLOT_STARTS = _slot_starts()


def _parse_date(value: str) -> date:
    try:
        return datetime.strptime(value, DATE_FMT).date()
    except ValueError as exc:
        raise ReservationError(f"'{value}' is not a valid date, use YYYY-MM-DD") from exc


def _validate_time(value: str) -> str:
    if value not in SLOT_STARTS:
        raise ReservationError(
            f"'{value}' is not a bookable 30-minute slot start. "
            f"Valid slots run {SLOT_STARTS[0]}-{SLOT_STARTS[-1]} in 30-minute steps."
        )
    return value


def is_business_day(d: date) -> bool:
    return d.weekday() < 5  # Monday=0 ... Friday=4


def _booked_times(d: date) -> set[str]:
    key = d.strftime(DATE_FMT)
    return {
        r.time for r in _RESERVATIONS.values() if r.date == key and r.status == "booked"
    }


def available_slots(d: date) -> list[str]:
    if not is_business_day(d):
        return []
    taken = _booked_times(d)
    return [t for t in SLOT_STARTS if t not in taken]


def check_availability(date_str: str) -> list[str]:
    d = _parse_date(date_str)
    return available_slots(d)


def suggest_times(count: int = 3, earliest_date: str | None = None) -> list[dict]:
    if count < 1:
        raise ReservationError("count must be at least 1")
    start = _parse_date(earliest_date) if earliest_date else date.today()
    suggestions: list[dict] = []
    d = start
    # Bound the search so a fully-booked stretch cannot loop forever.
    for _ in range(60):
        for t in available_slots(d):
            suggestions.append({"date": d.strftime(DATE_FMT), "time": t})
            if len(suggestions) == count:
                return suggestions
        d += timedelta(days=1)
    return suggestions


def book_reservation(customer_name: str, date_str: str, time_str: str) -> dict:
    if not customer_name or not customer_name.strip():
        raise ReservationError("customer_name is required")
    d = _parse_date(date_str)
    t = _validate_time(time_str)
    if not is_business_day(d):
        raise ReservationError(f"{date_str} is a weekend; reservations run Monday-Friday")
    if t not in available_slots(d):
        raise ReservationError(f"{date_str} {t} is already booked")
    reservation = Reservation(
        id=uuid.uuid4().hex[:8],
        customer_name=customer_name.strip(),
        date=date_str,
        time=t,
    )
    _RESERVATIONS[reservation.id] = reservation
    return _to_dict(reservation)


def get_reservation(reservation_id: str) -> dict:
    reservation = _RESERVATIONS.get(reservation_id)
    if reservation is None:
        raise ReservationError(f"No reservation with id '{reservation_id}'")
    return _to_dict(reservation)


def cancel_reservation(reservation_id: str) -> dict:
    reservation = _RESERVATIONS.get(reservation_id)
    if reservation is None:
        raise ReservationError(f"No reservation with id '{reservation_id}'")
    if reservation.status == "cancelled":
        raise ReservationError(f"Reservation '{reservation_id}' is already cancelled")
    reservation.status = "cancelled"
    return _to_dict(reservation)


def reschedule_reservation(reservation_id: str, new_date: str, new_time: str) -> dict:
    reservation = _RESERVATIONS.get(reservation_id)
    if reservation is None:
        raise ReservationError(f"No reservation with id '{reservation_id}'")
    if reservation.status == "cancelled":
        raise ReservationError(
            f"Reservation '{reservation_id}' is cancelled and cannot be rescheduled"
        )
    d = _parse_date(new_date)
    t = _validate_time(new_time)
    if not is_business_day(d):
        raise ReservationError(f"{new_date} is a weekend; reservations run Monday-Friday")
    if t not in available_slots(d):
        raise ReservationError(f"{new_date} {t} is already booked")
    reservation.date = new_date
    reservation.time = t
    return _to_dict(reservation)


def _to_dict(reservation: Reservation) -> dict:
    return {
        "id": reservation.id,
        "customer_name": reservation.customer_name,
        "date": reservation.date,
        "time": reservation.time,
        "status": reservation.status,
    }
