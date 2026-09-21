@echo off
REM Vivado build of the mmRISC-2 SoC, run on the Windows VM.
REM
REM Copy this file next to digilent_arty.tcl in build\gateware\ (build_soc.sh
REM does that for you) and run it from there. The tcl reads the RTL through
REM paths relative to this directory, so the drive letter of the share does
REM not matter.
REM
REM Vivado 2025.1 confirmed working.
vivado -mode batch -source digilent_arty.tcl
if errorlevel 1 (
    echo Vivado build failed.
    exit /b 1
)
echo Vivado build finished. Bitstream: digilent_arty.bit
