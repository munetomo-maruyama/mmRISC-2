@echo off
REM synth_l2.bat [size [ways [random [period [impl]]]]]
REM   CPU_L2 alone in Vivado, out of context (see synth_l2.tcl).
REM   synth_l2.bat                   256 KB, 4 ways, pseudo LRU, 50 MHz, place and route
REM   synth_l2.bat 131072            128 KB
REM   synth_l2.bat 262144 4 0 12.5   the same at 80 MHz, to see the margin
if not exist output mkdir output
vivado -mode batch -source synth_l2.tcl -log output\vivado.log -journal output\vivado.jou -tclargs %*
if errorlevel 1 (
    echo Vivado run failed, see output\vivado.log
    exit /b 1
)
echo Done. The numbers are in output\L2_*\summary.txt
