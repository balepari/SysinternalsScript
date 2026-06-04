# ============================================
# SYSINTERNALS PRO DEPLOY SCRIPT
# ============================================
param(
    [switch]$DryRun
)

# -------- CONFIG --------
$BasePath      = "C:\Sysinternals"
$StartMenuRoot = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Sysinternals"
$LogFile       = "$BasePath\install.log"
$SMBPath       = "\\live.sysinternals.com\tools"
$HTTPBase      = "https://live.sysinternals.com/tools"

# -------- LOGGING --------
function Log {
    param($msg)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$time - $msg" | Tee-Object -FilePath $LogFile -Append
}

# -------- PREP --------
New-Item -ItemType Directory -Force -Path $BasePath      | Out-Null
New-Item -ItemType Directory -Force -Path $StartMenuRoot | Out-Null
Log "Avvio installazione Sysinternals PRO$(if ($DryRun) {' [DRY-RUN]'} else {''})"

# -------- SOURCE DETECTION --------
$UseSMB   = $true
$FileList = @()

try {
    Write-Host "Test accesso SMB..."
    $FileList = Get-ChildItem $SMBPath -Filter *.exe -ErrorAction Stop
    Write-Host "Uso SMB"
} catch {
    Write-Host "SMB non disponibile -> uso HTTPS"
    $UseSMB = $false
}

# -------- CACHE INIT --------
$CacheFile = Join-Path $BasePath "cache.json"
if (Test-Path $CacheFile) {
    # -AsHashtable: evita PSCustomObject che non ha .ContainsKey()
    $HashCache = Get-Content $CacheFile | ConvertFrom-Json -AsHashtable
} else {
    $HashCache = @{}
}

# -------- THREAD-SAFE STRUCTURES --------
$Results  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$LogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

# ======================================================
# SMB PATH
# ======================================================
if ($UseSMB) {

    $total = $FileList.Count
    $i     = 0

    foreach ($file in $FileList) {
        $i++
        $pct = [Math]::Min(100, [int]($i / $total * 100))
        Write-Progress -Activity "Sysinternals via SMB" `
            -Status "$($file.Name)  ($i / $total)" -PercentComplete $pct

        $src = $file.FullName
        $dst = Join-Path $BasePath $file.Name

        if (Test-Path $dst) {
            $srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
            if ($srcHash -ne $dstHash) {
                if (-not $DryRun) { Copy-Item $src $dst -Force }
                Log "$(if ($DryRun) {'[DRY-RUN] '})Aggiornato: $($file.Name)"
            }
        } else {
            if (-not $DryRun) { Copy-Item $src $dst }
            Log "$(if ($DryRun) {'[DRY-RUN] '})Scaricato: $($file.Name)"
        }
    }
    Write-Progress -Activity "Sysinternals via SMB" -Completed

# ======================================================
# HTTP PATH
# ======================================================
} else {

    Write-Host "Recupero lista file via HTTP..."
    $html  = Invoke-WebRequest -Uri $HTTPBase
    $links = $html.Links | Where-Object { $_.href -like "*.exe" }
    $total = @($links).Count

    # Contatore condiviso thread-safe per la progress bar
    $progressCounter = [int[]]@(0)

    # Avvio il blocco parallelo in un ThreadJob: il main thread resta libero
    # per fare polling del contatore e aggiornare Write-Progress
    $downloadJob = Start-ThreadJob -ScriptBlock {
        $links_j    = $using:links
        $BasePath_j = $using:BasePath
        $HTTPBase_j = $using:HTTPBase
        $Results_j  = $using:Results
        $LogQueue_j = $using:LogQueue
        $DryRun_j   = $using:DryRun
        $counter_j  = $using:progressCounter

        try {
            $links_j | ForEach-Object -Parallel {
                $BasePath = $using:BasePath_j
                $HTTPBase = $using:HTTPBase_j
                $Results  = $using:Results_j
                $LogQueue = $using:LogQueue_j
                $DryRun   = $using:DryRun_j
                $counter  = $using:counter_j

                function QLog($msg) {
                    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    ($using:LogQueue).Enqueue("$time - $msg")
                }

                $fileName = Split-Path $_.href -Leaf
                $url      = "$HTTPBase/$fileName"
                $dst      = Join-Path $BasePath $fileName
                $tempFile = "$dst.tmp"

                if ($DryRun) {
                    $Results.Add([PSCustomObject]@{
                        FileName = $fileName
                        DestPath = $dst
                        Preview  = $true
                    })
                } else {
                    try {
                        $headers = @{}
                        if (Test-Path $dst) {
                            $lastWrite = (Get-Item $dst).LastWriteTimeUtc
                            $headers["If-Modified-Since"] = $lastWrite.ToString("R")
                        }
                        $response = Invoke-WebRequest `
                            -Uri $url -Headers $headers `
                            -OutFile $tempFile -PassThru -ErrorAction Stop
                        $newHash = (Get-FileHash $tempFile -Algorithm SHA256).Hash
                        $Results.Add([PSCustomObject]@{
                            FileName = $fileName
                            TempPath = $tempFile
                            DestPath = $dst
                            Hash     = $newHash
                            Size     = (Get-Item $tempFile).Length
                            Preview  = $false
                        })
                    } catch {
                        $statusCode = $null
                        try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}
                        if ($statusCode -eq 304) {
                            QLog "Non modificato (304): $fileName"
                        } else {
                            QLog "Errore download ($statusCode): $fileName - $($_.Exception.Message)"
                        }
                    }
                }

                # Incremento atomico: aggiorna il contatore visibile al main thread
                [System.Threading.Interlocked]::Increment([ref]$counter[0]) | Out-Null

            } -ThrottleLimit 8

        } finally {
            # nessuna operazione: il flush del LogQueue avviene nel main thread
        }
    }

    # Main thread: polling del contatore -> aggiornamento progress bar
    while ($downloadJob.State -eq 'Running') {
        $done = $progressCounter[0]
        $pct  = if ($total -gt 0) { [Math]::Min(100, [int]($done / $total * 100)) } else { 0 }
        Write-Progress -Activity "Download Sysinternals (HTTP)" `
            -Status "$done / $total file" -PercentComplete $pct
        Start-Sleep -Milliseconds 300
    }
    Write-Progress -Activity "Download Sysinternals (HTTP)" -Completed
    $downloadJob | Wait-Job | Remove-Job

    # Flush log queue -> file (thread principale, nessuna contesa)
    $msg = $null
    while ($LogQueue.TryDequeue([ref]$msg)) {
        "$msg" | Add-Content -Path $LogFile
    }
}

# ======================================================
# ELABORAZIONE RISULTATI (solo HTTP; SMB scrive direttamente)
# ======================================================
$resultList = [System.Collections.Generic.List[object]]$Results
$totalRes   = $resultList.Count
$iRes       = 0

foreach ($item in $resultList) {
    $iRes++
    $fileName = $item.FileName
    $dst      = if ($item.DestPath) { $item.DestPath } else { Join-Path $BasePath $fileName }
    $pct      = if ($totalRes -gt 0) { [Math]::Min(100, [int]($iRes / $totalRes * 100)) } else { 0 }
    Write-Progress -Activity "Elaborazione risultati" `
        -Status "$fileName  ($iRes / $totalRes)" -PercentComplete $pct

    # DRY-RUN: solo log, nessuna modifica
    if ($item.Preview) {
        if (-not (Test-Path $dst)) {
            Log "[DRY-RUN] Nuovo file: $fileName"
        } else {
            Log "[DRY-RUN] Possibile aggiornamento: $fileName"
        }
        continue
    }

    $tempFile = $item.TempPath
    $newHash  = $item.Hash

    # Cache check
    if ($HashCache.ContainsKey($fileName) -and $HashCache[$fileName] -eq $newHash) {
        Remove-Item $tempFile -Force
        Log "Skip (cache hash): $fileName"
        continue
    }

    # Size check
    if (Test-Path $dst) {
        if ((Get-Item $dst).Length -eq $item.Size) {
            Remove-Item $tempFile -Force
            Log "Skip (stessa dimensione): $fileName"
            continue
        }
    }

    Move-Item $tempFile $dst -Force
    $HashCache[$fileName] = $newHash
    Log "Aggiornato (HTTP): $fileName"
}
if ($totalRes -gt 0) {
    Write-Progress -Activity "Elaborazione risultati" -Completed
}

# ======================================================
# POST-PROCESSING (solo se non DryRun)
# ======================================================
if (-not $DryRun) {

    $HashCache | ConvertTo-Json | Set-Content $CacheFile

    # -------- CATEGORIE PROFESSIONALI --------
    $Categories = @{
        "01 - Process Analysis"   = @("procexp.exe","procmon.exe","pslist.exe","pskill.exe","handle.exe")
        "02 - Startup & Autoruns" = @("autoruns.exe","autorunsc.exe")
        "03 - Disk & File System" = @("du.exe","streams.exe","diskmon.exe")
        "04 - Networking"         = @("tcpview.exe","psping.exe")
        "05 - Security & Signing" = @("sigcheck.exe")
        "99 - All Tools"          = (Get-ChildItem $BasePath -Filter *.exe).Name
    }

    # -------- SHORTCUT CREATION (smart: ricrea solo se mancante o target cambiato) --------
    $WshShell = New-Object -ComObject WScript.Shell

    # Pre-calcolo lista flat per conteggio progress bar
    $allShortcuts = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($category in $Categories.Keys) {
        foreach ($exe in $Categories[$category]) {
            if (-not ($exe -and $exe.ToLower().EndsWith(".exe"))) { continue }
            $exePath = Join-Path $BasePath $exe
            if (-not (Test-Path $exePath)) { continue }
            $allShortcuts.Add([PSCustomObject]@{
                Category = $category
                Exe      = $exe
                ExePath  = $exePath
            })
        }
    }

    $totalLnk = $allShortcuts.Count
    $iLnk     = 0

    foreach ($entry in $allShortcuts) {
        $iLnk++
        $pct     = [Math]::Min(100, [int]($iLnk / $totalLnk * 100))
        $catPath = Join-Path $StartMenuRoot $entry.Category
        New-Item -ItemType Directory -Force -Path $catPath | Out-Null
        $lnk     = Join-Path $catPath ([System.IO.Path]::GetFileNameWithoutExtension($entry.Exe) + ".lnk")

        Write-Progress -Activity "Shortcut Start Menu" `
            -Status "$($entry.Exe)  ($iLnk / $totalLnk)" -PercentComplete $pct

        # Smart check: salta se il link esiste e punta gia' al file corretto
        if (Test-Path $lnk) {
            try {
                $existing = $WshShell.CreateShortcut($lnk)
                if ($existing.TargetPath -ieq $entry.ExePath) {
                    # link gia' aggiornato: nessuna azione
                    continue
                }
            } catch {
                # .lnk corrotto o illeggibile -> ricreazione forzata
            }
        }

        try {
            $sc                  = $WshShell.CreateShortcut($lnk)
            $sc.TargetPath       = $entry.ExePath
            $sc.WorkingDirectory = $BasePath
            $sc.IconLocation     = "$($entry.ExePath),0"
            $sc.Save()
            Log "Shortcut creato/aggiornato: $($entry.Exe)"
        } catch {
            Log "Errore shortcut: $lnk - $_"
            continue
        }

        # Bit "Esegui come amministratore" per tool che lo richiedono
        if ($entry.Exe -match "proc|autoruns|tcpview") {
            $bytes      = [System.IO.File]::ReadAllBytes($lnk)
            $bytes[21]  = $bytes[21] -bor 0x20
            [System.IO.File]::WriteAllBytes($lnk, $bytes)
        }
    }
    Write-Progress -Activity "Shortcut Start Menu" -Completed

    # -------- PATH INTEGRATION --------
    Log "Configurazione PATH..."
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($currentPath -notlike "*$BasePath*") {
        [Environment]::SetEnvironmentVariable("Path", "$currentPath;$BasePath", "Machine")
        Log "Aggiunto a PATH"
    } else {
        Log "PATH gia' configurato"
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine")

} else {
    Log "[DRY-RUN] Shortcut e PATH non modificati"
}

# -------- FINAL STEPS --------
Log "Installazione completata!"
Write-Host ""
if ($DryRun) {
    Write-Host "Dry-Run completato - nessuna modifica effettuata"
} else {
    Write-Host "Sysinternals PRO pronto!"
    Write-Host "Cartella: $BasePath"
    Write-Host "Start > Sysinternals"
    Write-Host "Puoi ora lanciare tool da qualsiasi terminale (PATH attivo)"
}
