# Gitea Setup and Access

## Accessing Gitea Locally

To access the Gitea instance running in your local Kubernetes cluster via the domain `gitea.local`, you need to update your `/etc/hosts` file.

### Step 1: Update /etc/hosts

Run the following command to map `gitea.local` to your localhost (or the appropriate ingress IP):

```bash
sudo sh -c 'echo "127.0.0.1 gitea.local" >> /etc/hosts'
```

> **Note:** If you are using a VM or a specific node IP for your cluster, replace `127.0.0.1` with that IP address.

### Step 2: Access Gitea

- **HTTP:** Open your browser and navigate to [http://gitea.local](http://gitea.local).
- **SSH:** Gitea SSH is exposed on port `2222`. You can clone repositories using:
  ```bash
  git clone ssh://git@gitea.local:2222/username/repo.git
  ```
