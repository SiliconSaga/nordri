# PostgreSQL Database Service

This platform provides a self-service PostgreSQL capability using Crossplane and the Percona PostgreSQL Operator.

## Requesting a Database

To provision a new PostgreSQL database, create a `XPostgreSQL` custom resource.

### Example: 

`my-db.yaml`

Apply it to the cluster:

```bash
kubectl apply -f my-db.yaml
```

## Accessing the Database

The database is deployed directly into the **same namespace** where you created the `PostgreSQLInstance` claim.

> [!IMPORTANT]
> You must ensure the target namespace exists before creating the `PostgreSQLInstance`.

### Connection Details

*   **Namespace**: Your application namespace (e.g., `my-ns`)
*   **Host**: `my-db.my-ns.svc.cluster.local`
*   **Port**: `5432`
*   **Database**: `mydb` (from `databaseName` parameter)
*   **User**: `mydb` (same as database name)
*   **Password**: Retrieved from the secret in your namespace

### Retrieving Credentials

```bash
# Get the password from the secret in your namespace
kubectl get secret my-db-user-secret -n my-ns -o jsonpath="{.data.password}" | base64 -d
```

### Testing Connectivity

You can verify connectivity and run SQL queries using a temporary client pod.

1.  **Deploy a Client Pod:**

    ```bash
    kubectl run postgres-client --rm -it --image=postgres:15 --restart=Never --namespace my-ns -- bash
    ```

2.  **Connect to the Database:**

    Inside the pod, run:

    ```bash
    # Replace <password> with the actual password retrieved above
    PGPASSWORD='<password>' psql -h my-db -U mydb -d mydb
    ```

3.  **Run SQL Commands:**

    ```sql
    -- Check version
    SELECT version();

    -- Create a table
    CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT, email TEXT);

    -- Insert data
    INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');

    -- Query data
    SELECT * FROM users;
    ```

## Architecture

*   **Crossplane**: Manages the abstraction and lifecycle of the database.
*   **Percona PostgreSQL Operator**: Orchestrates the PostgreSQL clusters, handling high availability, backups, and updates.
*   **Namespace Isolation**: Each database instance runs in its own namespace for security and resource isolation.

## Backups and Restore

The Percona Operator automatically handles backups using `pgBackRest`.

### Verifying Backups

You can verify that backups are being created by checking the `pgbackrest` repository pod and the backup jobs.

```bash
# Check for backup jobs
kubectl get jobs -n my-ns

# Check backup status in the PerconaPGCluster custom resource
kubectl get perconapgcluster my-db -n my-ns -o yaml | grep -A 10 status:
```

### Restoring a Database

To restore a database, you typically create a new `PostgreSQLInstance` and reference the backup repository of the old instance. 
*(Note: Specific restore procedures involving Crossplane Composition parameters are currently under development. For manual restore using the operator directly, refer to the [Percona Documentation](https://docs.percona.com/percona-operator-for-postgresql/2.0/backups.html).)*
