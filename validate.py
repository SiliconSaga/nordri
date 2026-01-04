import logging
import time
import requests
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from rich.console import Console
from rich.table import Table

# Setup
logging.basicConfig(level=logging.INFO, format='%(message)s')
console = Console()
config.load_kube_config()
v1 = client.CoreV1Api()
custom_api = client.CustomObjectsApi()

def check_pods(namespace, label_selector=None):
    """Checks if all pods in a namespace are Running/Completed."""
    try:
        pods = v1.list_namespaced_pod(namespace, label_selector=label_selector)
        if not pods.items:
            return False, f"No pods found in {namespace}"
        
        all_ready = True
        not_ready_pods = []
        
        for pod in pods.items:
            if pod.status.phase not in ["Running", "Succeeded"]:
                all_ready = False
                not_ready_pods.append(f"{pod.metadata.name} ({pod.status.phase})")
            elif pod.status.phase == "Running":
                 # Check readiness gates if container statuses exist
                 if pod.status.container_statuses:
                     for container in pod.status.container_statuses:
                         if not container.ready:
                             all_ready = False
                             not_ready_pods.append(f"{pod.metadata.name} (NotReady)")

        if all_ready:
            return True, f"{len(pods.items)} pods ready"
        else:
            return False, f"Pods not ready: {', '.join(not_ready_pods)}"

    except ApiException as e:
        return False, f"API Error: {e}"

def check_url(url, host_header=None, expected_code=200):
    """Checks if a URL returns the expected status code (int or list)."""
    headers = {"Host": host_header} if host_header else {}
    expected = [expected_code] if isinstance(expected_code, int) else expected_code
    try:
        # We verify=False because we might use self-signed certs or localhost
        response = requests.get(url, headers=headers, timeout=5, verify=False)
        if response.status_code in expected:
            return True, f"Status {response.status_code}"
        # ArgoCD might return 200 or 307 redirect
        if response.status_code in [200, 302, 307] and any(c in [200, 302, 307] for c in expected):
             return True, f"Status {response.status_code}"

        return False, f"Got {response.status_code}, expected {expected}"
    except requests.exceptions.RequestException as e:
        return False, f"Connection Failed: {e}"

def check_pvc_binding(storage_class, namespace="default"):
    """Creates a temporary PVC to verify storage."""
    pvc_name = f"test-pvc-{storage_class}"
    pvc_manifest = {
        "apiVersion": "v1",
        "kind": "PersistentVolumeClaim",
        "metadata": {"name": pvc_name},
        "spec": {
            "accessModes": ["ReadWriteOnce"],
            "storageClassName": storage_class,
            "resources": {"requests": {"storage": "10Mi"}}
        }
    }
    
    try:
        # Create
        v1.create_namespaced_persistent_volume_claim(namespace, pvc_manifest)
        
        # Wait for Bound (max 30s)
        bound = False
        for i in range(15):
            pvc = v1.read_namespaced_persistent_volume_claim(pvc_name, namespace)
            if pvc.status.phase == "Bound":
                bound = True
                break
            time.sleep(2)
            
        # Delete
        v1.delete_namespaced_persistent_volume_claim(pvc_name, namespace)
        
        if bound:
            return True, "PVC Bound & Deleted"
        else:
            return False, "PVC timed out (Not Bound)"
            
    except ApiException as e:
        # Cleanup attempt
        try:
             v1.delete_namespaced_persistent_volume_claim(pvc_name, namespace)
        except:
             pass
        return False, f"PVC Error: {e.reason}"

def main():
    table = Table(title="Nordri Validation Report")
    table.add_column("Component", style="cyan")
    table.add_column("Test", style="magenta")
    table.add_column("Status", style="bold")
    table.add_column("Details")

    console.print("[bold yellow]Running Nordri Validation...[/bold yellow]")

    # 1. Pod Health
    namespaces = {
        "Gitea": "gitea",
        "ArgoCD": "argocd",
        "Longhorn": "longhorn-system",
        "Garage": "garage",
        "Crossplane": "crossplane-system",
        "Traefik": "kube-system"
    }
    
    for name, ns in namespaces.items():
        success, msg = check_pods(ns)
        status = "[green]PASS[/green]" if success else "[red]FAIL[/red]"
        table.add_row(name, f"Pod Health ({ns})", status, msg)

    # 2. Ingress Connectivity
    # Assuming localhost resolution works or Host header is used
    ingresses = [
        ("ArgoCD UI", "http://localhost", "argocd.localhost"),
        ("Gitea UI", "http://localhost", "gitea.localhost"),
        ("Longhorn UI", "http://localhost", "longhorn.localhost"),
        ("Garage S3 API", "http://localhost", "s3.localhost"),
    ]

    for name, url, host in ingresses:
        # Garage S3 might return 200 (empty list) or 403 (no auth), both mean it's running.
        codes = [200, 403] if "S3" in name else 200
        success, msg = check_url(url, host_header=host, expected_code=codes)
        status = "[green]PASS[/green]" if success else "[red]FAIL[/red]"
        table.add_row(name, f"Ingress ({host})", status, msg)

    # 3. Storage Validation
    success, msg = check_pvc_binding("longhorn")
    status = "[green]PASS[/green]" if success else "[red]FAIL[/red]"
    table.add_row("Longhorn", "PVC Creation (Smoke Test)", status, msg)

    console.print(table)

if __name__ == "__main__":
    main()
