@echo off
REM synth_fpu.bat [top [period [impl]]]
REM   an FPU alone in Vivado, out of context (see synth_fpu.tcl).
REM   synth_fpu.bat                 FPU_PIPE (the pipelined unit), 50 MHz
REM   synth_fpu.bat CORE_FPU        the unit the core has now, to compare
if not exist output mkdir output
vivado -mode batch -source synth_fpu.tcl -log output\vivado.log -journal output\vivado.jou -tclargs %*
if errorlevel 1 (
    echo Vivado run failed, see output\vivado.log
    exit /b 1
)
echo Done. The numbers are in output\*\summary.txt
