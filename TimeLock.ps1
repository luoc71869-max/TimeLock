#requires -Version 5.1
# =====================================================================
#  TimeLock.ps1 -- 时间锁图形界面（WPF）
#  依赖同目录下的 TimeLockCore.ps1
# =====================================================================

$ErrorActionPreference = 'Stop'
$script:TlkAppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:TlkAppDir 'TimeLockCore.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Selected = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$script:OutAuto = $true
$script:NetUtc = $null
$script:Busy = $false
$script:BrushCache = @{}

# ---------------------------------------------------------------------
#  界面
# ---------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="时间锁 · TimeLock" Height="680" Width="900"
        MinHeight="600" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA"
        FontFamily="Microsoft YaHei UI, Microsoft YaHei, Segoe UI" FontSize="13"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#111827"/>
    <SolidColorBrush x:Key="Muted" Color="#6B7280"/>
    <SolidColorBrush x:Key="Line" Color="#E5E7EB"/>
    <SolidColorBrush x:Key="Accent" Color="#2563EB"/>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="7" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.68"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,10"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="7,6"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Padding" Value="7,6"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="Background" Value="#FFFFFF"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="Margin" Value="0,16,0,7"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Padding" Value="18,7"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="2,0,2,10">
      <StackPanel Orientation="Horizontal">
        <Border Width="40" Height="40" CornerRadius="11" Background="#E8EFFE">
          <TextBlock Text="🔒" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="时间锁" FontSize="19" FontWeight="Bold"/>
          <TextBlock Text="到设定时间之前，文件只以密文形式存在" Style="{StaticResource Hint}"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <StackPanel VerticalAlignment="Center" Margin="0,0,10,0">
          <TextBlock x:Name="lblNetTime" Text="网络时间：未校验" FontWeight="SemiBold" HorizontalAlignment="Right"/>
          <TextBlock x:Name="lblNetNote" Text="解锁前必须联网校验" Style="{StaticResource Hint}" HorizontalAlignment="Right"/>
        </StackPanel>
        <Button x:Name="btnRefreshTime" Content="校验" Style="{StaticResource Btn}" VerticalAlignment="Center"/>
      </StackPanel>
    </Grid>

    <TabControl Grid.Row="1" Background="Transparent" BorderThickness="0" Padding="0">

      <TabItem Header="🔒  锁定">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="4,10,4,4">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Margin="0,0,20,0">
              <TextBlock Text="1 · 选择要锁定的文件或文件夹" Style="{StaticResource H1}" Margin="0,0,0,7"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ListBox x:Name="lbItems" Grid.Column="0" Height="152" SelectionMode="Extended"/>
                <StackPanel Grid.Column="1" Width="104" Margin="8,0,0,0">
                  <Button x:Name="btnAddFiles" Content="添加文件" Margin="0,0,0,6" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnAddFolder" Content="添加文件夹" Margin="0,0,0,6" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnRemove" Content="移除所选" Margin="0,0,0,6" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnClear" Content="清空" Style="{StaticResource Btn}"/>
                </StackPanel>
              </Grid>
              <TextBlock x:Name="lblItemSummary" Text="尚未选择任何文件" Style="{StaticResource Hint}" Margin="2,6,0,0"/>

              <TextBlock Text="2 · 设定解锁时间" Style="{StaticResource H1}"/>
              <StackPanel Orientation="Horizontal">
                <DatePicker x:Name="dpDate" Width="168" VerticalAlignment="Center"/>
                <TextBox x:Name="txtTime" Width="76" Margin="8,0,0,0" Text="20:00" HorizontalContentAlignment="Center"/>
              </StackPanel>
              <WrapPanel Margin="0,8,0,0">
                <Button x:Name="btnQ1h" Content="+1 小时" Tag="h1" Margin="0,0,6,0" Style="{StaticResource Btn}"/>
                <Button x:Name="btnQ1d" Content="+1 天" Tag="d1" Margin="0,0,6,0" Style="{StaticResource Btn}"/>
                <Button x:Name="btnQ7d" Content="+7 天" Tag="d7" Margin="0,0,6,0" Style="{StaticResource Btn}"/>
                <Button x:Name="btnQ30d" Content="+30 天" Tag="d30" Style="{StaticResource Btn}"/>
              </WrapPanel>
              <TextBlock x:Name="lblPreview" Text="" Style="{StaticResource Hint}" Margin="2,9,0,0"/>
            </StackPanel>

            <StackPanel Grid.Column="1" Width="378">
              <TextBlock Text="3 · 设置密码" Style="{StaticResource H1}" Margin="0,0,0,7"/>
              <PasswordBox x:Name="pbPass1"/>
              <PasswordBox x:Name="pbPass2" Margin="0,7,0,0"/>
              <TextBlock Text="左：密码　右：确认密码（至少 6 位）" Style="{StaticResource Hint}" Margin="2,5,0,0"/>
              <Border Background="#FFFBEB" BorderBrush="#FDE68A" BorderThickness="1" CornerRadius="7" Padding="10" Margin="0,9,0,0">
                <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="#92400E"
                  Text="⚠ 密码不会被保存，忘记密码后文件无法恢复。留空则为免密模式：同一 Windows 账户可以绕过时间限制，仅适合临时使用。"/>
              </Border>

              <TextBlock Text="4 · 输出与执行" Style="{StaticResource H1}"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="txtOut" Grid.Column="0" IsReadOnly="True" Background="#F9FAFB"/>
                <Button x:Name="btnBrowseOut" Grid.Column="1" Content="另存为…" Margin="8,0,0,0" Style="{StaticResource Btn}"/>
              </Grid>
              <CheckBox x:Name="chkDeleteOriginals" Content="锁定成功后删除原文件（推荐）" IsChecked="True" Margin="2,12,0,0"/>
              <Button x:Name="btnLock" Content="立即锁定" Style="{StaticResource Primary}" Margin="0,14,0,8"/>
              <TextBlock Text="锁定过程完全在本机完成，不会上传任何数据。" Style="{StaticResource Hint}" HorizontalAlignment="Center"/>
            </StackPanel>
          </Grid>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="🔓  解锁">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="4,10,4,4">
          <StackPanel>
            <TextBlock Text="1 · 选择 .tlock 文件" Style="{StaticResource H1}"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="txtLockFile" Grid.Column="0" IsReadOnly="True" Background="#F9FAFB"/>
              <Button x:Name="btnPickLock" Grid.Column="1" Content="浏览…" Margin="8,0,0,0" Style="{StaticResource Btn}"/>
            </Grid>

            <Border x:Name="brdInfo" Visibility="Collapsed" Background="#FFFFFF" BorderBrush="#E5E7EB"
                    BorderThickness="1" CornerRadius="9" Padding="14" Margin="0,12,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="86"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="解锁时间" Foreground="#6B7280" Margin="0,2,0,7"/>
                <TextBlock x:Name="lblInfoTime" Grid.Row="0" Grid.Column="1" FontWeight="SemiBold" Margin="0,2,0,7"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Text="内容" Foreground="#6B7280" Margin="0,2,0,7"/>
                <TextBlock x:Name="lblInfoContent" Grid.Row="1" Grid.Column="1" Margin="0,2,0,7"/>
                <TextBlock Grid.Row="2" Grid.Column="0" Text="加密方式" Foreground="#6B7280" Margin="0,2,0,7"/>
                <TextBlock x:Name="lblInfoMode" Grid.Row="2" Grid.Column="1" Margin="0,2,0,7"/>
                <TextBlock Grid.Row="3" Grid.Column="0" Text="状态" Foreground="#6B7280"/>
                <TextBlock x:Name="lblInfoStatus" Grid.Row="3" Grid.Column="1" FontWeight="SemiBold"/>
              </Grid>
            </Border>

            <TextBlock Text="2 · 输入密码并解锁" Style="{StaticResource H1}"/>
            <PasswordBox x:Name="pbUnlock" MaxWidth="380" HorizontalAlignment="Left" MinWidth="300"/>
            <TextBlock Text="免密模式的容器无需密码，直接留空即可。" Style="{StaticResource Hint}" Margin="2,5,0,0"/>
            <CheckBox x:Name="chkOverwrite" Content="覆盖已存在的同名文件" Margin="2,12,0,0"/>
            <CheckBox x:Name="chkDeleteContainer" Content="解锁成功后删除 .tlock 容器" Margin="2,8,0,0"/>
            <Button x:Name="btnUnlock" Content="⚡  解锁" Style="{StaticResource Primary}" Margin="0,16,0,8"/>
            <TextBlock Text="解锁前会先联网校验当前时间；无法联网时不会解锁。" Style="{StaticResource Hint}" HorizontalAlignment="Center"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem Header="📖  说明">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="4,10,4,4">
          <StackPanel MaxWidth="760" HorizontalAlignment="Left">
            <TextBlock Text="它是怎么工作的" FontSize="15" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <TextBlock TextWrapping="Wrap" LineHeight="22" Foreground="#374151"
              Text="文件会被打包、压缩，再用 AES-256 加密成一个 .tlock 文件。头部记录解锁时间，并由 HMAC-SHA256 保护：任何对时间或密文的修改都会被检测到，直接拒绝解锁。密码通过 PBKDF2（30 万次）派生，不会写入磁盘。"/>

            <TextBlock Text="时间是怎么判定的" FontSize="15" FontWeight="SemiBold" Margin="0,16,0,6"/>
            <TextBlock TextWrapping="Wrap" LineHeight="22" Foreground="#374151"
              Text="解锁时只使用网络时间：优先 NTP（ntp.aliyun.com / cn.pool.ntp.org），失败则回退到 HTTPS 响应头里的服务器时间。完全无视本机时钟，所以改系统时间没有用。多个时间源取中位数，互相差异超过 10 分钟会拒绝执行；同时记录上次校验时间，发现明显回退也会拒绝。无法联网时不会解锁。"/>

            <TextBlock Text="密码与安全性" FontSize="15" FontWeight="SemiBold" Margin="0,16,0,6"/>
            <TextBlock TextWrapping="Wrap" LineHeight="22" Foreground="#374151"
              Text="密码模式：没有密码就无法解密，即使拿到 .tlock 文件也没用。密码不会被保存，忘记密码等于永久丢失数据，请务必记牢或另存到密码管理器。免密模式：随机密钥由 Windows DPAPI 保护，只有创建它的 Windows 账户 + 电脑能解开，安全性较低，适合临时锁一下。"/>

            <TextBlock Text="需要注意" FontSize="15" FontWeight="SemiBold" Margin="0,16,0,6"/>
            <TextBlock TextWrapping="Wrap" LineHeight="22" Foreground="#374151"
              Text="1. 锁定后删除的原文件无法通过本工具恢复（机械硬盘上可能残留数据，SSD 上无法保证彻底擦除）。&#10;2. 请保留好 .tlock 文件，不要改名或编辑；改坏了将无法解锁。&#10;3. 这是本机工具：能拿到 .tlock + 密码的人，可以在别的机器上用同样的格式解密。&#10;4. 免密模式的容器换电脑或换 Windows 账户后无法解锁。&#10;5. 建议保持系统时间自动同步，并对重要文件另做备份。"/>

            <TextBlock Text="关于“防自己”" FontSize="15" FontWeight="SemiBold" Margin="0,16,0,6"/>
            <TextBlock TextWrapping="Wrap" LineHeight="22" Foreground="#374151"
              Text="脚本本身是明文的，懂技术的人可以修改脚本跳过时间检查。但在密码模式下，跳过检查仍然需要密码；本工具只是把“提前打开”这件事变得足够麻烦。"/>

            <TextBlock Text="文件位置" FontSize="15" FontWeight="SemiBold" Margin="0,16,0,6"/>
            <TextBlock x:Name="lblAboutPath" TextWrapping="Wrap" LineHeight="22" Foreground="#6B7280" FontSize="12"/>
            <TextBlock Text="操作日志：timelock.log　　上次校验记录：.timelock-state.json" Style="{StaticResource Hint}" Margin="0,4,0,20"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <Grid Grid.Row="2" Margin="2,12,2,0">
      <StackPanel>
        <ProgressBar x:Name="pbProgress" Height="3" Visibility="Collapsed" IsIndeterminate="True"
                     Foreground="#2563EB" Background="#E5E7EB" BorderThickness="0"/>
        <TextBlock x:Name="lblStatus" Text="就绪" Margin="0,9,0,0" Foreground="#6B7280" TextWrapping="Wrap"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:Win = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    'lblNetTime','lblNetNote','btnRefreshTime',
    'lbItems','btnAddFiles','btnAddFolder','btnRemove','btnClear','lblItemSummary',
    'dpDate','txtTime','btnQ1h','btnQ1d','btnQ7d','btnQ30d','lblPreview',
    'pbPass1','pbPass2','txtOut','btnBrowseOut','chkDeleteOriginals','btnLock',
    'txtLockFile','btnPickLock','brdInfo','lblInfoTime','lblInfoContent','lblInfoMode','lblInfoStatus',
    'pbUnlock','chkOverwrite','chkDeleteContainer','btnUnlock',
    'lblAboutPath','pbProgress','lblStatus'
)
foreach ($n in $names) {
    Set-Variable -Name $n -Value $script:Win.FindName($n) -Scope Script
}

$script:BusyButtons = @(
    $script:btnRefreshTime, $script:btnAddFiles, $script:btnAddFolder, $script:btnRemove, $script:btnClear,
    $script:btnQ1h, $script:btnQ1d, $script:btnQ7d, $script:btnQ30d,
    $script:btnBrowseOut, $script:btnLock, $script:btnPickLock, $script:btnUnlock
)

# ---------------------------------------------------------------------
#  UI 工具
# ---------------------------------------------------------------------
function Get-Brush {
    param([string]$Hex)
    if (-not $script:BrushCache.ContainsKey($Hex)) {
        $script:BrushCache[$Hex] = ([Windows.Media.BrushConverter]::new()).ConvertFromString($Hex)
    }
    return $script:BrushCache[$Hex]
}

function Update-Ui {
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    } catch { }
}

function Set-Status {
    param([string]$Text, [string]$Kind = 'muted')
    $color = switch ($Kind) {
        'ok'   { '#15803D' }
        'err'  { '#B91C1C' }
        'warn' { '#B45309' }
        default { '#6B7280' }
    }
    $script:lblStatus.Text = $Text
    $script:lblStatus.Foreground = Get-Brush $color
    Update-Ui
}

function Set-Busy {
    param([bool]$On, [string]$Text)
    $script:Busy = $On
    foreach ($b in $script:BusyButtons) { if ($b) { $b.IsEnabled = -not $On } }
    $script:pbProgress.Visibility = if ($On) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($Text) { Set-Status $Text 'muted' }
    Update-Ui
}

function Show-Error {
    param([string]$Title, [string]$Message)
    [Windows.MessageBox]::Show($Message, $Title, 'OK', 'Warning') | Out-Null
}

# ---------------------------------------------------------------------
#  业务辅助
# ---------------------------------------------------------------------
function Get-SelectedLocalTime {
    $d = $script:dpDate.SelectedDate
    if ($null -eq $d) { throw '请先选择解锁日期' }
    $ts = [timespan]::Zero
    if (-not [timespan]::TryParse($script:txtTime.Text.Trim(), [ref]$ts)) {
        throw '时间格式无效，请使用 HH:mm（例如 20:30）'
    }
    if ($ts.TotalHours -ge 24 -or $ts.TotalMinutes -lt 0) { throw '时间必须在 00:00 - 23:59 之间' }
    return ([datetime]$d).Date.Add($ts)
}

function Update-UnlockPreview {
    try {
        $local = Get-SelectedLocalTime
        $now = if ($script:NetUtc) { $script:NetUtc.ToLocalTime() } else { Get-Date }
        $span = $local - $now
        if ($span.TotalSeconds -le 0) {
            $script:lblPreview.Text = '⚠ 这个时间已经过去了，锁定会失败'
            $script:lblPreview.Foreground = Get-Brush '#B45309'
        } else {
            $script:lblPreview.Text = ('解锁时间：{0:yyyy-MM-dd HH:mm}　·　距今还有 {1}' -f $local, (Format-Duration $span))
            $script:lblPreview.Foreground = Get-Brush '#6B7280'
        }
    } catch {
        $script:lblPreview.Text = $_.Exception.Message
        $script:lblPreview.Foreground = Get-Brush '#B45309'
    }
}

function Update-NetLabel {
    param($Net)
    if ($Net) {
        $script:lblNetTime.Text = '网络时间：' + $Net.Local.ToString('yyyy-MM-dd HH:mm:ss')
        $script:lblNetTime.Foreground = Get-Brush '#15803D'
        $script:lblNetNote.Text = ('来源 {0} 个 · 互相偏差 {1} 秒' -f $Net.SourceCount, $Net.SpreadSeconds)
        return
    }
    $state = Read-TlkState
    if ($state -and $state.lastNetLocal) {
        $script:lblNetTime.Text = '上次校验：' + $state.lastNetLocal
        $script:lblNetTime.Foreground = Get-Brush '#6B7280'
        $script:lblNetNote.Text = '点击右侧“校验”获取当前网络时间'
    } else {
        $script:lblNetTime.Text = '网络时间：未校验'
        $script:lblNetTime.Foreground = Get-Brush '#6B7280'
        $script:lblNetNote.Text = '解锁前必须联网校验'
    }
}

function Update-ItemSummary {
    $count = $script:Selected.Count
    if ($count -eq 0) {
        $script:lblItemSummary.Text = '尚未选择任何文件'
        $script:ItemFileCount = 0
        $script:ItemBytes = [long]0
        return
    }
    $bytes = [long]0
    $files = 0
    foreach ($p in $script:Selected) {
        try {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            if ($item -is [System.IO.DirectoryInfo]) {
                $children = Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
                foreach ($c in $children) { $bytes += $c.Length; $files++ }
            } else {
                $bytes += $item.Length; $files++
            }
        } catch { }
    }
    $script:ItemFileCount = $files
    $script:ItemBytes = $bytes
    $script:lblItemSummary.Text = ('已选择 {0} 项 · 共 {1} 个文件 · {2}' -f $count, $files, (Format-ByteSize ([double]$bytes)))
}

function Get-DefaultOutPath {
    if ($script:Selected.Count -eq 0) { return '' }
    $first = $script:Selected[0]
    $parent = Split-Path -Parent $first
    if ([string]::IsNullOrEmpty($parent)) { return '' }
    $leaf = Split-Path -Leaf $first
    if ([System.IO.File]::Exists($first)) { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    return (Join-Path $parent ('{0}_{1}.tlock' -f $leaf, $stamp))
}

function Update-OutPath {
    if ($script:OutAuto) {
        $script:txtOut.Text = Get-DefaultOutPath
    }
}

function Update-UnlockInfo {
    param($Hdr, $Net)
    if (-not $Hdr) {
        $script:brdInfo.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $script:brdInfo.Visibility = [Windows.Visibility]::Visible
    $unlockUnix = [long]$Hdr.Meta.unlockUtc
    $script:lblInfoTime.Text = Format-LocalTime $unlockUnix
    $script:lblInfoContent.Text = ('{0} 个文件 · {1}' -f $Hdr.Meta.itemCount, (Format-ByteSize ([double]$Hdr.Meta.totalBytes)))
    $script:lblInfoMode.Text = if ($Hdr.Mode -eq 0) { '密码保护（AES-256 + HMAC）' } else { '免密模式（DPAPI，仅本机本账户）' }

    if (-not $Net) {
        $script:lblInfoStatus.Text = '点击“解锁”后联网校验时间'
        $script:lblInfoStatus.Foreground = Get-Brush '#6B7280'
        return
    }
    $remain = (ConvertFrom-UnixSeconds $unlockUnix) - $Net.Utc
    if ($remain.TotalSeconds -le 0) {
        $script:lblInfoStatus.Text = '✓ 已到解锁时间'
        $script:lblInfoStatus.Foreground = Get-Brush '#15803D'
    } else {
        $script:lblInfoStatus.Text = ('尚未到时间，还剩 {0}' -f (Format-Duration $remain))
        $script:lblInfoStatus.Foreground = Get-Brush '#B45309'
    }
}

function Load-LockFileInfo {
    param([string]$Path)
    try {
        $hdr = Read-TlkHeader -Path $Path
        Update-UnlockInfo $hdr $null
        return $hdr
    } catch {
        $script:brdInfo.Visibility = [Windows.Visibility]::Collapsed
        throw
    }
}

# ---------------------------------------------------------------------
#  事件处理
# ---------------------------------------------------------------------
$script:btnAddFiles.Add_Click({
    if ($script:Busy) { return }
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择要锁定的文件'
        $dlg.Multiselect = $true
        $dlg.Filter = '所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        foreach ($f in $dlg.FileNames) {
            $full = [System.IO.Path]::GetFullPath($f)
            $exists = $false
            foreach ($x in $script:Selected) {
                if ([string]::Equals($x, $full, [StringComparison]::OrdinalIgnoreCase)) { $exists = $true; break }
            }
            if (-not $exists) { $script:Selected.Add($full) }
        }
        Update-ItemSummary
        Update-OutPath
        Set-Status ('已添加文件，共选择 {0} 项' -f $script:Selected.Count) 'muted'
    } catch {
        Show-Error '添加文件失败' $_.Exception.Message
    }
})

$script:btnAddFolder.Add_Click({
    if ($script:Busy) { return }
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择要锁定的文件夹（会递归包含其中所有文件）'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $full = [System.IO.Path]::GetFullPath($dlg.SelectedPath)
        $exists = $false
        foreach ($x in $script:Selected) {
            if ([string]::Equals($x, $full, [StringComparison]::OrdinalIgnoreCase)) { $exists = $true; break }
        }
        if (-not $exists) { $script:Selected.Add($full) }
        Update-ItemSummary
        Update-OutPath
        Set-Status ('已添加文件夹，共选择 {0} 项' -f $script:Selected.Count) 'muted'
    } catch {
        Show-Error '添加文件夹失败' $_.Exception.Message
    }
})

$script:btnRemove.Add_Click({
    if ($script:Busy) { return }
    try {
        $sel = @($script:lbItems.SelectedItems)
        foreach ($s in $sel) { [void]$script:Selected.Remove($s) }
        Update-ItemSummary
        Update-OutPath
    } catch {
        Show-Error '移除失败' $_.Exception.Message
    }
})

$script:btnClear.Add_Click({
    if ($script:Busy) { return }
    $script:Selected.Clear()
    $script:txtOut.Text = ''
    $script:OutAuto = $true
    Update-ItemSummary
    Set-Status '已清空选择' 'muted'
})

$quickHandler = {
    param($sender, $e)
    try {
        $base = $null
        try { $base = Get-SelectedLocalTime } catch { $base = Get-Date }
        switch ([string]$sender.Tag) {
            'h1'  { $base = $base.AddHours(1) }
            'd1'  { $base = $base.AddDays(1) }
            'd7'  { $base = $base.AddDays(7) }
            'd30' { $base = $base.AddDays(30) }
        }
        $script:dpDate.SelectedDate = $base.Date
        $script:txtTime.Text = $base.ToString('HH:mm')
        Update-UnlockPreview
    } catch {
        Set-Status $_.Exception.Message 'warn'
    }
}
$script:btnQ1h.Add_Click($quickHandler)
$script:btnQ1d.Add_Click($quickHandler)
$script:btnQ7d.Add_Click($quickHandler)
$script:btnQ30d.Add_Click($quickHandler)

$script:dpDate.Add_SelectedDateChanged({ param($s, $e) Update-UnlockPreview })
$script:txtTime.Add_TextChanged({ param($s, $e) Update-UnlockPreview })

$script:btnBrowseOut.Add_Click({
    if ($script:Busy) { return }
    try {
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Title = '保存时间锁容器'
        $dlg.Filter = '时间锁容器 (*.tlock)|*.tlock'
        $dlg.DefaultExt = 'tlock'
        $dlg.AddExtension = $true
        $default = $script:txtOut.Text
        if ($default) {
            $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($default)
            $dlg.FileName = [System.IO.Path]::GetFileName($default)
        } else {
            $dlg.FileName = 'lock_' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.tlock'
        }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:txtOut.Text = $dlg.FileName
        $script:OutAuto = $false
    } catch {
        Show-Error '选择输出位置失败' $_.Exception.Message
    }
})

$script:btnRefreshTime.Add_Click({
    if ($script:Busy) { return }
    try {
        Set-Busy $true '正在校验网络时间…'
        $net = Get-TrustedUtc
        $script:NetUtc = $net.Utc
        Update-NetLabel $net
        Update-UnlockPreview
        try { if ($script:txtLockFile.Text) { $h = Load-LockFileInfo $script:txtLockFile.Text; Update-UnlockInfo $h $net } } catch { }
        Set-Status ('网络时间校验成功：{0}（{1} 个来源，互相偏差 {2} 秒）' -f $net.Local.ToString('yyyy-MM-dd HH:mm:ss'), $net.SourceCount, $net.SpreadSeconds) 'ok'
    } catch {
        Set-Status $_.Exception.Message 'err'
        Show-Error '时间校验失败' $_.Exception.Message
    } finally {
        Set-Busy $false
    }
})

$script:btnLock.Add_Click({
    if ($script:Busy) { return }
    try {
        if ($script:Selected.Count -eq 0) { throw '请先添加要锁定的文件或文件夹' }
        $pwd = $script:pbPass1.Password
        if ($pwd -ne $script:pbPass2.Password) { throw '两次输入的密码不一致' }
        if ($pwd.Length -gt 0 -and $pwd.Length -lt 6) { throw '密码至少需要 6 位（或留空使用免密模式）' }

        $localTarget = Get-SelectedLocalTime
        try { $targetUtc = [TimeZoneInfo]::ConvertTimeToUtc($localTarget, [TimeZoneInfo]::Local) }
        catch { throw '这个本地时间无效（可能落在夏令时切换区间），请换一个时间' }
        $targetUnix = [long]([DateTimeOffset]$targetUtc).ToUnixTimeSeconds()

        $outPath = $script:txtOut.Text.Trim()
        if ([string]::IsNullOrEmpty($outPath)) { throw '请选择输出文件位置' }

        Update-ItemSummary
        if ($script:ItemFileCount -eq 0) { throw '所选内容里没有文件' }

        Set-Busy $true '正在校验网络时间…'
        $net = Get-TrustedUtc
        $script:NetUtc = $net.Utc
        Update-NetLabel $net
        $nowLocal = $net.Utc.ToLocalTime()
        if ($targetUnix -le [long](ConvertTo-UnixSeconds $net.Utc)) {
            throw ('解锁时间必须晚于当前时间。当前网络时间：{0}' -f $nowLocal.ToString('yyyy-MM-dd HH:mm:ss'))
        }

        $del = [bool]$script:chkDeleteOriginals.IsChecked
        $modeText = if ($pwd.Length -gt 0) { '密码保护（AES-256）' } else { '免密模式（仅本机本账户，安全性较低）' }
        $msg = '即将锁定 ' + $script:ItemFileCount + ' 个文件（' + (Format-ByteSize ([double]$script:ItemBytes)) + '）。' + "`n`n" +
               '解锁时间：' + $localTarget.ToString('yyyy-MM-dd HH:mm') + "`n" +
               '加密方式：' + $modeText + "`n" +
               $(if ($del) { '锁定后原文件将被删除，无法通过本工具恢复。' } else { '原文件将保留（提醒：这样锁定就没有意义了）。' }) + "`n`n" +
               '确定继续吗？'
        $ans = [Windows.MessageBox]::Show($msg, '确认锁定', 'YesNo', 'Question')
        if ($ans -ne [Windows.MessageBoxResult]::Yes) { return }

        Set-Status '正在加密…'
        $keep = -not $del
        $result = Invoke-TlkLock -Paths @($script:Selected) -UnlockUnix $targetUnix -Password $pwd -OutputPath $outPath `
            -KeepOriginals:$keep -OnProgress {
                param($i, $total, $name)
                Set-Status ('正在加密 {0}/{1}：{2}' -f $i, $total, (Split-Path -Leaf $name))
            }

        $script:Selected.Clear()
        $script:txtOut.Text = ''
        $script:OutAuto = $true
        $script:pbPass1.Clear()
        $script:pbPass2.Clear()
        Update-ItemSummary

        $done = '锁定完成。' + "`n`n" +
                '文件数：' + $result.FileCount + '　大小：' + (Format-ByteSize ([double]$result.TotalBytes)) + "`n" +
                '解锁时间：' + (Format-LocalTime $result.UnlockUnix) + "`n" +
                '容器：' + $result.OutputPath
        if ($result.DeleteFailures.Count -gt 0) {
            $done += "`n`n" + '有 ' + $result.DeleteFailures.Count + ' 个原文件删除失败（请手动处理）：' + "`n" +
                     (($result.DeleteFailures | Select-Object -First 3) -join "`n")
        }
        Set-Status ('锁定完成：' + $result.OutputPath) 'ok'
        [Windows.MessageBox]::Show($done, '锁定成功', 'OK', 'Information') | Out-Null
    } catch {
        Set-Status $_.Exception.Message 'err'
        Show-Error '锁定失败' $_.Exception.Message
    } finally {
        Set-Busy $false
    }
})

$script:btnPickLock.Add_Click({
    if ($script:Busy) { return }
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择 .tlock 文件'
        $dlg.Filter = '时间锁容器 (*.tlock)|*.tlock|所有文件 (*.*)|*.*'
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:txtLockFile.Text = $dlg.FileName
        $hdr = Load-LockFileInfo $dlg.FileName
        Write-TlkLog ("OPEN  $($dlg.FileName)  items=$($hdr.Meta.itemCount)")
        Set-Status ('已载入容器，解锁时间：' + (Format-LocalTime ([long]$hdr.Meta.unlockUtc))) 'muted'
        $script:pbUnlock.Focus() | Out-Null
    } catch {
        Set-Status $_.Exception.Message 'err'
        Show-Error '无法读取容器' $_.Exception.Message
    }
})

$script:pbUnlock.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [Windows.Input.Key]::Enter) {
        $script:btnUnlock.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
    }
})

$script:btnUnlock.Add_Click({
    if ($script:Busy) { return }
    try {
        $path = $script:txtLockFile.Text.Trim()
        if ([string]::IsNullOrEmpty($path) -or -not [System.IO.File]::Exists($path)) { throw '请选择 .tlock 文件' }

        $hdr = Read-TlkHeader -Path $path
        Update-UnlockInfo $hdr $null
        $unlockUnix = [long]$hdr.Meta.unlockUtc

        Set-Busy $true '正在校验网络时间…'
        $net = Get-TrustedUtc
        $script:NetUtc = $net.Utc
        Update-NetLabel $net
        Update-UnlockInfo $hdr $net
        Update-UnlockPreview

        $remain = (ConvertFrom-UnixSeconds $unlockUnix) - $net.Utc
        if ($remain.TotalSeconds -gt 0) {
            $msgWait = ('还没到解锁时间，还剩 {0}。' -f (Format-Duration $remain)) + "`n" +
                       ('解锁时间：{0}（网络时间：{1}）' -f (Format-LocalTime $unlockUnix), $net.Local.ToString('yyyy-MM-dd HH:mm:ss'))
            throw $msgWait
        }

        $pwd = $script:pbUnlock.Password
        if ($hdr.Mode -eq 0 -and [string]::IsNullOrEmpty($pwd)) { throw '这个容器需要密码，请输入密码' }

        $count = [int]$hdr.Meta.itemCount
        $size = Format-ByteSize ([double]$hdr.Meta.totalBytes)
        $ans = [Windows.MessageBox]::Show(
            ('将把 {0} 个文件（{1}）恢复到它们原来的位置。' -f $count, $size) + "`n`n确定继续吗？",
            '确认解锁', 'YesNo', 'Question')
        if ($ans -ne [Windows.MessageBoxResult]::Yes) { return }

        Set-Status '正在解密…'
        $ow = [bool]$script:chkOverwrite.IsChecked
        $delc = [bool]$script:chkDeleteContainer.IsChecked
        $res = Invoke-TlkUnlock -Path $path -Password $pwd -Overwrite:$ow -DeleteContainer:$delc -OnProgress {
                param($i, $total, $name)
                Set-Status ('正在解密 {0}/{1}：{2}' -f $i, $total, (Split-Path -Leaf $name))
            }

        $script:pbUnlock.Clear()
        $done = '已恢复 ' + $res.Restored.Count + ' 个文件。'
        if ($res.Skipped.Count -gt 0) { $done += "`n`n" + '跳过 ' + $res.Skipped.Count + ' 个已存在的文件（未勾选“覆盖”）。' }
        if ($res.Failures.Count -gt 0) {
            $done += "`n`n" + '有 ' + $res.Failures.Count + ' 个问题：' + "`n" + (($res.Failures | Select-Object -First 3) -join "`n")
        }
        Set-Status ('解锁完成：恢复 ' + $res.Restored.Count + ' 个文件') 'ok'
        [Windows.MessageBox]::Show($done, '解锁完成', 'OK', 'Information') | Out-Null

        if ([System.IO.File]::Exists($path)) {
            $h2 = Load-LockFileInfo $path
            Update-UnlockInfo $h2 $net
        } else {
            $script:txtLockFile.Text = ''
            $script:brdInfo.Visibility = [Windows.Visibility]::Collapsed
        }
    } catch {
        Set-Status $_.Exception.Message 'err'
        Show-Error '解锁失败' $_.Exception.Message
    } finally {
        Set-Busy $false
    }
})

$script:Win.Add_Closing({
    param($s, $e)
    if ($script:Busy) {
        $e.Cancel = $true
        [Windows.MessageBox]::Show('正在处理文件，请等待完成后再关闭窗口。', '请稍候', 'OK', 'Information') | Out-Null
    }
})

$script:Win.Add_Loaded({
    try {
        $script:lbItems.ItemsSource = $script:Selected
        $script:dpDate.SelectedDate = (Get-Date).Date.AddDays(1)
        $script:txtTime.Text = '20:00'
        $script:lblAboutPath.Text = '程序目录：' + $script:TlkAppDir
        Update-NetLabel $null
        Update-ItemSummary
        Update-OutPath
        Update-UnlockPreview
        Set-Status '就绪。锁定需要联网校验一次时间，请保持网络可用。' 'muted'
    } catch {
        Show-Error '初始化失败' $_.Exception.Message
    }
})

[void]$script:Win.ShowDialog()

