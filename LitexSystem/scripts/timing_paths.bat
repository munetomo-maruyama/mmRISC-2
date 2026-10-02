@echo off
REM List the 300 worst paths of the CPU clock of the last build
REM (timing_paths.tcl). Run in build\gateware after build_digilent_arty.bat;
REM build_soc.sh copies both files there.
vivado -mode batch -source timing_paths.tcl
if errorlevel 1 (
    echo Vivado failed.
    exit /b 1
)
echo Written: digilent_arty_paths.rpt
