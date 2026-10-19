# The demo's SIEMatic content, as built by hand on the primary cluster (ocp-runner docs-archive,
# phase-9-deployment-log.md, "Built the real Phase 4 spec"): five public saved searches and the shared
# "Zero trust evidence" dashboard with four panels. Owner: the break-glass superuser. Idempotent: rows
# are matched by name and rewritten. Run with:  python manage.py shell < demo-content.py
from django.contrib.auth import get_user_model

from dashboarding.models import Dashboard, Panel
from search2.models import SavedSearch

owner = get_user_model().objects.get(username="break-glass")

SEARCHES = {
    # the ones a presenter runs by name
    "AuthBridge denials": """search --filter='index="authbridge"' --filter='extracted_fields__code="ibac.blocked"' --order-by='["-created"]' --limit=100""",
    "AuthBridge traffic": """search --filter='index="authbridge"' --order-by='["-created"]' --limit=200""",
    "Vault audit reads": """search --filter='index="vault"' --order-by='["-created"]' --limit=100""",
    "Keycloak events": """search --filter='index="keycloak"' --order-by='["-created"]' --limit=100""",
    "The blocked turn": """search --filter='created__gte={last_hour}' --order-by='["-created"]' --limit=300""",
    # the four that back the dashboard panels
    "Events per index (last hour)": """search --filter='created__gte={last_hour}' | groupby --keys='["index"]' --out='event_count'""",
    "AuthBridge decisions by outcome": """search --filter='index="authbridge"' | groupby --keys='["extracted_fields__code"]' --out='event_count'""",
    "Keycloak events by type and user": """search --filter='index="keycloak"' | groupby --keys='["extracted_fields__type", "extracted_fields__details__username"]' --out='event_count'""",
    "Vault reads by service account": """search --filter='index="vault"' | groupby --keys='["extracted_fields__auth__display_name", "extracted_fields__request__operation"]' --out='event_count'""",
}
for name, query in SEARCHES.items():
    SavedSearch.objects.update_or_create(owner=owner, name=name, defaults={"query": query, "is_public": True})

PANELS = [
    ("Events per index, last hour", "Events per index (last hour)", "chart", "bar", "index", "event_count"),
    ("AuthBridge decisions by outcome", "AuthBridge decisions by outcome", "chart", "bar", "extracted_fields__code", "event_count"),
    ("Keycloak events by type and user", "Keycloak events by type and user", "table", None, None, None),
    ("Vault reads by service account", "Vault reads by service account", "table", None, None, None),
]
dashboard, _ = Dashboard.objects.update_or_create(
    created_by=owner, name="Zero trust evidence",
    defaults={"description": "Three evidence stores on one timestamp axis: AuthBridge decisions from the "
              "sidecars, Keycloak's identity events, and the Vault audit device. Act 4 of the demo.",
              "shared": True})
dashboard.panels.all().delete()
for order, (title, search_name, viz, chart, x, y) in enumerate(PANELS):
    Panel.objects.create(dashboard=dashboard, title=title, search=f'run_saved_search "{search_name}"',
                         visualization_type=viz, chart_type=chart, x_field=x, y_field=y,
                         order=order, row=1 + order // 2, column=1 + order % 2)
print(f"demo content: {len(SEARCHES)} searches, dashboard '{dashboard.name}' with {dashboard.panels.count()} panels")
