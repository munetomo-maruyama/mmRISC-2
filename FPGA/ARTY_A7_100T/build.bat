@echo off
REM Windows-side Vivado batch build (run in FPGA\ARTY_A7_100T)
REM Requires Vivado on PATH (Vivado 2025.1 confirmed for LitexRocket).
vivado -mode batch -source build.tcl -log output\vivado.log -journal output\vivado.jou
if errorlevel 1 (
    echo Vivado build failed.
    exit /b 1
)
echo Vivado build finished. Bitstream: output\TOP.bit  Flash image: output\TOP.bin
