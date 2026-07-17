# GeneralContainer

Universal `linux/amd64` GPU development image based on `nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04`. It reproduces the SUPER-GIANT container startup flow with project-specific Git and S3 locations moved to runtime environment variables.

## Included

- CUDA 12.8.0, cuDNN development libraries, NVCC, and the standard CUDA build toolchain
- Python 3.13 in `/opt/venv`
- JAX 0.11.0 with CUDA 12 support and Flax 0.12.7
- PyTorch 2.11.0+cu128 and torchvision 0.26.0+cu128 — the newest matching pair on the CUDA 12.8 wheel index when prepared
- Transformers, Datasets, Optax, OmegaConf, KaggleHub, and Hugging Face Hub
- Node.js 24 and npm
- Tailscale with Tailscale SSH, s5cmd 2.3.0, Git, OpenSSH client, curl, wget, build tools, `vim`, `tmux`, and `ripgrep`
- `/proj` as the working directory; the Python virtual environment is active by default

The image intentionally contains both JAX and PyTorch CUDA stacks, so expect a large image and a long first pull.

## Startup flow

Every container start performs these steps in order:

1. If `S3_URI` is set, sync data into `DATA_DIR` (`/proj/data`).
2. If `GIT_REPO_URL` is set, clone or update it in `GIT_REPO_DIR` (`/proj/project`) and install it editable when it has `pyproject.toml` or `setup.py`.
3. Start Tailscale in userspace mode and enable Tailscale SSH by default.
4. If `${S3_URI}/entrypoint.sh` exists, download and run it. `S3_ENTRYPOINT_URI` can override that object URI.
5. Run the supplied container command, or `sleep infinity` when no command was supplied.

Only point `S3_URI` at a trusted bucket because its `entrypoint.sh`, when present, is executable startup code.

## Run

Copy `.env.minimal` to `.env` and fill its six values. `.env.example` contains the optional overrides.

```bash
docker run --pull always -d --gpus all \
  --name general-container \
  --mount type=bind,source="$HOME/proj",target=/proj \
  --env-file .env \
  ghcr.io/debeltoni/general-container:latest

docker exec -it general-container tmux
```

For Tailscale SSH, persist daemon state if desired:

```bash
--mount type=volume,source=tailscale-state,target=/var/lib/tailscale
```

The host needs an NVIDIA driver compatible with CUDA 12.8.

## Runtime variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `GIT_REPO_URL` | empty | HTTPS or SSH Git clone URL; an empty value skips Git sync. |
| `GIT_REPO_DIR` | `/proj/project` | Clone destination. |
| `GIT_CLONE_DEPTH` | `1` | Clone/fetch depth. |
| `S3_URI` | empty | `s3://bucket` or `s3://bucket/prefix`; an empty value skips S3. |
| `DATA_DIR` | `/proj/data` | Local S3 destination. |
| `SYNC_DIRS` | empty | Comma-separated relative prefixes/files. A trailing `/` marks a prefix. Empty means full sync. |
| `FORCE_SYNC` | `0` | `1` or `true` removes the matching sync marker and downloads again. |
| `S3_ENTRYPOINT_URI` | `${S3_URI}/entrypoint.sh` | Optional startup script object. |
| `TS_AUTHKEY` | empty | Tailscale auth key. Without one, `tailscale up` emits an interactive login URL. |
| `TS_HOSTNAME` | `gpu-box` | Tailnet device name. |
| `TS_TAGS` | `tag:gpu` | Advertised Tailscale tags. |
| `TS_ACCEPT_DNS` | `false` | Tailscale DNS setting. |
| `TS_ENABLE_SSH` | `true` | Enables Tailscale SSH. |
| `TS_EXTRA_ARGS` | empty | Extra space-separated arguments for `tailscale up`. |

Use standard AWS variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`) for S3 authentication. Set `S3_ENDPOINT_URL` for R2, MinIO, or another S3-compatible endpoint.

When `${S3_URI}/sync_dirs.txt` exists, its newline-separated contents override `SYNC_DIRS`. An existing empty file explicitly syncs nothing; a missing file plus empty `SYNC_DIRS` syncs the full source. Markers under `DATA_DIR` prevent repeat downloads for the same source/list unless `FORCE_SYNC=1`.

## Build and publishing

```bash
docker build --platform linux/amd64 -t general-container .
```

`.github/workflows/Build_images.yml` retains the source workflow's runner disk cleanup and publishes `latest` plus commit-SHA tags to both Docker Hub and GHCR. Add these under **Settings → Secrets and variables → Actions → Repository secrets** before the first push:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

The Docker Hub target is `<DOCKERHUB_USERNAME>/general-container`; the GHCR target is `ghcr.io/debeltoni/general-container`.
