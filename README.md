# nomad-logs-action

Small GitHub Action that makes requests to a Hashicorp Nomad server and collects logs from a given job.

## Usage

Get logs from a service job

```yml
name: Get logs from Nomad Job
on: [push]
jobs:
  logs:
    name: Nomad Logs
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v1

      - name: Get logs from Nomad
        uses: younited/nomad-logs-action
        with:
          token: ${{ secrets.YOUR_NOMAD_SECRET }}
          address: ${{ secrets.YOUR_NOMAD_SERVER }}
          job: example-job
```

Get logs from a parameterized job in a specific namespace

```yml
name: Get logs from Nomad Job
on: [push]
jobs:
  logs:
    name: Nomad Logs
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v1

      - name: Get logs from Nomad
        uses: younited/nomad-logs-action
        with:
          token: ${{ secrets.YOUR_NOMAD_SECRET }}
          address: ${{ secrets.YOUR_NOMAD_SERVER }}
          job: parameterized-job
          namespace: my-namespace
          parameterized: true
```

Combine with vault-action

```yml
name: Get logs from Nomad Job
on: [push]
jobs:
  logs:
    name: Nomad Logs
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v1

      - name: Get Nomad token from Hashicorp Vault
        uses: hashicorp/vault-action@v2.1.2
        with:
          url: ${{ secrets.YOUR_VAULT_SERVER }}
          method: approle
          roleId: ${{ secrets.VAULT_ROLE_ID }}
          secretId: ${{ secrets.VAULT_SECRET_ID }}
          secrets: |
            nomad/creds/github-action secret_id | NOMAD_TOKEN

      - name: Get logs from Nomad
        uses: younited/nomad-logs-action
        with:
          token: ${{ env.NOMAD_TOKEN }}
          address: ${{ secrets.YOUR_NOMAD_SERVER }}
          job: parameterized-job
          namespace: my-namespace
          parameterized: true
```

## Parameters

- `token`: Token used to authenticate with a nomad server
- `address`: Address of the nomad server
- `namespace`: Namespace of the nomad job
- `job`: Name of the nomad job
- `parameterized`: Set to true if the nomad job is parameterized

## Outputs

- `status`: Indicates the success or failure of the running tasks
- `content`: Displays the task logs from stdout or stderr

## Example of displayed logs

### Success
```
Allocation "1abcd234" (group example-1):
✅ Task example-1 successfully deployed.

Allocation "4901ffe1" (group example-2):
✅ Task example-2 successfully deployed.

Allocation "ba54b3d9" (group example-1):
✅ Task example-1 successfully deployed.
```

### Error
```
Allocation "47445981" (group example-1):
❌ Task example-1 failed:
2021/06/08 17:17:34 [emerg] 1#1: unknown directive "servre" in /etc/nginx/conf.d/status.conf:1
nginx: [emerg] unknown directive "servre" in /etc/nginx/conf.d/status.conf:1

Allocation "48bf3fc1" (group example-2):
✅ Task example-2 successfully deployed.
```

### Out of Memory
```
Allocation "5ab5c4d8" (group example-2):
❌ Task example-2 killed due to out-of-limit resources usage.

```

### Docker Driver Error
```
Allocation "490f2fc1" (group example-1):
✅ Task example-1 successfully deployed.

Allocation "d9f173e5" (group example-2):
❌ Task example-2 failed:
Failed to pull `nginx:1.19.4-oopsie`: API error (404): manifest for nginx:1.19.4-oopsie not found: manifest unknown: manifest unknown
```
