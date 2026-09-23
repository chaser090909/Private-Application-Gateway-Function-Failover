"""DR watchdog for the private Application Gateway pair.

Two entry points, one decision function:

* a timer that evaluates both regions every 30 seconds, and
* an HTTP webhook that Azure Monitor calls when the primary custom probe is down,
  so the action group does not have to wait for the next tick.

A region is up only when its container group is Running and its custom probe is
healthy. Probe health is the HealthyHostCount / UnhealthyHostCount average,
which is the same signal the probe-down alerts use. The backendhealth action
is a long-running operation, so it is only a short fallback when metrics have
no samples.

A stopped container is down immediately. Failback requires the container to be
Running and the probe to be up right now, so a stale HealthyHostCount sample
cannot return traffic to a dead region. When the primary probe is down and the
secondary region is up, DNS is repointed at the secondary gateway.

Every ARM call authenticates with the app's system-assigned managed identity.
There are no keys and no service principal secrets.
"""

import json
import logging
import os
import socket
from datetime import datetime, timedelta, timezone

import azure.functions as func
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError
from azure.identity import ManagedIdentityCredential
from azure.mgmt.containerinstance import ContainerInstanceManagementClient
from azure.mgmt.monitor import MonitorManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.privatedns import PrivateDnsManagementClient
from azure.mgmt.privatedns.models import ARecord, RecordSet

SUBSCRIPTION_ID = os.environ["AZURE_SUBSCRIPTION_ID"]

DNS_RESOURCE_GROUP = os.environ["DNS_RESOURCE_GROUP"]
DNS_ZONE_NAME = os.environ["DNS_ZONE_NAME"]
DNS_RECORD_NAME = os.environ["DNS_RECORD_NAME"]
DNS_RECORD_TTL = int(os.environ.get("DNS_RECORD_TTL", "30"))

HEALTHY_BACKEND_STATES = {
    state.strip().casefold()
    for state in os.environ.get("BACKEND_HEALTHY_STATES", "Up,Healthy").split(",")
    if state.strip()
}
DOWN_PROBE_STATES = {"down", "unhealthy", "draining"}

PRIMARY = {
    "label": "primary",
    "resource_group": os.environ["PRIMARY_RESOURCE_GROUP"],
    "container_group": os.environ["PRIMARY_CONTAINER_GROUP"],
    "appgw": os.environ["PRIMARY_APPGW_NAME"],
    "ip": os.environ["PRIMARY_APPGW_IP"],
}

SECONDARY = {
    "label": "secondary",
    "resource_group": os.environ["SECONDARY_RESOURCE_GROUP"],
    "container_group": os.environ["SECONDARY_CONTAINER_GROUP"],
    "appgw": os.environ["SECONDARY_APPGW_NAME"],
    "ip": os.environ["SECONDARY_APPGW_IP"],
}

def _prefer_ipv4() -> None:
    """Linux workers can sit on an unreachable IPv6 address until the socket times out."""
    original = socket.getaddrinfo

    def getaddrinfo(host, port, family=0, socktype=0, proto=0, flags=0):
        if family == 0:
            family = socket.AF_INET
        return original(host, port, family, socktype, proto, flags)

    socket.getaddrinfo = getaddrinfo


_prefer_ipv4()
logging.getLogger("azure").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)

# The SDK defaults are a 300 second socket timeout and ten retries. The timer
# fires every 30 seconds and the host cancels the run at 30 seconds, so a
# single call has to fail well inside that window.
_ARM_CLIENT_KWARGS = {
    "connection_timeout": 5,
    "read_timeout": 10,
    "retry_total": 1,
    "retry_backoff_factor": 0.4,
    "retry_backoff_max": 2,
}

credential = ManagedIdentityCredential(**_ARM_CLIENT_KWARGS)
aci_client = ContainerInstanceManagementClient(credential, SUBSCRIPTION_ID, **_ARM_CLIENT_KWARGS)
network_client = NetworkManagementClient(credential, SUBSCRIPTION_ID, **_ARM_CLIENT_KWARGS)
monitor_client = MonitorManagementClient(credential, SUBSCRIPTION_ID, **_ARM_CLIENT_KWARGS)
dns_client = PrivateDnsManagementClient(credential, SUBSCRIPTION_ID, **_ARM_CLIENT_KWARGS)

app = func.FunctionApp()


def _child(obj, snake: str, camel: str | None = None):
    if obj is None:
        return None
    if isinstance(obj, dict):
        if snake in obj:
            return obj[snake]
        if camel and camel in obj:
            return obj[camel]
        return None
    return getattr(obj, snake, None)


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return list(value)


def normalize_health(value) -> str:
    """SDK enums stringify as 'EnumName.UP' on Python 3.11. Compare the value."""
    if value is None:
        return ""
    raw = getattr(value, "value", value)
    text = str(raw).strip()
    if "." in text:
        text = text.rsplit(".", 1)[-1]
    return text.casefold()


def container_state(region: dict) -> str | None:
    """Live container group state. None means the call did not say."""
    group = aci_client.container_groups.get(region["resource_group"], region["container_group"])
    view = _child(group, "instance_view")
    state = _child(view, "state")
    if not state:
        for container in _as_list(_child(group, "containers")):
            current = _child(_child(container, "instance_view"), "current_state")
            state = _child(current, "state")
            if state:
                break
    normalized = normalize_health(state) or None
    logging.info("%s container %s state=%s", region["label"], region["container_group"], normalized)
    return normalized


def _backend_health(region: dict, timeout: int, expand: str | None):
    kwargs = {}
    if expand:
        kwargs["expand"] = expand
    poller = network_client.application_gateways.begin_backend_health(
        region["resource_group"],
        region["appgw"],
        **kwargs,
    )
    poller.wait(timeout=timeout)
    if not poller.done():
        logging.warning("%s backendhealth still running after %ss", region["label"], timeout)
        return None
    return poller.result()


def probe_from_backend_health(region: dict, timeout: int = 15) -> str | None:
    """'up', 'down', or None when the gateway did not return server probe rows."""
    try:
        health = _backend_health(region, timeout, "BackendAddressPool,BackendHttpSettings")
    except Exception as exc:
        logging.warning(
            "%s backendhealth failed status=%s",
            region["label"],
            getattr(exc, "status_code", None) or exc,
        )
        return None

    states = []
    logs = []
    for pool in _as_list(_child(health, "backend_address_pools", "backendAddressPools")):
        settings = _child(pool, "backend_http_settings_collection", "backendHttpSettingsCollection")
        for setting in _as_list(settings):
            for server in _as_list(_child(setting, "servers")):
                state = normalize_health(_child(server, "health"))
                if state:
                    states.append(state)
                probe_log = _child(server, "health_probe_log", "healthProbeLog")
                if probe_log:
                    logs.append(str(probe_log)[:240])

    if not states:
        logging.info("%s backendhealth returned no server probe rows", region["label"])
        return None

    healthy = any(state in HEALTHY_BACKEND_STATES for state in states)
    down = any(state in DOWN_PROBE_STATES for state in states)
    logging.info(
        "%s gateway %s probe_states=%s healthy=%s probe_log=%s",
        region["label"],
        region["appgw"],
        states,
        healthy,
        logs[:2],
    )
    if healthy:
        return "up"
    if down:
        return "down"
    return None


def gateway_resource_id(region: dict) -> str:
    return (
        f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{region['resource_group']}"
        f"/providers/Microsoft.Network/applicationGateways/{region['appgw']}"
    )


def _point_average(point) -> float | None:
    """UnhealthyHostCount and HealthyHostCount are published only as Average."""
    if isinstance(point, dict):
        value = point.get("average")
    else:
        value = getattr(point, "average", None)
    if value is None:
        return None
    return float(value)


def probe_from_metrics(region: dict) -> str | None:
    """Fast probe signal. UnhealthyHostCount is the custom probe failing."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=5)
    timespan = f"{start.strftime('%Y-%m-%dT%H:%M:%SZ')}/{end.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    try:
        metrics = monitor_client.metrics.list(
            gateway_resource_id(region),
            timespan=timespan,
            interval="PT1M",
            metricnames="HealthyHostCount,UnhealthyHostCount",
            aggregation="Average",
        )
    except HttpResponseError as exc:
        logging.warning(
            "%s metrics read failed status=%s",
            region["label"],
            getattr(exc, "status_code", None),
        )
        return None

    latest: dict[str, float] = {}
    for metric in _as_list(_child(metrics, "value")):
        name = _child(_child(metric, "name"), "value") or ""
        series_latest = []
        for series in _as_list(_child(metric, "timeseries")):
            values = [
                value
                for value in (
                    _point_average(point) for point in _as_list(_child(series, "data"))
                )
                if value is not None
            ]
            if values:
                series_latest.append(values[-1])
        if name and series_latest:
            latest[str(name)] = max(series_latest)

    healthy = latest.get("HealthyHostCount")
    unhealthy = latest.get("UnhealthyHostCount")
    logging.info("%s metrics healthy=%s unhealthy=%s", region["label"], healthy, unhealthy)
    if unhealthy is not None and unhealthy >= 1 and (healthy is None or healthy <= 0):
        return "down"
    if healthy is not None and healthy >= 1 and (unhealthy is None or unhealthy <= 0):
        return "up"
    if unhealthy is not None and unhealthy >= 1:
        return "down"
    return None


def read_probe(region: dict, trigger: str) -> tuple[str | None, str]:
    # The timer is every 30 seconds. backendhealth is an LRO and does not
    # finish inside that window, so both the timer and the webhook use metrics.
    logging.info("%s probe read trigger=%s", region["label"], trigger)
    probe = probe_from_metrics(region)
    if probe is not None:
        return probe, "metrics"
    return None, "none"


def assess(region: dict, trigger: str) -> dict:
    """up is True, False, or None. None means do not move DNS on this region."""
    try:
        container = container_state(region)
    except Exception:
        logging.exception("%s container state read failed", region["label"])
        container = None

    if container is not None and container.casefold() != "running":
        return {"container": container, "probe": "down", "up": False, "source": "container"}

    try:
        probe, source = read_probe(region, trigger)
    except Exception:
        logging.exception("%s probe health read failed", region["label"])
        probe, source = None, "error"

    if container is not None and container.casefold() == "running" and probe == "up":
        up = True
    elif probe == "down":
        up = False
    else:
        up = None

    return {"container": container, "probe": probe, "up": up, "source": source}


def current_targets() -> list[str]:
    try:
        record_set = dns_client.record_sets.get(
            DNS_RESOURCE_GROUP, DNS_ZONE_NAME, "A", DNS_RECORD_NAME
        )
    except ResourceNotFoundError:
        return []
    return sorted(record.ipv4_address for record in (record_set.a_records or []) if record.ipv4_address)


def point_dns_at(region: dict) -> bool:
    """Repoint the A record. Returns True only when it actually changed."""
    existing = current_targets()
    if existing == [region["ip"]]:
        logging.info("DNS already points at %s (%s)", region["ip"], region["label"])
        return False

    dns_client.record_sets.create_or_update(
        DNS_RESOURCE_GROUP,
        DNS_ZONE_NAME,
        "A",
        DNS_RECORD_NAME,
        RecordSet(ttl=DNS_RECORD_TTL, a_records=[ARecord(ipv4_address=region["ip"])]),
    )
    logging.warning(
        "DNS %s repointed from %s to %s (%s)",
        DNS_RECORD_NAME,
        existing,
        region["ip"],
        region["label"],
    )
    return True


def evaluate(trigger: str) -> dict:
    """Decide which region should serve, and move DNS if it is not already there.

    Primary probe down plus a healthy secondary moves the A record to the
    secondary gateway. An unknown primary is left alone so a failed ARM read
    cannot flap traffic.
    """
    primary = assess(PRIMARY, trigger)
    secondary = None

    if primary["up"] is True:
        changed = point_dns_at(PRIMARY)
        active = "primary"
    elif primary["up"] is False:
        secondary = assess(SECONDARY, trigger)
        if secondary["up"] is True:
            changed = point_dns_at(SECONDARY)
            active = "secondary"
        else:
            logging.critical("Primary probe is down and secondary is not up; leaving DNS unchanged")
            changed, active = False, "none"
    else:
        logging.error("Primary probe health is unknown; leaving DNS unchanged")
        changed, active = False, "unchanged"

    secondary_up = secondary_region_is_up(secondary)
    event = None
    if secondary_up is True:
        # Logged whenever Central US can serve, so alert-secondary-region-up
        # stays fired and resolves once these lines stop.
        event = "SECONDARY_REGION_UP"
        logging.info("SECONDARY_REGION_UP secondary region is up")
    if changed and active == "primary":
        event = "FAILBACK_PRIMARY"
        logging.warning(
            "FAILBACK_PRIMARY traffic sent back to primary region %s",
            PRIMARY["ip"],
        )

    result = {
        "trigger": trigger,
        "primary_up": primary["up"],
        "secondary_up": secondary_up,
        "primary_probe": primary["probe"],
        "secondary_probe": None if secondary is None else secondary["probe"],
        "primary_container": primary["container"],
        "secondary_container": None if secondary is None else secondary["container"],
        "probe_source": primary["source"],
        "active": active,
        "event": event,
        "dns_changed": changed,
        "dns_targets": current_targets(),
    }
    logging.info("PROBE_HEALTH watchdog evaluated: %s", json.dumps(result))
    return result


def secondary_region_is_up(assessed: dict | None) -> bool | None:
    """Whether Central US can serve. Reuses a failover assessment when one exists.

    The steady-state check is container state plus a metrics read, so the
    30-second timer does not wait on a second backendhealth call.
    """
    if assessed is not None:
        return assessed["up"]

    try:
        state = container_state(SECONDARY)
    except Exception:
        logging.exception("secondary container state read failed")
        state = None

    if state is not None and state != "running":
        return False

    try:
        probe = probe_from_metrics(SECONDARY)
    except Exception:
        logging.exception("secondary probe health read failed")
        return None

    if state == "running" and probe == "up":
        return True
    if probe == "down":
        return False
    return None


@app.timer_trigger(
    schedule="%WATCHDOG_SCHEDULE%",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def watchdog(timer: func.TimerRequest) -> None:
    evaluate("timer")


@app.route(route="region-failover", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def region_failover(req: func.HttpRequest) -> func.HttpResponse:
    """Webhook for the failover action group.

    Fired by the primary probe-down alert and by the primary container stop.
    The alert payload is logged and then live state is re-read, which is what
    actually moves DNS to the secondary region. Repeated calls are harmless.
    """
    try:
        payload = req.get_json()
    except ValueError:
        payload = None

    if isinstance(payload, dict):
        essentials = payload.get("data", {}).get("essentials", {})
        logging.info(
            "webhook trigger: rule=%s condition=%s targets=%s",
            essentials.get("alertRule"),
            essentials.get("monitorCondition"),
            essentials.get("alertTargetIDs"),
        )

    result = evaluate("webhook")
    return func.HttpResponse(
        json.dumps(result),
        status_code=200,
        mimetype="application/json",
    )
