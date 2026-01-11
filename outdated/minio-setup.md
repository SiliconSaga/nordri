# MinIO Setup for Velero Backup Storage

## Overview

This document covers the deployment of MinIO as a local S3-compatible storage backend for Velero backups, using the official MinIO Docker image to avoid Bitnami licensing issues.

## Deployment

### 1. MinIO Installation

MinIO has been deployed using a custom Kubernetes YAML configuration with the official `minio/minio` Docker image.

**Configuration:**
- **Image**: `minio/minio:latest` (official MinIO image)
- **Storage**: 20Gi using `local-path` storage class
- **Credentials**: `minioadmin` / `minioadmin123`
- **Namespace**: `minio`

### 2. Access Information

**API Endpoint (for Velero/S3 operations):**
- URL: `http://localhost:9000`
- Note: This redirects to port 9001 in browsers (normal behavior)

**Web Console (for management):**
- URL: `http://localhost:9001`
- Username: `minioadmin`
- Password: `minioadmin123`

### 3. Port Forwarding Setup

Run these commands in separate terminals:

```bash
# Terminal 1: MinIO API (for Velero)
kubectl port-forward svc/minio -n minio 9000:9000

# Terminal 2: MinIO Console (for web management)
kubectl port-forward svc/minio-console -n minio 9001:9001
```

### 4. Create Velero Backup Bucket

1. Open browser to `http://localhost:9001`
2. Login with `minioadmin` / `minioadmin123`
3. Click "Create Bucket"
4. Bucket name: `velero-backups`
5. Click "Create Bucket"

### 5. Verify MinIO Status

```bash
# Check MinIO pod status
kubectl get pods -n minio

# Check MinIO logs
kubectl logs -n minio deployment/minio

# Check services
kubectl get svc -n minio
```

## Integration with Velero

### MinIO Configuration for Velero

**S3 Endpoint**: `http://localhost:9000`
**Access Key**: `minioadmin`
**Secret Key**: `minioadmin123`
**Bucket**: `velero-backups`
**Region**: `us-east-1` (default)

### Velero Installation Command

```bash
# Install Velero server with MinIO backend
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket velero-backups \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=false \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,s3Url=http://localhost:9000
```

## Storage Strategy

### Local MinIO (Primary)
- **Purpose**: Fast local backups and restores
- **Storage**: 20Gi local-path storage
- **Use Case**: Development, testing, quick restores

### GCP Integration (Future)
- **Purpose**: Long-term storage and disaster recovery
- **Method**: MinIO replication to GCP bucket
- **Use Case**: Production backups, cross-cluster restore

## Troubleshooting

### Common Issues

1. **Port Forward Issues**
   - Ensure ports 9000 and 9001 are not in use
   - Check if other port-forwards are running: `ps aux | grep kubectl`

2. **MinIO Not Starting**
   - Check pod logs: `kubectl logs -n minio deployment/minio`
   - Verify storage: `kubectl get pvc -n minio`

3. **Access Issues**
   - Verify port forwards are running
   - Check service endpoints: `kubectl get endpoints -n minio`

### Verification Commands

```bash
# Check all MinIO resources
kubectl get all -n minio

# Test MinIO API connectivity
curl -I http://localhost:9000/minio/health/live

# Check storage usage
kubectl describe pvc minio-storage -n minio
```

## Next Steps

1. **Create Velero Credentials File**
2. **Install Velero Server**
3. **Configure Backup Schedules**
4. **Test Backup/Restore Operations**
5. **Set up GCP Replication (Optional)**

## Files Created

- `minio-deployment.yaml`: Complete MinIO deployment configuration
- `minio-setup.md`: This documentation file

## Notes

- Using official MinIO Docker image to avoid Bitnami licensing issues
- 20Gi storage should be sufficient for development/testing
- For production, consider larger storage and GCP replication
- MinIO console provides bucket management and monitoring
