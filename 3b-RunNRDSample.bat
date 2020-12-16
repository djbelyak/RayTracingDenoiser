@echo off

set TARGET_VS=vs2017
if exist "_Compiler\vs2019" set TARGET_VS=vs2019

set DIR=_Build\%TARGET_VS%\Bin\Release\

if not exist %DIR% (
    set DIR=_Build\%TARGET_VS%\Bin\Debug\
)

if not exist %DIR% (
    echo The project is not compiled!
    pause
    exit /b
)

set API=D3D12
echo 1 - D3D12
echo 2 - VULKAN
:CHOOSE_API
set /P M=Choose API [1-2]:
if %M%==1 goto D3D12
if %M%==2 goto VULKAN
goto CHOOSE_API
:D3D12
set API=D3D12
goto RESOLUTION
:VULKAN
set API=VULKAN
goto RESOLUTION

:RESOLUTION
set WIDTH=1920
set HEIGHT=1080
echo.
echo 1 - 1080p
echo 2 - 1440p
echo 3 - 2160p
echo 4 - 1080p (ultra wide)
echo 5 - 1440p (ultra wide)
:CHOOSE_RESOLUTION
set /P M=Choose resolution [1-5]:
if %M%==1 goto 1080P
if %M%==2 goto 1440P
if %M%==3 goto 2160P
if %M%==4 goto 1080p_WIDE
if %M%==5 goto 1440P_WIDE
goto CHOOSE_RESOLUTION
:1080P
set WIDTH=1920
set HEIGHT=1080
goto RUN
:1440P
set WIDTH=2560
set HEIGHT=1440
goto RUN
:2160P
set WIDTH=3840
set HEIGHT=2160
goto RUN
:1080P_WIDE
set WIDTH=2560
set HEIGHT=1080
goto RUN
:1440P_WIDE
set WIDTH=3440
set HEIGHT=1440
goto RUN

:RUN
pushd %DIR%

start 09_RayTracing_NRD.exe --width=%WIDTH% --height=%HEIGHT% --api=%API%% --testMode --scene=Bistro/BistroInterior.fbx

popd

exit /b