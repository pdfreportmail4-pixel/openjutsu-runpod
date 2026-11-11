# OpenJutsu'ya baglanir: pod'a SSH tuneli acar, tarayiciyi baslatir,
# kapatirken uretilen videolari bilgisayarina indirir.

$key = Join-Path $HOME ".ssh\id_ed25519"
$kh  = Join-Path $HOME ".ssh\runpod_known_hosts"

Write-Host ""
Write-Host "RunPod > pod > Connect > 'SSH over exposed TCP' satırını yapıştır."
Write-Host "Örnek: ssh root@213.173.98.12 -p 17845 -i ~/.ssh/id_ed25519"
$line = Read-Host "SSH komutu"

if ($line -match 'root@([0-9.]+)') { $ip = $Matches[1] } else { $ip = Read-Host "Pod IP" }
if ($line -match '-p\s+(\d+)') { $port = $Matches[1] } else { $port = Read-Host "SSH port" }

# Her pod yeni bir anahtar üretir; aynı IP:port eski bir pod'a aitse kaydını sil.
if (Test-Path $kh) { ssh-keygen -R "[$ip]:$port" -f $kh 2>&1 | Out-Null }

$sshArgs = "-N -o StrictHostKeyChecking=accept-new -o `"UserKnownHostsFile=$kh`" " +
           "-o ServerAliveInterval=30 -o ExitOnForwardFailure=yes " +
           "-L 3000:127.0.0.1:3000 -L 8188:127.0.0.1:8188 " +
           "-p $port -i `"$key`" root@$ip"
$ssh = Start-Process -FilePath "ssh" -ArgumentList $sshArgs -NoNewWindow -PassThru

Write-Host "Tünel açılıyor..."
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    if ($ssh.HasExited) { break }
    try {
        Invoke-WebRequest "http://127.0.0.1:3000" -UseBasicParsing -TimeoutSec 3 | Out-Null
        $ready = $true
        break
    } catch { Start-Sleep -Seconds 2 }
}

if ($ssh.HasExited) {
    Write-Host "SSH bağlanamadı. IP/port'u ve RunPod'daki SSH anahtarını kontrol et." -ForegroundColor Red
    exit 1
}
if ($ready) {
    Write-Host "Bağlandı: http://127.0.0.1:3000 (ComfyUI: http://127.0.0.1:8188)" -ForegroundColor Green
} else {
    Write-Host "Tünel açık ama OpenJutsu henüz yanıt vermiyor. RunPod Logs'ta 'OPENJUTSU READY' görünce sayfayı yenile." -ForegroundColor Yellow
}
Start-Process "http://127.0.0.1:3000"

Write-Host ""
Read-Host "İşin bitince videoları indirip bağlantıyı kapatmak için Enter'a bas"

$dest = Join-Path ([Environment]::GetFolderPath("MyVideos")) ("openjutsu\" + (Get-Date -Format "yyyy-MM-dd_HH-mm"))
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Write-Host "Videolar indiriliyor: $dest"
& scp -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$kh" -P $port -i $key -r "root@${ip}:/opt/ComfyUI/output" $dest

Stop-Process -Id $ssh.Id -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Tamam. Videolar: $dest" -ForegroundColor Green
Write-Host "Pod'u RunPod'dan Terminate etmeyi unutma." -ForegroundColor Yellow
