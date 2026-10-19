# Seed the first indexer checkpoint of each kube_logs target (SIEMatic build 68ec29d). Without one, the
# plugin asks Kubernetes only for lines newer than the current poll's own start time, so a target that logs
# rarely never delivers anything (found 2026-10-18 on the era-k8s backup). A checkpoint whose cursor sits at
# the container's start, with the container's identity, makes the first collection cover the whole log; from
# then on the plugin advances it and survives restarts by itself. Targets that already have one are skipped.
#   env TARGETS_JSON='[{"target": "kube_logs:ns/name/container", "index": "...", "source": "...",
#        "pod_uid": "...", "container_id": "...", "restart_count": 0, "started_at": "2026-10-18T14:35:47Z"}]' \
#   python manage.py shell < seed-checkpoints.py
import json
import os
from datetime import datetime, timezone

from agent.models import Agent, Checkpoint

AGENT_ID = os.environ.get("SHIPPER_AGENT_ID", "shipper-kube-logs")
agent = Agent.objects.get(agent_id=AGENT_ID)
seeded = 0
for t in json.loads(os.environ["TARGETS_JSON"]):
    if Checkpoint.objects.filter(target=t["target"]).exists():
        continue
    started = datetime.strptime(t["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    cursor = {
        "timestamp": started.isoformat(timespec="microseconds").replace("+00:00", "000Z"),
        "line_hashes": [],
        "pod_uid": t["pod_uid"],
        "container_id": t["container_id"],
        "restart_count": int(t["restart_count"]),
    }
    Checkpoint.objects.create(target=t["target"], cursor=json.dumps(cursor), agent=agent,
                              index=t["index"], source=t["source"], events_delivered=0)
    seeded += 1
print(f"seeded {seeded} checkpoint(s); {Checkpoint.objects.count()} in total")
