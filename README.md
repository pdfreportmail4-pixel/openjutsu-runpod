# OpenJutsu RunPod kurulumu

ComfyUI + OpenJutsu + gerekli custom node'lar + modeller (~51 GB), RunPod'da volume olmadan çalışır. İki yol var:

| | A) Her şey RunPod'da | B) Hazır Docker imajı |
|---|---|---|
| Bilgisayarında ne yapıyorsun? | Hiçbir şey kurmuyorsun | Bir kere Docker build + push |
| Her açılışta ne oluyor? | Yazılımlar kurulur + modeller iner | Sadece modeller iner |
| Açılış süresi (tahmin) | ~10–20 dk | ~5–10 dk |

İki yolda da bilgisayarına sadece bağlantı script'i (`windows\baglan.bat`) lazım. Önce **A** ile başla. Açılış süresi can sıkarsa **B**'ye geçersin, template'teki iki alanı değiştirmek yetiyor.

Sabitlenen sürümler: ComfyUI `v0.45.1`, OpenJutsu `7fe118b`, custom node'lar 11 Kasım 2026 tarihli commit'ler (`scripts/install_nodes.sh`). PyTorch CUDA 13.0 build'i.

---

## A) Her şey RunPod'da

### 1. Dosyaları GitHub'a koy (bir kere)

GitHub'da **public** bir repo aç (örn. `openjutsu-runpod`) ve bu klasörün içeriğini yükle. `bootstrap.sh` repo'nun kök dizininde olmalı. Repo'da gizli bilgi yok.

### 2. SSH anahtarı (bir kere)

PowerShell'de:
```powershell
ssh-keygen -t ed25519
Get-Content $HOME\.ssh\id_ed25519.pub
```
Çıkan satırı RunPod'da **Settings → SSH Public Keys** alanına yapıştır.

### 3. RunPod template (bir kere)

**Templates → New Template**:

| Alan | Değer |
|---|---|
| Container Image | `ubuntu:24.04` |
| Container Start Command | aşağıdaki satır |
| Container Disk | **150 GB** |
| Volume Disk | **0** |
| Expose TCP Ports | `22` |
| Expose HTTP Ports | (boş) |

Container Start Command (`KULLANICI` yerine GitHub kullanıcı adını yaz):
```
bash -c "apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && rm -rf /opt/oj && git clone --depth 1 https://github.com/KULLANICI/openjutsu-runpod /opt/oj && bash /opt/oj/bootstrap.sh"
```

### 4. Her seferinde

1. Template'ten **Deploy** et. Filtrelerde **CUDA 13.0+** ve **en az 64 GB RAM** seçili olsun.
2. **Logs** sekmesinde `[setup] 1/5 … 5/5` adımlarını ve model indirmesini izle. `OPENJUTSU READY` yazınca hazır.
3. `windows\baglan.bat` dosyasına çift tıkla ve pod'un **Connect → SSH over exposed TCP** satırını yapıştır.
4. İşin bitince script'te Enter'a bas: videolar `Videolar\openjutsu\<tarih>` klasörüne iner. Sonra pod'u **Terminate** et.

---

## B) Hazır Docker imajı (daha hızlı açılış)

Docker Desktop (WSL2) gerekir, build için en az ~60 GB boş disk olmalı. `KULLANICI` yerine Docker Hub kullanıcı adını yaz:

```powershell
cd C:\AI\openjutsu-runpod
docker build --platform=linux/amd64 -t KULLANICI/openjutsu-runpod:v1 .
docker login
docker push KULLANICI/openjutsu-runpod:v1
```

Build sonunda ComfyUI bütün node'ları CPU'da yükleyip test eder. Zorunlu bir paket yüklenemezse build hata verir.

Template'te iki alan değişiyor:
- **Container Image:** `KULLANICI/openjutsu-runpod:v1`
- **Container Start Command:** boş

Diğer ayarlar A ile aynı.

---

## Ortam değişkenleri (isteğe bağlı, iki yolda da)

| Değişken | Ne işe yarar |
|---|---|
| `SSH_PUBLIC_KEY` | `id_ed25519.pub` dosyasının içeriği. RunPod anahtarı pod'a kendisi aktarmazsa SSH bununla açılır. |
| `HF_TOKEN` | Hugging Face token. RunPod Secrets'a `hf_token` adıyla kaydedip `{{ RUNPOD_SECRET_hf_token }}` yaz. |
| `FIX_FACES_MODELS` | `1` (varsayılan) Fix faces modellerini de indirir, `0` atlar. |
| `COMFY_ARGS` | ComfyUI'ye ek bayrak. **`--highvram` ve `--disable-dynamic-vram` ekleme**, 32 GB kartlarda OOM'a yol açar. |
| `SKIP_MODELS` | `1` model indirmeyi atlar (test için). |

## Elle bağlanma (baglan.bat yerine)

```powershell
ssh -N -L 3000:127.0.0.1:3000 -L 8188:127.0.0.1:8188 -p <PORT> -i $HOME\.ssh\id_ed25519 root@<IP>
```
OpenJutsu: http://127.0.0.1:3000, ComfyUI: http://127.0.0.1:8188.

Videoları elle indirmek için:
```powershell
scp -P <PORT> -i $HOME\.ssh\id_ed25519 -r root@<IP>:/opt/ComfyUI/output .\openjutsu-output
```

Loglar pod'da `/opt/logs/` altında: `models.log`, `comfyui.log`, `proxy.log`, `app.log`, `nodes_install.log`, `next_build.log`.

## Bilinen sınırlar

- **From picture (FLUX) modu:** FLUX modelleri indirilmiyor, OpenJutsu README'sinde indirme linkleri yok. Diğer bütün modlar için gereken her şey var.
- **Model yolları:** DMAD LoRA, int4 text encoder ve int8 video VAE için resmi indirme linki yok. Script bu dosyaları depoda adlarıyla arıyor. Bulamazsa `models.log` dosyasındaki `MISSING` listesinde görünür.
- **InsightFace:** Fix faces'teki InsightFace, `onnxruntime-gpu` CUDA ile açılamazsa CPU'ya düşer. Çalışır ama yavaştır.
- **Pod durunca her şey silinir.** Container disk siliniyor, videoları indirmeden pod'u kapatma.
