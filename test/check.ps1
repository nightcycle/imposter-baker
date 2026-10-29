$ErrorActionPreference = 'Stop'
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
Invoke-Checked cargo @('fmt', '--check')
Invoke-Checked cargo @('test', '--locked', '--all-targets')
Invoke-Checked cargo @('clippy', '--locked', '--all-targets', '--', '-D', 'warnings')
New-Item -ItemType Directory -Path test/tooling -Force | Out-Null
if (-not (Test-Path -LiteralPath test/tooling/roblox.d.luau)) {
    Invoke-WebRequest -Uri 'https://luau-lsp.pages.dev/type-definitions/globalTypes.None.d.luau' -OutFile test/tooling/roblox.d.luau
}
Invoke-Checked rojo @('sourcemap', 'default.project.json', '--output', 'test/tooling/sourcemap.json')
Invoke-Checked luau-lsp @('analyze', '--definitions=@roblox=test/tooling/roblox.d.luau', '--sourcemap=test/tooling/sourcemap.json', '--platform=roblox', 'imposter-render/src', 'test/luau')
Invoke-Checked stylua @('--check', 'imposter-render/src', 'test/luau', 'test/run.luau')
Invoke-Checked lune @('run', 'test/run.luau')
Invoke-Checked wally @('package', '--project-path', 'imposter-render', '--output', 'test/tooling/imposter-render.zip')
Invoke-Checked rojo @('build', 'imposter-render/default.project.json', '--output', 'test/tooling/imposter-render.rbxm')
