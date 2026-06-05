# Southpaw's Turbohaul Server

> Curated model server for the Nous Research community. One-command setup for local inference with optimized models.

Fork of [MrTrenchTrucker/turbohaul-manager](https://github.com/MrTrenchTrucker/turbohaul-manager) v0.3.0, adapted to use [AtomicBot's llama.cpp fork](https://github.com/AtomicBot-ai/atomic-llama-cpp-turboquant) for full **TurboQuant TQ3/TQ4 + MTP speculative decoding** support.

## What's Different from Upstream

| Feature | Upstream Turbohaul | Southpaw's Fork |
|---------|-------------------|-----------------|
| llama.cpp fork | Tom's TurboQuant | AtomicBot's (TQ + MTP + NextN) |
| MTP spec decoding | `--spec-type draft-mtp` | `--spec-type nextn` (Qwen3) / `--spec-type mtp` (Gemma 4) |
| TurboQuant weights | TQ1, TQ2 only | TQ1, TQ2, **TQ3_1S, TQ4_1S** |
| Draft block size | N/A | `--draft-block-size B` (drafts B-1 tokens) |
| Curated presets | None | Southpaw's Picks (auto-download + hardware-tier optimization) |
| GPU arch targets | Blackwell (12.0) | RTX 3090/4090 (8.6), RTX 4060/4070 (8.9), Blackwell (12.0) |

## Quick Start

### Docker (Recommended)

```bash
git clone https://github.com/SouthpawIN/southpaw-turbohaul.git
cd southpaw-turbohaul

# Build with AtomicBot's llama.cpp (full TQ3/TQ4 + MTP)
docker build -f Dockerfile.atomic -t turbohaul-southpaw:v0.3.0 .

# Run (mount your models directory)
docker run --gpus all -p 127.0.0.1:11401:11401 \
  -v $(pwd)/state:/var/lib/turbohaul \
  -v ~/Models/storage/gguf:/models \
  turbohaul-southpaw:v0.3.0
```

### Bare Metal (No Docker)

```bash
# 1. Clone and build AtomicBot's llama.cpp
git clone https://github.com/AtomicBot-ai/atomic-llama-cpp-turboquant.git
cd atomic-llama-cpp-turboquant
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)

# 2. Install turbohaul
cd ../southpaw-turbohaul
pip install .
pip install jsonschema==4.21.1

# 3. Run
export LD_LIBRARY_PATH="$(pwd)/../atomic-llama-cpp-turboquant/build/bin:$LD_LIBRARY_PATH"
turbohaul-manager --config docker/turbohaul.default.yaml
```

## Southpaw's Curated Picks

### Main Models (GPU 0 — reasoning, conversation)

| Model | Best For | VRAM | Quant |
|-------|----------|------|-------|
| **Darwin-28B-REASON** | STEM reasoning, GPQA 89.39% | 24GB | Q4_K_M |
| Qwen 3.6 27B | General purpose, tool calling | 24GB | UD-Q4_K_M |

### Auxiliary Models (GPU 1 — fast tasks, tool calling)

| Model | Best For | VRAM | Quant |
|-------|----------|------|-------|
| **APEX-MTP 35B-A3B** | MoE + MTP speculative, 1M ctx | 24GB | I-Compact |
| Qwen 3.6 35B-A3B | Lightweight MoE | 24GB | UD-Q4_K_M |

### Hardware Presets

| Preset | GPUs | VRAM/GPU | Main | Aux |
|--------|------|----------|------|-----|
| `dual-24gb` | 2 | 24GB | Darwin-28B (GPU 0) | APEX-MTP (GPU 1) |
| `single-24gb` | 1 | 24GB | Darwin-28B | APEX-MTP (cpu-moe) |
| `single-16gb` | 1 | 16GB | Darwin-28B Q3 | APEX-MTP I-Mini |
| `single-8gb` | 1 | 8GB | Darwin-28B Q2 | APEX-MTP I-Nano |

## Registering a Curated Model

```bash
# Register Darwin-28B with optimized flags
curl -X PUT http://127.0.0.1:11401/api/manifests/darwin-28b \
  -H "Content-Type: application/json" \
  -d '{
    "model_path": "/models/Darwin-28B-REASON.Q4_K_M.gguf",
    "flags": {
      "n_gpu_layers": 99,
      "ctx_size": 262144,
      "flash_attn": "on",
      "cache_type_k": "q4_0",
      "cache_type_v": "q4_0"
    }
  }'

# Register APEX-MTP with MTP speculative decoding
curl -X PUT http://127.0.0.1:11401/api/manifests/apex-mtp \
  -H "Content-Type: application/json" \
  -d '{
    "model_path": "/models/Qwen3.6-35B-A3B-APEX-MTP-I-Compact.gguf",
    "flags": {
      "n_gpu_layers": 99,
      "cpu_moe": true,
      "ctx_size": 1048576,
      "flash_attn": "on",
      "cache_type_k": "q4_0",
      "cache_type_v": "q4_0",
      "spec_type": "nextn",
      "draft_block_size": 3
    }
  }'
```

## Using with Hermes Agent

```yaml
# config.yaml for any Hermes profile
model:
  provider: custom
  base_url: http://127.0.0.1:11401/v1
  api_key: dummy
  default: darwin-28b

auxiliary:
  provider: custom
  base_url: http://127.0.0.1:11401/v1
  api_key: dummy
  default: apex-mtp
```

## OmniModal Support

When OmniStep 12A3B models become available, they can be registered with:
```bash
curl -X PUT http://127.0.0.1:11401/api/manifests/omnistep \
  -H "Content-Type: application/json" \
  -d '{
    "model_path": "/models/OmniStep-12A3B-Q4_K_M.gguf",
    "flags": {
      "n_gpu_layers": 99,
      "ctx_size": 65536,
      "flash_attn": "on"
    }
  }'
```

## License

MIT (same as upstream Turbohaul-Manager and AtomicBot's llama.cpp fork)
