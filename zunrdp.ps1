Param(
    [string]$Owner,
    [string]$MachineID
)

# --- CẤU HÌNH CƠ BẢN ---
# Tắt cảnh báo bảo mật RDP để dễ login
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# URL Database (Phải khớp với code HTML)
$DB_URL = "https://zunrdp-default-rtdb.asia-southeast1.firebasedatabase.app"

# Thông tin tài khoản (Cố định để hiện lên Web)
$User = "ZunRdp"
$Pass = "CloudAccess@2026!#"

Write-Host "--- ZUNRDP AGENT STARTING ---" -ForegroundColor Cyan

# --- GIAI ĐOẠN 1: TÌM IP TAILSCALE ---
$IP = "Đang lấy IP..."
$RetryCount = 0

while ($RetryCount -lt 20) {
    try {
        # Lấy địa chỉ IPv4 từ Tailscale (thường bắt đầu bằng 100.)
        $tsPath = "C:\Program Files\Tailscale\tailscale.exe"
        if (Test-Path $tsPath) {
            $rawIP = (& $tsPath ip -4)
            if ($rawIP -match "100\.") {
                $IP = $rawIP.Trim()
                Write-Host "Got IP: $IP" -ForegroundColor Green
                break
            }
        }
    } catch {}
    Start-Sleep -Seconds 3
    $RetryCount++
}

# --- GIAI ĐOẠN 2: GỬI THÔNG TIN KHỞI TẠO (PUT) ---
# Dùng phương thức PUT để tạo mới dữ liệu máy ảo
$vmInfo = @{
    id      = $MachineID
    owner   = $Owner
    ip      = $IP
    user    = $User
    pass    = $Pass
    cpu     = 0
    ram     = 0
    status  = "Running"
    created = [int64](Get-Date -UFormat %s) * 1000
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod -Uri "$DB_URL/vms/$MachineID.json" -Method Put -Body $vmInfo -ContentType "application/json"
    Write-Host "Sent Initial Info to Firebase" -ForegroundColor Green
} catch {
    Write-Host "Error sending info: $_" -ForegroundColor Red
}

# --- GIAI ĐOẠN 3: VÒNG LẶP MONITOR & CONTROL (REALTIME) ---
while ($true) {
    try {
        # 1. Tính toán CPU & RAM
        $cpu = [int](Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        
        $os = Get-WmiObject Win32_OperatingSystem
        $totalRam = $os.TotalVisibleMemorySize
        $freeRam = $os.FreePhysicalMemory
        $ramUsage = [int][Math]::Round((($totalRam - $freeRam) / $totalRam) * 100)

        # 2. Gửi dữ liệu cập nhật (PATCH)
        # Chỉ gửi CPU/RAM để không ghi đè IP/User/Pass
        $updateData = @{
            cpu = $cpu
            ram = $ramUsage
        } | ConvertTo-Json -Compress

        Invoke-RestMethod -Uri "$DB_URL/vms/$MachineID.json" -Method Patch -Body $updateData -ContentType "application/json"
        
        Write-Host "Updated -> CPU: $cpu% | RAM: $ramUsage%" -ForegroundColor Gray

        # 3. Kiểm tra lệnh hủy (Kill Switch)
        # Web sẽ gửi lệnh vào node /commands/ID
        $cmdCheck = Invoke-RestMethod -Uri "$DB_URL/commands/$MachineID.json" -ErrorAction SilentlyContinue
        
        if ($cmdCheck -and $cmdCheck.action -eq "stop") {
            Write-Host "KILL COMMAND RECEIVED!" -ForegroundColor Red
            
            # Xóa dữ liệu máy ảo trên Firebase trước khi chết
            Invoke-RestMethod -Uri "$DB_URL/vms/$MachineID.json" -Method Delete
            Invoke-RestMethod -Uri "$DB_URL/commands/$MachineID.json" -Method Delete
            
            # Tắt máy
            Stop-Computer -Force
            break
        }

    } catch {
        Write-Host "Connection Glitch..." -ForegroundColor Yellow
    }

    # Đợi 5 giây trước khi cập nhật tiếp (Để biểu đồ chạy mượt)
    Start-Sleep -Seconds 5
}
