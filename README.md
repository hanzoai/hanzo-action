# Hanzo Deploy Action

Deploy containers to [Hanzo PaaS](https://platform.hanzo.ai) from GitHub Actions.

## Usage

### Deploy a container image

```yaml
- uses: hanzoai/hanzo-action@v1
  with:
    api-key: ${{ secrets.HANZO_API_KEY }}
    org: my-org
    project: my-project
    env: production
    image: ghcr.io/my-org/my-app:${{ github.sha }}
```

### Trigger a build from linked repo

```yaml
- uses: hanzoai/hanzo-action@v1
  with:
    api-key: ${{ secrets.HANZO_API_KEY }}
    org: my-org
    project: my-project
    env: production
    trigger: true
```

### Full example workflow

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and push image
        run: |
          docker build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}

      - name: Deploy to Hanzo
        uses: hanzoai/hanzo-action@v1
        with:
          api-key: ${{ secrets.HANZO_API_KEY }}
          org: my-org
          project: my-project
          env: production
          image: ghcr.io/${{ github.repository }}:${{ github.sha }}
          replicas: 2
          port: 8080
          wait: true
          timeout: 300
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api-key` | Yes | | Hanzo API key or access token |
| `org` | Yes | | Organization ID or name |
| `project` | Yes | | Project ID or name |
| `env` | Yes | `production` | Environment ID or name |
| `image` | No | | Container image to deploy |
| `container` | No | repo name | Container name |
| `trigger` | No | `false` | Trigger build from linked repo |
| `replicas` | No | `1` | Number of replicas |
| `port` | No | `8080` | Container port |
| `wait` | No | `true` | Wait for deployment to be ready |
| `timeout` | No | `300` | Wait timeout in seconds |
| `platform-url` | No | `https://platform.hanzo.ai` | PaaS platform URL |

## Outputs

| Output | Description |
|--------|-------------|
| `container-id` | ID of the deployed container |
| `status` | Deployment status (`success`, `failure`, `timeout`) |

## Authentication

Get an API key from [hanzo.ai](https://hanzo.ai) and add it as a repository secret named `HANZO_API_KEY`.

```bash
# Or use the CLI
hanzo auth login
hanzo auth status
```

MIT OR Apache-2.0, at your option — see [HIP-0137](https://github.com/hanzoai/hips/blob/main/HIPs/hip-0137-one-license.md).
