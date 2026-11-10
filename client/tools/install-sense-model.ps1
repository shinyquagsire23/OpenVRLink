# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Makes the PlayStation VR2 Sense controller model usable by an OpenVRLink
# client, on a Windows PC running SteamVR. Run it once on that PC (again after
# a SteamVR update that changes the model):
#
#   powershell -ExecutionPolicy Bypass -File install-sense-model.ps1
#
# Why: the VR Link driver only accepts controllers of types it knows, so the
# client's controllers are of the Touch type, with Touch input names
# (/input/trigger, /input/a, ...). SteamVR's PS VR2 model ties its moving
# parts to PS VR2 input names (/input/r2, /input/cross, ...), so on a Touch
# controller its trigger, buttons and stick never move.
#
# This copies the two Sense models out of SteamVR's own playstation_vr2 driver
# folder into a new resource-only folder beside it, "openvrlink_sense", and
# rewrites the input names in the copies to the Touch ones. Nothing in
# SteamVR's own folders is changed. To undo it, delete drivers\openvrlink_sense.

$ErrorActionPreference = 'Stop'
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
$drivers = Join-Path $steam 'steamapps/common/SteamVR/drivers'
$source = Join-Path $drivers 'playstation_vr2/resources/rendermodels'
$target = Join-Path $drivers 'openvrlink_sense'
if (-not (Test-Path $source)) { throw "SteamVR's playstation_vr2 driver folder was not found at $source" }

# PS VR2 input name -> the Touch input in the same place on the controller.
# The two finger-proximity sensors and the right-hand Options button have no
# Touch counterpart and are left as they are (those parts will not move).
# Nor is the PS button renamed: on visionOS an app never sees it pressed, and
# tied to the same input as Create it would move whenever Create does.
$names = [ordered]@{
    '/input/r2_sensor' = '/input/r2_sensor';  '/input/l2_sensor' = '/input/l2_sensor'
    '/input/r1_sensor' = '/input/r1_sensor';  '/input/l1_sensor' = '/input/l1_sensor'
    '/input/r2' = '/input/trigger';           '/input/l2' = '/input/trigger'
    '/input/r1' = '/input/grip';              '/input/l1' = '/input/grip'
    '/input/right_stick' = '/input/joystick'; '/input/left_stick' = '/input/joystick'
    '/input/cross/click' = '/input/a/click';  '/input/circle/click' = '/input/b/click'
    '/input/square/click' = '/input/x/click'; '/input/triangle/click' = '/input/y/click'
    '/input/create/click' = '/input/system/click'
}

if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory (Join-Path $target 'resources/rendermodels') | Out-Null
Set-Content (Join-Path $target 'driver.vrdrivermanifest') @'
{
	"alwaysActivate": false,
	"name" : "openvrlink_sense",
	"directory" : "",
	"resourceOnly" : true,
	"hmd_presence" : []
}
'@

foreach ($model in 'playstation_vr2_sense_left', 'playstation_vr2_sense_right') {
    $to = Join-Path $target "resources/rendermodels/$model"
    Copy-Item (Join-Path $source $model) $to -Recurse
    $file = Join-Path $to "$model.json"
    $text = Get-Content $file -Raw
    $changed = 0
    # Quoted, so that "/input/r2" does not also match inside "/input/r2_sensor".
    foreach ($name in $names.Keys) {
        $before = $text
        $text = $text.Replace('"' + $name + '"', '"' + $names[$name] + '"')
        if ($text -ne $before -and $name -ne $names[$name]) { $changed++ }
    }
    Set-Content $file $text -NoNewline
    "${model}: $changed kinds of input renamed"
}
"Installed to $target. Restart SteamVR."
