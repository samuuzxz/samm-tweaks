function Get-UTMemoryRatedSpeed {
    <#
    .SYNOPSIS
        The rated (XMP / EXPO) speed a memory part number spells out, or 0 when it does not say.
    .DESCRIPTION
        Windows only reports the speed the memory runs at and its JEDEC fallback, never the XMP profile,
        so the kit's own part number is the one place the rated speed shows up. Only the naming schemes
        that encode it unambiguously are read; anything else returns 0 and the caller falls back to the
        JEDEC-default heuristic instead of guessing.
    #>
    param([string]$PartNumber)
    $p = ([string]$PartNumber).Trim().ToUpperInvariant()
    if (-not $p) { return 0 }
    # G.Skill F4-3600C16..., F5-6000J3038...
    if ($p -match '^F[45]-(\d{4})[A-Z]') { return [int]$Matches[1] }
    # Kingston FURY KF436C17BB/8 (DDR4-3600), KF560C40BBK2-32 (DDR5-6000)
    if ($p -match '^KF[45](\d{2})C') { return [int]$Matches[1] * 100 }
    # Corsair CMK16GX4M2B3200C16, CMH32GX5M2B6000C30
    if ($p -match '^CM[A-Z]+\d+GX[45]M\d[A-Z](\d{4})C') { return [int]$Matches[1] }
    # Crucial Ballistix BL8G32C16U4B, BL2K8G36C16U4B
    if ($p -match '^BL\d*K?\d+G(\d{2})C\d') { return [int]$Matches[1] * 100 }
    # TeamGroup T-Force TF3D416G3600HC18J, TeamGroup UD5-6000
    if ($p -match '^TF\w*?G(\d{4})HC') { return [int]$Matches[1] }
    return 0
}

function Get-UTMemoryChannel {
    <#
    .SYNOPSIS
        The channel letter a DIMM sits in, read from the board's own slot labels, or '' when they do not say.
    .DESCRIPTION
        Boards label slots differently: "P0 CHANNEL A" / "DIMM_A2" (ASUS, AMD), "Controller0-ChannelA-DIMM0"
        (Intel), "ChannelB-DIMM1". Anything that does not name a channel returns '' and the caller then
        makes no claim about channels at all.
    #>
    param([string]$BankLabel, [string]$DeviceLocator)
    $text = ('{0} {1}' -f $BankLabel, $DeviceLocator)
    if ($text -match '(?i)channel\s*([A-H])(?![A-Z])') { return $Matches[1].ToUpperInvariant() }
    if ($text -match '(?i)\bDIMM[_\s-]?([A-H])\d') { return $Matches[1].ToUpperInvariant() }
    return ''
}

function Get-UTGpuKind {
    <#
    .SYNOPSIS
        'discrete', 'integrated', 'basic' (no driver) or 'other' for a display adapter name.
    #>
    param([string]$Name)
    if ($Name -match 'Microsoft Basic Display|Microsoft Basic Render') { return 'basic' }
    if ($Name -match 'NVIDIA|GeForce|Quadro|Radeon RX|Radeon Pro|Radeon R9|Radeon HD|Arc\(TM\) [AB]\d|Arc [AB]\d') { return 'discrete' }
    if ($Name -match 'Intel|Radeon|AMD|Vega') { return 'integrated' }
    return 'other'
}

function Get-UTFpsDoctorFacts {
    <#
    .SYNOPSIS
        Reads, and only reads, the things that cap frame rate below what the hardware can do: memory speed
        and channels, which GPU drives the monitor, the GPU's PCIe link, the refresh rate, power source,
        Fortnite's own cap, renderer and GPU assignment. Every probe is independent and a failed one
        leaves its field empty, so the findings only ever talk about what was actually measured.
    #>
    $f = [ordered]@{
        IsLaptop = $false; RamGB = 0; VBS = $false; OnBattery = $false; PowerSaver = $false
        MemoryType = ''; MemoryMTs = 0; MemoryRatedMTs = 0; DimmCount = 0; DimmChannels = @()
        Gpus = @(); DisplayGpu = ''; PcieWidth = 0; PcieMaxWidth = 0; PcieGpu = ''
        Hz = 0; MaxHzAtRes = 0; Width = 0; Height = 0
        FnInstalled = $false; FnIniExists = $false; FnFrameRateLimit = $null; FnVSync = ''; FnFullscreenMode = ''
        FnRHI = ''; FnFeatureLevel = ''; FnRayTracing = ''; FnNanite = ''
        FnReflex = ''; FnMeshQuality = ''; FnViewDistance = ''; FnShadows = ''; FnEffects = ''
        FnExe = ''; FnGpuPreference = ''; FnOnHdd = $false
        IsWiFi = $false; Region = ''; RegionMs = $null; RegionJitterMs = $null; RegionLossPct = $null
    }
    $si = $sync.sysinfo
    if ($si) {
        $f.IsLaptop = [bool]$si.IsLaptop
        $f.RamGB = [double]$si.RamGB
        $f.VBS = ([int]$si.VBSStatus -eq 2 -or [bool]$si.HVCIRunning)
    }

    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $f.DimmCount = $sticks.Count
        $types = @($sticks | ForEach-Object { [int]$_.SMBIOSMemoryType } | Sort-Object -Unique)
        if ($types -contains 34) { $f.MemoryType = 'DDR5' } elseif ($types -contains 26) { $f.MemoryType = 'DDR4' } elseif ($types -contains 24) { $f.MemoryType = 'DDR3' }
        # The slowest stick sets the speed of the whole set.
        $cur = @($sticks | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 } | Sort-Object)
        if ($cur.Count) { $f.MemoryMTs = $cur[0] }
        # Some firmware reports the clock in MHz rather than MT/s, which reads as half the real speed.
        if ($f.MemoryType -eq 'DDR4' -and $f.MemoryMTs -gt 0 -and $f.MemoryMTs -lt 1800) { $f.MemoryMTs *= 2 }
        if ($f.MemoryType -eq 'DDR5' -and $f.MemoryMTs -gt 0 -and $f.MemoryMTs -lt 3600) { $f.MemoryMTs *= 2 }
        $rated = @($sticks | ForEach-Object { Get-UTMemoryRatedSpeed -PartNumber ([string]$_.PartNumber) } | Where-Object { $_ -gt 0 } | Sort-Object)
        if ($rated.Count) { $f.MemoryRatedMTs = $rated[0] }
        $f.DimmChannels = @($sticks | ForEach-Object { Get-UTMemoryChannel -BankLabel ([string]$_.BankLabel) -DeviceLocator ([string]$_.DeviceLocator) })
    } catch { }

    try {
        foreach ($g in (Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if (-not $g.Name) { continue }
            $drives = ([int]$g.CurrentHorizontalResolution -gt 0)
            $f.Gpus += [pscustomobject]@{ Name = [string]$g.Name; Kind = (Get-UTGpuKind -Name ([string]$g.Name)); DrivesDisplay = $drives; PnpId = [string]$g.PNPDeviceID }
            if ($drives -and -not $f.DisplayGpu) { $f.DisplayGpu = [string]$g.Name }
        }
    } catch { }

    # The negotiated link against the GPU's own capability. DEVPKEY_PciDevice_MaxLinkWidth is what the
    # card supports, not what the slot supports, so a card in a x4 chipset slot reads x4 of x16 here.
    $dgpu = @($f.Gpus | Where-Object { $_.Kind -eq 'discrete' -and $_.PnpId }) | Select-Object -First 1
    if ($dgpu) {
        try {
            $props = @(Get-PnpDeviceProperty -InstanceId $dgpu.PnpId -ErrorAction Stop)
            foreach ($p in $props) {
                if ($p.KeyName -eq 'DEVPKEY_PciDevice_CurrentLinkWidth') { $f.PcieWidth = [int]$p.Data }
                if ($p.KeyName -eq 'DEVPKEY_PciDevice_MaxLinkWidth') { $f.PcieMaxWidth = [int]$p.Data }
            }
            $f.PcieGpu = $dgpu.Name
        } catch { }
    }

    if ('UT.NativeV1.Display' -as [type]) {
        try {
            $cur = [UT.NativeV1.Display]::GetCurrent()
            $f.Width = [int]$cur.Width; $f.Height = [int]$cur.Height; $f.Hz = [int]$cur.Hz
            $rates = @([UT.NativeV1.Display]::EnumModes() | Where-Object { $_.Width -eq $cur.Width -and $_.Height -eq $cur.Height } | ForEach-Object { [int]$_.Hz } | Sort-Object -Descending)
            if ($rates.Count) { $f.MaxHzAtRes = $rates[0] }
        } catch { }
    }

    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        # BatteryStatus 1 is "discharging", i.e. running on the battery right now.
        if ($bat.Count -and (@($bat | Where-Object { [int]$_.BatteryStatus -eq 1 }).Count -gt 0)) { $f.OnBattery = $true }
    } catch { }
    try {
        $scheme = (Invoke-UTNative -FilePath 'powercfg.exe' -Arguments @('/getactivescheme')).Output
        # The GUID, not the name: plan names are translated on non-English Windows.
        if ($scheme -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { $f.PowerSaver = $true }
    } catch { }

    try { $f.IsWiFi = [bool](Get-UTNetworkLink).IsWiFi } catch { }
    # The region measurement runs in the background at start-up; the doctor reuses it rather than
    # pinging again, and says so when it has not finished.
    $best = @($sync.regions | Where-Object { $_ -and $_.Host -like '*epicgames.com' -and $null -ne $_.AvgMs }) | Select-Object -First 1
    if ($best) { $f.Region = [string]$best.Region; $f.RegionMs = [double]$best.AvgMs; $f.RegionJitterMs = [double]$best.JitterMs; $f.RegionLossPct = [double]$best.LossPct }

    try {
        $fn = Get-UTFortnite
        $f.FnInstalled = [bool]$fn.Installed
        $f.FnIniExists = [bool]$fn.GameIniExists
        if ($fn.GameIniExists) {
            $ini = Read-UTIniFile -Path $fn.GameIni
            $main = $ini.Sections[[string]$sync.configs.fortnite.MainSection]
            if ($main) {
                if ($main.ContainsKey('FrameRateLimit')) {
                    $v = 0.0
                    if ([double]::TryParse(([string]$main['FrameRateLimit']).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $f.FnFrameRateLimit = $v }
                }
                if ($main.ContainsKey('bUseVSync')) { $f.FnVSync = ([string]$main['bUseVSync']).Trim() }
                if ($main.ContainsKey('FullscreenMode')) { $f.FnFullscreenMode = ([string]$main['FullscreenMode']).Trim() }
                if ($main.ContainsKey('bRayTracing')) { $f.FnRayTracing = ([string]$main['bRayTracing']).Trim() }
                if ($main.ContainsKey('bUseNanite')) { $f.FnNanite = ([string]$main['bUseNanite']).Trim() }
                if ($main.ContainsKey('LatencyTweak2')) { $f.FnReflex = ([string]$main['LatencyTweak2']).Trim() }
            }
            $sg = $ini.Sections['ScalabilityGroups']
            if ($sg) {
                if ($sg.ContainsKey('sg.ViewDistanceQuality')) { $f.FnViewDistance = ([string]$sg['sg.ViewDistanceQuality']).Trim() }
                if ($sg.ContainsKey('sg.ShadowQuality')) { $f.FnShadows = ([string]$sg['sg.ShadowQuality']).Trim() }
                if ($sg.ContainsKey('sg.EffectsQuality')) { $f.FnEffects = ([string]$sg['sg.EffectsQuality']).Trim() }
            }
            $pm = $ini.Sections['PerformanceMode']
            if ($pm -and $pm.ContainsKey('MeshQuality')) { $f.FnMeshQuality = ([string]$pm['MeshQuality']).Trim() }
            $rhi = $ini.Sections['D3DRHIPreference']
            if ($rhi) {
                if ($rhi.ContainsKey('PreferredRHI')) { $f.FnRHI = ([string]$rhi['PreferredRHI']).Trim() }
                if ($rhi.ContainsKey('PreferredFeatureLevel')) { $f.FnFeatureLevel = ([string]$rhi['PreferredFeatureLevel']).Trim() }
            }
        }
        $exe = Get-UTFortniteExePath -InstallLocation $fn.InstallLocation
        if ($exe) {
            $f.FnExe = $exe
            $pref = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name $exe -ErrorAction SilentlyContinue
            if ($pref) { $f.FnGpuPreference = [string]$pref.$exe }
        }
        if ($fn.InstallLocation -match '^([A-Za-z]):') {
            $disk = Get-Partition -DriveLetter $Matches[1] -ErrorAction Stop | Get-Disk -ErrorAction Stop
            $phys = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $disk.Number } | Select-Object -First 1
            $f.FnOnHdd = ([string]$phys.MediaType -eq 'HDD')
        }
    } catch { }

    return [pscustomobject]$f
}

function Get-UTFortniteExePath {
    param([string]$InstallLocation)
    if (-not $InstallLocation) { return '' }
    # Plain concatenation: Join-Path throws when the drive letter is not mounted right now.
    return ($InstallLocation.TrimEnd('\', '/') + '\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe')
}

function Get-UTFpsDoctorFindings {
    <#
    .SYNOPSIS
        Turns the facts into findings, worst first. Pure: no I/O, so every rule is unit-tested.
    .DESCRIPTION
        Severity: 'fix' is a real cap on frame rate with a known fix, 'warn' is probable and worth
        checking, 'info' is context, 'ok' is a check that passed (listed so the reader can see what was
        looked at). Impact is deliberately qualitative: the size of each gain depends on how CPU-bound
        the machine is, and a number here would be invented.
    #>
    param([Parameter(Mandatory = $true)]$Facts)
    $f = $Facts
    $out = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Severity, $Area, $Title, $Detail, $Action, $Impact)
        $out.Add([pscustomobject]@{ Severity = $Severity; Area = $Area; Title = $Title; Detail = $Detail; Action = $Action; Impact = $Impact })
    }

    # --- Fortnite's own settings: the cheapest fixes, and the most common reason for a "stuck" number.
    if ($null -ne $f.FnFrameRateLimit) {
        if ($f.FnFrameRateLimit -gt 0) {
            $cap = [int][math]::Round($f.FnFrameRateLimit)
            & $add 'fix' 'Fortnite' ("Fortnite is capped at {0} FPS" -f $cap) ("FrameRateLimit={0} in GameUserSettings.ini. If your counter sits at {0}, this cap is the whole reason: no tweak can push past it." -f $cap) 'FORTNITE tab: Max FPS profile (uncapped), or set Frame Rate Limit to Unlimited in the Video menu. A cap just under your average gives smoother frame times, so uncap only if you want the higher number.' 'removes the ceiling'
        } else {
            & $add 'ok' 'Fortnite' 'Fortnite frame rate is uncapped' '' '' ''
        }
    }
    if ($f.FnVSync -match '^(?i)true$') {
        & $add 'fix' 'Fortnite' 'VSync is on in Fortnite' 'VSync holds the frame rate at the monitor refresh rate and adds input latency.' 'FORTNITE tab: any profile turns it off.' 'removes the ceiling'
    }
    if ($f.FnFeatureLevel -and $f.FnFeatureLevel -notmatch '^(?i)es31$') {
        $renderer = 'DirectX 12'
        if ($f.FnRHI -match '^(?i)dx11$') { $renderer = 'DirectX 11' }
        & $add 'fix' 'Fortnite' ("Fortnite runs the full {0} renderer, not Performance Mode" -f $renderer) 'Performance Mode is a lighter renderer built for high frame rates and is what almost every competitive player uses. On a CPU-bound PC it is usually the largest single FPS change available in the game.' 'FORTNITE tab: Max FPS profile (Performance Mode), or Rendering Mode = Performance in the Video menu.' 'large'
    } elseif ($f.FnFeatureLevel) {
        & $add 'ok' 'Fortnite' 'Fortnite uses Performance Mode' '' '' ''
    }
    if ($f.FnRayTracing -match '^(?i)true$') {
        & $add 'fix' 'Fortnite' 'Hardware ray tracing is on' 'Ray tracing is the most expensive setting Fortnite has.' 'FORTNITE tab: any profile turns it off.' 'large'
    }
    if ($f.FnNanite -match '^(?i)true$' -and ($f.FnFeatureLevel -notmatch '^(?i)es31$')) {
        & $add 'warn' 'Fortnite' 'Nanite virtualized geometry is on' 'Nanite is heavy on the GPU at high frame rates.' 'FORTNITE tab: Max FPS or Balanced turns it off.' 'medium'
    }
    # Fights are where frame rate collapses: builds, edits, explosions and other players all land at once,
    # and that load is on the CPU and on the settings that scale with object count. Creative is empty.
    $perfMode = ($f.FnFeatureLevel -match '^(?i)es31$')
    if ($perfMode -and $f.FnMeshQuality -match '^[1-9]') {
        & $add 'fix' 'Fortnite' 'Mesh quality is High in Performance Mode' 'High meshes draw every build piece, tree and player at full detail. In a build fight that is the setting that grows fastest with what is on screen, so it is a common reason for 200 FPS in Creative turning into 90-120 in a real fight.' 'Video menu: Mesh = Low, or the Max FPS profile in the FORTNITE tab.' 'large in fights'
    }
    if ($f.FnShadows -match '^[1-9]') {
        & $add 'fix' 'Fortnite' 'Shadows are on' 'Every destroyed or placed build changes the shadows, so their cost rises with the fight. Competitive players run them off.' 'Video menu: Shadows = Off, or any FORTNITE tab profile.' 'medium in fights'
    }
    if ($f.FnEffects -match '^[1-9]') {
        & $add 'warn' 'Fortnite' 'Effects quality is above Low' 'Explosions, smoke and build destruction particles are exactly what fills the screen in a fight.' 'Video menu: Effects = Low, or the Max FPS profile.' 'medium in fights'
    }
    if ($f.FnViewDistance -match '^[34]$') {
        & $add 'info' 'Fortnite' 'View distance is Epic or Far' 'More distant players and builds are drawn, which costs CPU in late game. Many players keep it high on purpose to see distant builds: lower it only if late-game drops are your problem.' 'Video menu: View Distance = Medium to test the difference.' 'small to medium'
    }
    # Reflex is NVIDIA-only; the key is written on every PC, so it is only judged where it can be turned on.
    $nvidia = (@($f.Gpus | Where-Object { $_.Name -match 'NVIDIA|GeForce' }).Count -gt 0)
    if ($nvidia -and $f.FnReflex -ne '' -and $f.FnReflex -ne '2') {
        $state = 'off'
        if ($f.FnReflex -eq '1') { $state = 'On, not On + Boost' }
        & $add 'fix' 'Latency' ("NVIDIA Reflex is {0}" -f $state) 'Reflex keeps the render queue empty so the frame you see is the newest one. It is the largest latency reduction a setting can give when the GPU is busy, and On + Boost also stops the GPU clock dropping in light moments.' 'Video menu: NVIDIA Reflex Low Latency = On + Boost, or any FORTNITE tab profile. Needs an NVIDIA GTX 900 or newer.' 'lower input delay'
    } elseif ($nvidia -and $f.FnReflex -eq '2') {
        & $add 'ok' 'Latency' 'NVIDIA Reflex On + Boost' '' '' ''
    }
    if ($f.FnFullscreenMode -eq '2') {
        & $add 'warn' 'Fortnite' 'Fortnite runs in a window' 'Windowed mode is composed by the desktop window manager, which costs frames and latency.' 'Video menu: Window Mode = Fullscreen, or any profile in the FORTNITE tab.' 'small'
    }

    # --- Edits: an edit is confirmed by the server, so how fast it lands and whether it sticks is set by
    # the connection, then by frame time. No PC setting shortens the distance to the server.
    if ($f.IsWiFi) {
        & $add 'fix' 'Edits' 'You are on Wi-Fi' 'Wi-Fi adds jitter and short loss bursts. Edits and builds wait on the server, so they are the first thing to land late, fail or snap back in a fight.' 'Use an Ethernet cable. If that is impossible, 5 GHz close to the router is the next best thing.' 'large for edits'
    }
    if ($null -ne $f.RegionMs) {
        $bad = $false
        if ($f.RegionLossPct -gt 0) {
            $bad = $true
            & $add 'fix' 'Edits' ("{0} percent packet loss to {1}" -f $f.RegionLossPct, $f.Region) 'A lost packet is an edit the server never saw: this is the usual cause of edits that do not go through or reset.' 'NETWORK tab: run the region test again on a cable. If loss stays, it is the router or the provider: restart the router, then call the provider with the traceroute from that tab.' 'large for edits'
        }
        if ($f.RegionJitterMs -gt 5) {
            $bad = $true
            & $add 'warn' 'Edits' ("Jitter {0} ms to {1}" -f $f.RegionJitterMs, $f.Region) 'Jitter makes the edit delay change from one edit to the next, so muscle memory never lines up.' 'Cable instead of Wi-Fi, and nothing downloading or streaming on the same connection while you play.' 'medium for edits'
        }
        if ($f.RegionMs -ge 50) {
            $bad = $true
            & $add 'warn' 'Edits' ("{0} ms to {1}, your closest Fortnite region" -f $f.RegionMs, $f.Region) ("Each edit is confirmed about one round trip later, so roughly {0} ms rides on every edit. That is distance to the datacenter: no tweak and no PC setting lowers it." -f $f.RegionMs) 'Make sure matchmaking uses this region (Settings > Game > Matchmaking Region). A cable and a closer server are the only real fixes.' 'edit delay'
        }
        if (-not $bad) { & $add 'ok' 'Edits' ("{0} ms to {1}, no loss, low jitter" -f $f.RegionMs, $f.Region) '' '' '' }
    } else {
        & $add 'info' 'Edits' 'Region ping not measured yet' 'The edit checks reuse the region test that runs in the background at start-up.' 'Wait for it, or press the region test in the NETWORK tab, then run the doctor again.' ''
    }
    if ($f.FnInstalled) {
        & $add 'info' 'Edits' 'Edit settings to check in game' 'Fortnite keeps these in your Epic account, not on this PC, so they cannot be read or written from here.' 'Settings > Game: Confirm Edit on Release ON (an edit lands the moment you let go of fire, one press less), Turbo Building ON. Put Edit on a key or mouse button you can hit without moving your WASD hand. A mouse at 1000 Hz polling or more.' 'faster edits'
    }

    # --- Memory: the biggest hardware lever in a CPU-bound game, and invisible from inside Windows.
    if ($f.DimmCount -eq 1) {
        $sev = 'fix'; $act = 'Add a second, identical stick so the memory runs dual channel.'
        if ($f.IsLaptop) { $sev = 'warn'; $act = 'If the laptop has a free slot, add an identical stick. Some laptops have one stick soldered and one slot; the manual says which.' }
        & $add $sev 'Memory' 'Memory runs single channel (one stick)' 'With one stick the CPU gets half the memory bandwidth. Fortnite at high frame rates is CPU- and memory-bound, so this is one of the largest losses a PC can have.' $act 'large'
    } elseif ($f.DimmCount -ge 2) {
        $ch = @($f.DimmChannels)
        $named = @($ch | Where-Object { $_ })
        if ($named.Count -eq $ch.Count -and $named.Count -ge 2 -and @($named | Sort-Object -Unique).Count -eq 1) {
            & $add 'fix' 'Memory' ("All {0} sticks are in channel {1}" -f $named.Count, $named[0]) 'The board labels every occupied slot with the same channel, so the memory runs single channel even with two sticks.' 'Move one stick to the other channel. For two sticks the manual almost always says A2 and B2 (second and fourth slot from the CPU).' 'large'
        } else {
            & $add 'ok' 'Memory' ("{0} memory sticks installed" -f $f.DimmCount) '' '' ''
        }
    }
    if ($f.MemoryMTs -gt 0) {
        if ($f.MemoryRatedMTs -gt 0 -and $f.MemoryRatedMTs -gt ($f.MemoryMTs + 100)) {
            & $add 'fix' 'Memory' ("Memory runs at {0} MT/s but the kit is rated {1}" -f $f.MemoryMTs, $f.MemoryRatedMTs) 'The part number says the kit is rated faster than it runs. Without XMP (Intel) or EXPO (AMD) enabled in the BIOS every kit falls back to its slow JEDEC default.' 'BIOS: enable XMP / EXPO / DOCP profile 1, save, reboot. If the PC will not boot afterwards, clearing CMOS puts it back.' 'medium to large'
        } elseif (-not $f.IsLaptop -and (($f.MemoryType -eq 'DDR4' -and $f.MemoryMTs -le 2666) -or ($f.MemoryType -eq 'DDR5' -and $f.MemoryMTs -le 4800))) {
            & $add 'warn' 'Memory' ("{0} runs at {1} MT/s, the JEDEC default" -f $f.MemoryType, $f.MemoryMTs) 'This is the speed every stick falls back to when XMP / EXPO is off. Most gaming kits are rated faster (DDR4 3200-3600, DDR5 6000). The part number did not say what this kit is rated for.' 'Check the rated speed on the stick label or the box. If it is higher, enable XMP / EXPO / DOCP in the BIOS.' 'medium to large'
        } else {
            & $add 'ok' 'Memory' ("{0} at {1} MT/s" -f $f.MemoryType, $f.MemoryMTs).Trim() '' '' ''
        }
    }
    if ($f.RamGB -gt 0 -and $f.RamGB -lt 15) {
        & $add 'warn' 'Memory' ("{0} GB of RAM" -f $f.RamGB) 'Fortnite plus Windows and a browser or Discord can pass 8 GB, and then the game waits on the page file. That shows as stutter and 1% lows more than as average FPS.' 'Close background apps before playing (GAME READY tab). 16 GB in two sticks is the practical minimum today.' 'stutter'
    }

    # --- GPU: which GPU does the work, and whether it gets its full link.
    $gpus = @($f.Gpus)
    if (@($gpus | Where-Object { $_.Kind -eq 'basic' }).Count -gt 0) {
        & $add 'fix' 'GPU' 'A display adapter has no driver' 'Windows lists a Microsoft Basic Display Adapter: a GPU is running without its driver and cannot accelerate the game at all.' 'Install the driver from nvidia.com / amd.com / intel.com (APPS tab has the vendor apps).' 'large'
    }
    $discrete = @($gpus | Where-Object { $_.Kind -eq 'discrete' })
    $integrated = @($gpus | Where-Object { $_.Kind -eq 'integrated' })
    if (-not $f.IsLaptop -and $discrete.Count -gt 0 -and $integrated.Count -gt 0) {
        $dgpuDrives = (@($discrete | Where-Object { $_.DrivesDisplay }).Count -gt 0)
        $igpuDrives = (@($integrated | Where-Object { $_.DrivesDisplay }).Count -gt 0)
        if ($igpuDrives -and -not $dgpuDrives) {
            & $add 'fix' 'GPU' 'The monitor is plugged into the motherboard, not the graphics card' ("The display is driven by {0} while {1} sits idle. Every frame is rendered on the weak GPU, or copied across to it." -f $integrated[0].Name, $discrete[0].Name) 'Move the monitor cable from the motherboard to a port on the graphics card (the lower, horizontal row of ports at the back).' 'large'
        }
    }
    if ($discrete.Count -gt 0 -and $integrated.Count -gt 0 -and $f.FnExe) {
        if ($f.FnGpuPreference -match 'GpuPreference=2') {
            & $add 'ok' 'GPU' 'Fortnite is assigned to the high-performance GPU' '' '' ''
        } else {
            & $add 'warn' 'GPU' 'Fortnite has no GPU assignment on a two-GPU PC' ("This PC has {0} and {1}. With no per-app preference Windows decides, and on some laptops and desktops it picks the integrated GPU." -f $discrete[0].Name, $integrated[0].Name) 'TWEAKS tab: "Fortnite on the high-performance GPU" (optional tier, undoable).' 'large if it was on the iGPU'
        }
    }
    if (-not $f.IsLaptop -and $f.PcieMaxWidth -ge 8 -and $f.PcieWidth -gt 0) {
        if (($f.PcieWidth * 2) -le $f.PcieMaxWidth) {
            & $add 'warn' 'GPU' ("GPU link is x{0} of x{1}" -f $f.PcieWidth, $f.PcieMaxWidth) ("{0} negotiated fewer PCIe lanes than it supports. Usual causes: the card is in the lower (chipset) slot, a riser cable, an M.2 drive sharing the lanes, or dust in the slot." -f $f.PcieGpu) 'Check it under load with GPU-Z (Bus Interface, run the render test). If it stays low, move the card to the top slot closest to the CPU.' 'small to medium'
        } else {
            & $add 'ok' 'GPU' ("GPU link x{0} of x{1}" -f $f.PcieWidth, $f.PcieMaxWidth) '' '' ''
        }
    }

    # --- Display: not an FPS cap, but a reason high FPS does not look like high FPS.
    if ($f.Hz -gt 0 -and $f.MaxHzAtRes -gt ($f.Hz + 1)) {
        & $add 'fix' 'Display' ("The monitor runs at {0} Hz but supports {1} Hz" -f $f.Hz, $f.MaxHzAtRes) ("At {0} Hz you only ever see {0} frames a second, however many the game renders. Windows often leaves new monitors at 60 Hz." -f $f.Hz) ('Settings > System > Display > Advanced display > refresh rate: {0} Hz. Use DisplayPort or the cable that came with the monitor; many HDMI cables cannot carry high refresh rates.' -f $f.MaxHzAtRes) 'what you see'
    } elseif ($f.Hz -gt 0) {
        & $add 'ok' 'Display' ("{0}x{1} at {2} Hz, the panel's maximum at this resolution" -f $f.Width, $f.Height, $f.Hz) '' '' ''
    }

    # --- Power.
    if ($f.OnBattery) {
        & $add 'fix' 'Power' 'The laptop is running on battery' 'On battery a gaming laptop limits the GPU and CPU to a fraction of their power. Frame rates drop by half or more.' 'Plug the charger in, and use the charger that came with the laptop: a USB-C charger often cannot supply full power.' 'large'
    }
    if ($f.PowerSaver) {
        & $add 'fix' 'Power' 'The Power saver plan is active' 'Power saver caps the CPU clock.' 'TWEAKS tab: Ultimate Performance plan, or Balanced in Control Panel > Power Options.' 'large'
    }
    if ($f.VBS) {
        & $add 'info' 'Windows' 'Memory integrity / VBS is running' 'The largest Windows-side FPS item in the catalogue, typically a few percent and more when CPU-bound. It is a security feature, which is why it is in the Risky tier and never recommended automatically.' 'TWEAKS tab, Risky tier: read the cost before you tick it.' 'small to medium'
    }
    if ($f.FnOnHdd) {
        & $add 'warn' 'Storage' 'Fortnite is installed on a hard disk' 'A hard disk cannot stream textures and meshes as fast as the game asks for them while you drop and fly around. That shows as hitching, not as a lower average.' 'Move Fortnite to an SSD: Epic Games Launcher > Library > Fortnite > Manage > Move.' 'stutter'
    }
    if (-not $f.FnInstalled) {
        & $add 'info' 'Fortnite' 'Fortnite was not found' 'The Fortnite checks were skipped. They read the Epic launcher install list and GameUserSettings.ini.' '' ''
    } elseif (-not $f.FnIniExists) {
        & $add 'info' 'Fortnite' 'No Fortnite settings file yet' 'Start Fortnite once and close it, then run the check again to have its settings read.' '' ''
    }

    $rank = @{ fix = 0; warn = 1; info = 2; ok = 3 }
    return @($out.ToArray() | Sort-Object { $rank[$_.Severity] })
}

function Invoke-UTFpsDoctor {
    <#
    .SYNOPSIS
        Collects the facts, ranks the findings and stores both on $sync for the SYSTEM tab. Changes nothing.
    #>
    Write-UTLog 'FPS doctor: reading memory, GPU, display, power and Fortnite settings (read-only)'
    $facts = Get-UTFpsDoctorFacts
    $findings = @(Get-UTFpsDoctorFindings -Facts $facts)
    $sync.fpsDoctorFacts = $facts
    $sync.fpsDoctor = $findings
    $fix = @($findings | Where-Object { $_.Severity -eq 'fix' }).Count
    $warn = @($findings | Where-Object { $_.Severity -eq 'warn' }).Count
    $level = 'Ok'
    if ($fix -gt 0) { $level = 'Warn' }
    Write-UTLog ("FPS doctor: {0} to fix, {1} to check, {2} checks passed" -f $fix, $warn, @($findings | Where-Object { $_.Severity -eq 'ok' }).Count) -Level $level
    foreach ($x in @($findings | Where-Object { $_.Severity -in 'fix', 'warn' })) { Write-UTLog ('  [{0}] {1}: {2}' -f $x.Severity, $x.Area, $x.Title) -Level Warn }
    return $findings
}
