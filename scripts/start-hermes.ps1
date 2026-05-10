param(
    [switch]$AutoInstall,
    [string]$HermesHome = "$env:USERPROFILE\.hermes",
    [string]$WorkingDir = "D:\",
    [string]$GitBashPath = "D:\Programs\Git\bin\bash.exe",
    # Local SearXNG + Firecrawl stacks (Hermes web.backend: firecrawl)
    [string]$LocalToolsRoot = "D:\cursorWorkSpace\agent_local_tool",
    [switch]$SkipLocalWebStacks,
    # Max seconds to wait for Docker engine after launching Docker Desktop
    [int]$DockerReadyTimeoutSec = 120,
    # After docker compose, wait up to this many seconds for Firecrawl HTTP to respond
    [int]$FirecrawlReadyTimeoutSec = 120,
    # When FIRECRAWL_API_URL is unset but we start the local Firecrawl compose, probe this URL (see your compose port)
    [string]$FirecrawlDefaultLocalUrl = "http://127.0.0.1:3002",
    # 即使配置了自托管探测 URL，也不阻塞等待（仅启动 docker 栈）
    [switch]$SkipFirecrawlWait
)

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERR]  $Message" -ForegroundColor Red
}

# 读取 ~/.hermes/.env 中单行 KEY=value（不含引号包裹值中的 = 的完整解析）
function Get-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith("#")) {
            continue
        }
        if ($t -match "^\s*$([Regex]::Escape($Key))\s*=\s*(.*)\s*$") {
            $val = $Matches[1].Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            return $val
        }
    }
    return ""
}

# 读取 config.yaml 的 web.backend（空字符串表示未配置）
function Get-HermesWebBackend {
    param(
        [string]$HermesHome,
        [string]$PythonExe
    )
    $cfg = Join-Path $HermesHome "config.yaml"
    if (-not (Test-Path -LiteralPath $cfg)) {
        return ""
    }
    # 多行脚本用数组拼接，避免 here-string 在部分 PS 5.1 环境下的解析问题
    $pyLines = @(
        'import sys',
        'try:',
        '    import yaml',
        'except ImportError:',
        '    print('''')',
        '    sys.exit(0)',
        'path = sys.argv[1]',
        'with open(path, encoding=''utf-8'') as f:',
        '    d = yaml.safe_load(f) or {}',
        'print((d.get(''web'') or {}).get(''backend'') or '''')'
    )
    $py = $pyLines -join [Environment]::NewLine
    $out = & $PythonExe -c $py $cfg 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }
    return ([string]$out).Trim()
}

# 探测自托管 Firecrawl HTTP 是否已监听（多种常见路径，避免版本差异）
function Test-FirecrawlHttpReady {
    param(
        [string]$BaseUrl,
        [int]$TimeoutSec = 3
    )
    $u = $BaseUrl.Trim().TrimEnd("/")
    if ($u.Length -eq 0) {
        return $false
    }
    foreach ($path in @("/health", "/v1/health", "/v0/health", "/")) {
        $uri = $u + $path
        try {
            $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 2 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                return $true
            }
        }
        catch {
            $code = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $code = [int]$_.Exception.Response.StatusCode
            }
            # 401/403 通常表示服务已起来但需要鉴权
            if ($code -eq 401 -or $code -eq 403) {
                return $true
            }
        }
    }
    return $false
}

function Wait-FirecrawlReady {
    param(
        [string]$BaseUrl,
        [int]$MaxWaitSec = 120
    )
    if (($BaseUrl -as [string]).Trim().Length -eq 0) {
        return $false
    }
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $elapsed = 0
    Write-Info ("Waiting for Firecrawl API at {0} (max {1}s)..." -f $BaseUrl.Trim(), $MaxWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-FirecrawlHttpReady -BaseUrl $BaseUrl) {
            Write-Ok ("Firecrawl API is reachable (after ~{0}s)." -f $elapsed)
            return $true
        }
        Start-Sleep -Seconds 3
        $elapsed += 3
        if (($elapsed % 15) -eq 0) {
            Write-Info ("Still waiting for Firecrawl... {0} / {1}s" -f $elapsed, $MaxWaitSec)
        }
    }
    Write-Warn ("Firecrawl not ready after {0}s. Hermes may return empty web_search until the stack is healthy." -f $MaxWaitSec)
    return $false
}

function Test-DockerDaemonReady {
    try {
        & docker info 1>$null 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

# Resolve Docker Desktop.exe (some installs use Docker\Docker\resources\)
function Get-DockerDesktopExePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Docker\Docker\resources\Docker Desktop.exe"),
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
    )
    $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($pf86) {
        $candidates += @(
            (Join-Path $pf86 "Docker\Docker\resources\Docker Desktop.exe"),
            (Join-Path $pf86 "Docker\Docker\Docker Desktop.exe")
        )
    }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            return $p
        }
    }
    return $null
}

# Start Docker Desktop if needed; poll until engine is up or timeout
function Ensure-DockerDesktop {
    param(
        [int]$MaxWaitSec = 120
    )
    if (Test-DockerDaemonReady) {
        return $true
    }

    $exe = Get-DockerDesktopExePath
    if (-not $exe) {
        Write-Warn "Docker Desktop.exe not found. Install Docker Desktop or start the engine manually."
        return $false
    }

    Write-Info "Docker engine not ready; starting Docker Desktop..."
    try {
        Start-Process -FilePath $exe -WindowStyle Minimized
    }
    catch {
        Write-Warn ("Could not start Docker Desktop: {0}" -f $_.Exception.Message)
        return $false
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $elapsed = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $elapsed += 2
        if (Test-DockerDaemonReady) {
            Write-Ok ("Docker engine ready (waited ~{0}s)." -f $elapsed)
            return $true
        }
        if (($elapsed % 10) -eq 0) {
            Write-Info ("Still waiting for Docker engine... {0} / {1}s" -f $elapsed, $MaxWaitSec)
        }
    }

    Write-Warn ("Docker engine wait timed out ({0}s). Skipping SearXNG / Firecrawl stacks." -f $MaxWaitSec)
    return $false
}

# docker compose up -d for each stack; failures are warnings only
function Start-LocalWebStacks {
    param(
        [string]$ProjectRoot,
        [string]$Root,
        [int]$DockerWaitSec = 120
    )
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Warn "docker CLI not found; skipping SearXNG / Firecrawl."
        return
    }
    if (Test-DockerDaemonReady) {
        Write-Ok "Docker engine already running."
    }
    else {
        if (-not (Ensure-DockerDesktop -MaxWaitSec $DockerWaitSec)) {
            return
        }
    }

    $stacks = @(
        @{ Name = "SearXNG"; Subdir = "searxng" },
        @{ Name = "Firecrawl"; Subdir = "firecrawl" }
    )

    foreach ($s in $stacks) {
        $dir = Join-Path $Root $s.Subdir
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Warn ("{0}: directory missing, skip: {1}" -f $s.Name, $dir)
            continue
        }
        $composeFile = $null
        foreach ($name in @("docker-compose.yml", "docker-compose.yaml")) {
            $cand = Join-Path $dir $name
            if (Test-Path -LiteralPath $cand) {
                $composeFile = $cand
                break
            }
        }
        if (-not $composeFile) {
            Write-Warn ("{0}: no compose file, skip: {1}" -f $s.Name, $dir)
            continue
        }

        Write-Info ("Starting {0} (docker compose up -d): {1}" -f $s.Name, $dir)
        Push-Location $dir
        try {
            & docker compose up -d
            $composeExit = $LASTEXITCODE
            if ($composeExit -ne 0) {
                Write-Warn ("{0}: docker compose failed (exit {1}); continuing to Hermes." -f $s.Name, $composeExit)
            }
            if ($composeExit -eq 0) {
                Write-Ok ("{0}: stack is up." -f $s.Name)
            }
        }
        catch {
            Write-Warn ("{0}: error: {1}" -f $s.Name, $_.Exception.Message)
        }
        finally {
            Pop-Location
            Set-Location $ProjectRoot
        }
    }
}

function Test-OllamaReady {
    param(
        [string]$BaseUrl = "http://127.0.0.1:11434/v1/models",
        [int]$TimeoutSec = 2
    )
    try {
        $null = Invoke-RestMethod -Uri $BaseUrl -TimeoutSec $TimeoutSec
        return $true
    }
    catch {
        return $false
    }
}

try {
    $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    Set-Location $ProjectRoot

    Write-Info "ProjectRoot = $ProjectRoot"
    Write-Info "WorkingDir  = $WorkingDir"

    $venvCandidates = @(
        (Join-Path $ProjectRoot ".venv\Scripts\python.exe"),
        (Join-Path $ProjectRoot "venv\Scripts\python.exe")
    )
    $pythonExe = $null
    foreach ($candidate in $venvCandidates) {
        if (Test-Path $candidate) {
            $pythonExe = $candidate
            break
        }
    }

    if (-not $pythonExe) {
        Write-Err "No venv python found (.venv or venv)."
        Write-Info "Create one with: python -m venv .venv"
        exit 1
    }

    Write-Ok "Python = $pythonExe"

    & $pythonExe -c "import yaml,fire,openai; print('ok')" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if ($AutoInstall) {
            Write-Warn "Dependencies missing. Installing editable package..."
            & $pythonExe -m pip install -e ".[pty]"
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Dependency install failed."
                exit 1
            }
            Write-Ok "Dependencies installed."
        }
        else {
            Write-Err "Dependencies missing in this venv."
            Write-Info "Run: $pythonExe -m pip install -e `".[pty]`""
            Write-Info "Or use: .\scripts\start-hermes.ps1 -AutoInstall"
            exit 1
        }
    }
    else {
        Write-Ok "Dependency check passed."
    }

    $env:HERMES_HOME = $HermesHome
    $env:TERMINAL_CWD = $WorkingDir
    if (Test-Path $GitBashPath) {
        $env:HERMES_GIT_BASH_PATH = $GitBashPath
        Write-Ok "Using Git Bash: $env:HERMES_GIT_BASH_PATH"
    }
    else {
        Write-Warn "Git Bash not found at: $GitBashPath"
        Write-Warn "Hermes may fall back to another bash implementation."
    }

    Write-Info "HERMES_HOME  = $env:HERMES_HOME"
    Write-Info "TERMINAL_CWD = $env:TERMINAL_CWD"

    if (-not $SkipLocalWebStacks) {
        Start-LocalWebStacks -ProjectRoot $ProjectRoot -Root $LocalToolsRoot -DockerWaitSec $DockerReadyTimeoutSec
    }
    else {
        Write-Info "Skipping local SearXNG / Firecrawl (-SkipLocalWebStacks)."
    }

    # Firecrawl: probe FIRECRAWL_API_URL from .env, or default local URL when web.backend=firecrawl and no cloud key (self-hosted)
    if (-not $SkipFirecrawlWait) {
        $dotenvPath = Join-Path $HermesHome ".env"
        $fcApiUrl = (Get-DotEnvValue -Path $dotenvPath -Key "FIRECRAWL_API_URL").Trim()
        $fcApiKey = (Get-DotEnvValue -Path $dotenvPath -Key "FIRECRAWL_API_KEY").Trim()
        $webBackendRaw = Get-HermesWebBackend -HermesHome $HermesHome -PythonExe $pythonExe
        $webBackend = ([string]$webBackendRaw).Trim().ToLowerInvariant()

        $firecrawlProbeUrl = ""
        if ($fcApiUrl.Length -gt 0) {
            $firecrawlProbeUrl = $fcApiUrl
            Write-Info ('Firecrawl probe URL (from FIRECRAWL_API_URL): {0}' -f $firecrawlProbeUrl)
        }
        elseif ($webBackend -eq "firecrawl" -and $fcApiKey.Length -eq 0 -and -not $SkipLocalWebStacks) {
            $firecrawlProbeUrl = $FirecrawlDefaultLocalUrl.Trim()
            Write-Info ('web.backend is firecrawl and FIRECRAWL_API_KEY is unset; using default self-hosted URL: {0} (set FIRECRAWL_API_URL in .env if port differs)' -f $firecrawlProbeUrl)
        }

        if ($firecrawlProbeUrl.Length -gt 0) {
            Wait-FirecrawlReady -BaseUrl $firecrawlProbeUrl -MaxWaitSec $FirecrawlReadyTimeoutSec | Out-Null
        }
        elseif ($webBackend -eq "firecrawl" -and $fcApiKey.Length -eq 0 -and $fcApiUrl.Length -eq 0 -and $SkipLocalWebStacks) {
            Write-Warn 'Skipped local Docker stacks and FIRECRAWL_API_URL is unset; ensure self-hosted Firecrawl is running or web_search may be empty.'
        }
    }
    else {
        Write-Info 'Skipping Firecrawl HTTP readiness wait (-SkipFirecrawlWait).'
    }

    if (-not (Test-OllamaReady)) {
        Write-Warn "Ollama is not ready. Trying to start 'ollama serve'..."
        $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $ollamaCmd) {
            Write-Err "Cannot find 'ollama' in PATH."
            exit 1
        }

        try {
            Start-Process -FilePath $ollamaCmd.Source -ArgumentList "serve" -WindowStyle Hidden | Out-Null
        }
        catch {
            Write-Err "Failed to start ollama serve: $($_.Exception.Message)"
            exit 1
        }

        $maxWait = 30
        $ready = $false
        for ($i = 1; $i -le $maxWait; $i++) {
            Start-Sleep -Seconds 1
            if (Test-OllamaReady) {
                $ready = $true
                break
            }
        }

        if (-not $ready) {
            Write-Err "Ollama not ready after $maxWait seconds."
            Write-Info "Try running manually: ollama serve"
            exit 1
        }
        Write-Ok "Ollama is ready."
    }
    else {
        Write-Ok "Ollama is already running."
    }

    Write-Info "Starting Hermes..."

    $hermesExe = Join-Path (Split-Path $pythonExe -Parent) "hermes.exe"
    if (Test-Path $hermesExe) {
        & $hermesExe
    }
    else {
        & $pythonExe -m hermes_cli.main
    }

    exit $LASTEXITCODE
}
catch {
    Write-Err "Start failed: $($_.Exception.Message)"
    exit 1
}
