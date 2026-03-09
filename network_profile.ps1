Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 관리자 권한 체크
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("관리자 권한으로 실행해야 합니다.", "권한 필요")
    exit
}

if ($PSScriptRoot) {
    $basePath = $PSScriptRoot
} else {
    $basePath = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$configPath = Join-Path $basePath "network_profiles.json"

# 스크립트 버전
$scriptVersion = "0.1.0"

function Show-InfoMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, "완료")
}

function Show-ErrorMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, "오류")
}

function Get-Adapters {
    try {
        return Get-NetAdapter |
            Where-Object { $_.Status -ne "Disabled" } |
            Sort-Object Name |
            Select-Object -ExpandProperty Name
    }
    catch {
        return @("이더넷")
    }
}

function Test-Ipv4Address {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $ip = $null
    return [System.Net.IPAddress]::TryParse($Value.Trim(), [ref]$ip)
}

function Test-SubnetMask {
    param([string]$Mask)

    if (-not (Test-Ipv4Address $Mask)) {
        return $false
    }

    try {
        $octets = $Mask.Trim().Split(".") | ForEach-Object { [int]$_ }
        if ($octets.Count -ne 4) { return $false }

        $binary = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        return ($binary -match '^1*0*$')
    }
    catch {
        return $false
    }
}

function Invoke-Netsh {
    param([string]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "netsh.exe"
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $output = ($stdout + "`r`n" + $stderr).Trim()

    if ($process.ExitCode -ne 0) {
        throw "netsh 실행 실패 (ExitCode=$($process.ExitCode))`r`n$Arguments`r`n$output"
    }

    return $output
}

function Reset-AdapterIPv4 {
    param([string]$InterfaceAlias)

    try {
        Invoke-Netsh "interface ipv4 set address name=`"$InterfaceAlias`" source=dhcp" | Out-Null
    } catch {}

    try {
        Invoke-Netsh "interface ipv4 set dnsservers name=`"$InterfaceAlias`" source=dhcp" | Out-Null
    } catch {}

    Start-Sleep -Milliseconds 400
}

function Apply-StaticProfile {
    param(
        [string]$InterfaceAlias,
        [string]$Ip,
        [string]$Mask,
        [string]$Gateway,
        [string]$Dns
    )

    try {

        # 기존 설정 초기화 (충돌 방지)
        netsh interface ip set address name="$InterfaceAlias" dhcp | Out-Null
        netsh interface ip set dns name="$InterfaceAlias" dhcp | Out-Null

        Start-Sleep -Milliseconds 500

        # IP 수동 설정
        netsh interface ip set address name="$InterfaceAlias" static $Ip $Mask $Gateway 1 | Out-Null

        # DNS 수동 설정
        if (-not [string]::IsNullOrWhiteSpace($Dns)) {
            netsh interface ip set dns name="$InterfaceAlias" static $Dns primary | Out-Null
        }

        [System.Windows.Forms.MessageBox]::Show("정적 IP 적용 완료: $InterfaceAlias", "완료")

    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("정적 IP 적용 실패:`r`n$($_.Exception.Message)", "오류")
    }
}

function Apply-DhcpProfile {
    param([string]$InterfaceAlias)

    try {

        # DHCP 설정
        netsh interface ip set address name="$InterfaceAlias" dhcp | Out-Null

        # DNS 자동
        netsh interface ip set dns name="$InterfaceAlias" dhcp | Out-Null

        ipconfig /renew | Out-Null

        [System.Windows.Forms.MessageBox]::Show("DHCP 적용 완료: $InterfaceAlias", "완료")

    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("DHCP 적용 실패:`r`n$($_.Exception.Message)", "오류")
    }
}
function Save-Config {
    $config = @{
        Version = $scriptVersion
        InterfaceAlias = $cmbAdapter.SelectedItem
        Main = @{
            UseDhcp = $chkMainDhcp.Checked
            IP = $txtMainIp.Text
            Mask = $txtMainMask.Text
            Gateway = $txtMainGateway.Text
            DNS = $txtMainDns.Text
        }
        Sub = @{
            IP = $txtSubIp.Text
            Mask = $txtSubMask.Text
            Gateway = $txtSubGateway.Text
            DNS = $txtSubDns.Text
        }
    }

    try {
        $config | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $configPath
        [System.Windows.Forms.MessageBox]::Show("설정 저장 완료`r`n$configPath", "저장")
    }
    catch {
        Show-ErrorMessage "설정 저장 실패:`r`n$($_.Exception.Message)"
    }
}

function Load-Config {
    if (-not (Test-Path $configPath)) { return }

    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json

        if ($config.InterfaceAlias) {
            $targetAlias = [string]$config.InterfaceAlias
            if ($cmbAdapter.Items.Contains($targetAlias)) {
                $cmbAdapter.SelectedItem = $targetAlias
            }
        }

        # 호환성: 새 키(Main/Sub) 우선, 아니면 이전 키(Intranet/Gov) 사용
        if ($config.PSObject.Properties.Name -contains 'Main') {
            $mainCfg = $config.Main
        } elseif ($config.PSObject.Properties.Name -contains 'Intranet') {
            $mainCfg = $config.Intranet
        } else {
            $mainCfg = $null
        }

        if ($config.PSObject.Properties.Name -contains 'Sub') {
            $subCfg = $config.Sub
        } elseif ($config.PSObject.Properties.Name -contains 'Gov') {
            $subCfg = $config.Gov
        } else {
            $subCfg = $null
        }

        if ($mainCfg) {
            $chkMainDhcp.Checked = [bool]$mainCfg.UseDhcp
            $txtMainIp.Text = [string]$mainCfg.IP
            $txtMainMask.Text = [string]$mainCfg.Mask
            $txtMainGateway.Text = [string]$mainCfg.Gateway
            $txtMainDns.Text = [string]$mainCfg.DNS
        }

        if ($subCfg) {
            $txtSubIp.Text = [string]$subCfg.IP
            $txtSubMask.Text = [string]$subCfg.Mask
            $txtSubGateway.Text = [string]$subCfg.Gateway
            $txtSubDns.Text = [string]$subCfg.DNS
        }
    }
    catch {
        Show-ErrorMessage "설정 불러오기 실패:`r`n$($_.Exception.Message)"
    }
}

function Add-LabelTextBox {
    param($parent, $labelText, $x, $y)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labelText
    $label.Location = New-Object System.Drawing.Point($x, $y)
    $label.Size = New-Object System.Drawing.Size(90, 20)
    $parent.Controls.Add($label)

    $textbox = New-Object System.Windows.Forms.TextBox
    $textbox.Location = New-Object System.Drawing.Point(($x + 95), ($y - 3))
    $textbox.Size = New-Object System.Drawing.Size(230, 25)
    $parent.Controls.Add($textbox)

    return $textbox
}

# 폼
$form = New-Object System.Windows.Forms.Form
$form.Text = "네트워크 프로필 전환기 v$scriptVersion"
$form.Size = New-Object System.Drawing.Size(860, 430)
$form.StartPosition = "CenterScreen"
$form.TopMost = $false
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# 어댑터 선택
$lblAdapter = New-Object System.Windows.Forms.Label
$lblAdapter.Text = "어댑터"
$lblAdapter.Location = New-Object System.Drawing.Point(20, 20)
$lblAdapter.Size = New-Object System.Drawing.Size(80, 20)
$form.Controls.Add($lblAdapter)

$cmbAdapter = New-Object System.Windows.Forms.ComboBox
$cmbAdapter.Location = New-Object System.Drawing.Point(100, 18)
$cmbAdapter.Size = New-Object System.Drawing.Size(420, 25)
$cmbAdapter.DropDownStyle = 'DropDownList'
[void]$cmbAdapter.Items.AddRange((Get-Adapters))
if ($cmbAdapter.Items.Count -gt 0) {
    $cmbAdapter.SelectedIndex = 0
}
$form.Controls.Add($cmbAdapter)

# 메인 그룹
$grpMain = New-Object System.Windows.Forms.GroupBox
$grpMain.Text = "메인"
$grpMain.Location = New-Object System.Drawing.Point(20, 60)
$grpMain.Size = New-Object System.Drawing.Size(380, 260)
$form.Controls.Add($grpMain)

$chkMainDhcp = New-Object System.Windows.Forms.CheckBox
$chkMainDhcp.Text = "DHCP 사용"
$chkMainDhcp.Location = New-Object System.Drawing.Point(20, 30)
$chkMainDhcp.Size = New-Object System.Drawing.Size(100, 20)
$chkMainDhcp.Checked = $true
$grpMain.Controls.Add($chkMainDhcp)

$txtMainIp = Add-LabelTextBox -parent $grpMain -labelText "IP 주소" -x 20 -y 70
$txtMainMask = Add-LabelTextBox -parent $grpMain -labelText "서브넷 마스크" -x 20 -y 105
$txtMainGateway = Add-LabelTextBox -parent $grpMain -labelText "기본 게이트웨이" -x 20 -y 140
$txtMainDns = Add-LabelTextBox -parent $grpMain -labelText "DNS" -x 20 -y 175

$btnApplyMain = New-Object System.Windows.Forms.Button
$btnApplyMain.Text = "메인 적용"
$btnApplyMain.Location = New-Object System.Drawing.Point(20, 215)
$btnApplyMain.Size = New-Object System.Drawing.Size(120, 30)
$grpMain.Controls.Add($btnApplyMain)

# 서브 그룹
$grpSub = New-Object System.Windows.Forms.GroupBox
$grpSub.Text = "서브"
$grpSub.Location = New-Object System.Drawing.Point(430, 60)
$grpSub.Size = New-Object System.Drawing.Size(380, 260)
$form.Controls.Add($grpSub)

$txtSubIp = Add-LabelTextBox -parent $grpSub -labelText "IP 주소" -x 20 -y 35
$txtSubMask = Add-LabelTextBox -parent $grpSub -labelText "서브넷 마스크" -x 20 -y 70
$txtSubGateway = Add-LabelTextBox -parent $grpSub -labelText "기본 게이트웨이" -x 20 -y 105
$txtSubDns = Add-LabelTextBox -parent $grpSub -labelText "DNS" -x 20 -y 140

$btnApplySub = New-Object System.Windows.Forms.Button
$btnApplySub.Text = "서브 적용"
$btnApplySub.Location = New-Object System.Drawing.Point(20, 215)
$btnApplySub.Size = New-Object System.Drawing.Size(120, 30)
$grpSub.Controls.Add($btnApplySub)

# 하단 버튼
$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "설정 저장"
$btnSave.Location = New-Object System.Drawing.Point(540, 340)
$btnSave.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnSave)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "설정 불러오기"
$btnLoad.Location = New-Object System.Drawing.Point(680, 340)
$btnLoad.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnLoad)

# 이벤트
$chkMainDhcp.Add_CheckedChanged({
    $enabled = -not $chkMainDhcp.Checked
    $txtMainIp.Enabled = $enabled
    $txtMainMask.Enabled = $enabled
    $txtMainGateway.Enabled = $enabled
    $txtMainDns.Enabled = $enabled
})

$btnApplyMain.Add_Click({
    $iface = [string]$cmbAdapter.SelectedItem

    if ([string]::IsNullOrWhiteSpace($iface)) {
        [System.Windows.Forms.MessageBox]::Show("어댑터를 선택하세요.", "알림")
        return
    }

    if ($chkMainDhcp.Checked) {
        Apply-DhcpProfile -InterfaceAlias $iface
    } else {
        Apply-StaticProfile `
            -InterfaceAlias $iface `
            -Ip $txtMainIp.Text `
            -Mask $txtMainMask.Text `
            -Gateway $txtMainGateway.Text `
            -Dns $txtMainDns.Text
    }
})

$btnApplySub.Add_Click({
    $iface = [string]$cmbAdapter.SelectedItem

    if ([string]::IsNullOrWhiteSpace($iface)) {
        [System.Windows.Forms.MessageBox]::Show("어댑터를 선택하세요.", "알림")
        return
    }

    Apply-StaticProfile `
        -InterfaceAlias $iface `
        -Ip $txtSubIp.Text `
        -Mask $txtSubMask.Text `
        -Gateway $txtSubGateway.Text `
        -Dns $txtSubDns.Text
})

$btnSave.Add_Click({ Save-Config })
$btnLoad.Add_Click({ Load-Config })

# 기본값
$txtSubIp.Text = "본인 ip 입력"
$txtSubMask.Text = "255.255.255.224"
$txtSubGateway.Text = "10.46.31.65"
$txtSubDns.Text = "10.1.1.5"

$chkMainDhcp.Checked = $true
Load-Config

# 초기 UI 상태 반영
$enabled = -not $chkMainDhcp.Checked
$txtMainIp.Enabled = $enabled
$txtMainMask.Enabled = $enabled
$txtMainGateway.Enabled = $enabled
$txtMainDns.Enabled = $enabled

[void]$form.ShowDialog()