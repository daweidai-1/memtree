@echo off
rem memtree 入口（Windows）。解释器优先级：%MEMTREE_PY% -> py -3 -> python。
setlocal
set "MAIN=%~dp0..\scripts\memtree.py"
if not exist "%MAIN%" ( echo [memtree] missing %MAIN% 1>&2 & exit /b 127 )
if defined MEMTREE_PY ( "%MEMTREE_PY%" "%MAIN%" %* & exit /b %ERRORLEVEL% )
where py >nul 2>nul && ( py -3 "%MAIN%" %* & exit /b %ERRORLEVEL% )
where python >nul 2>nul && ( python "%MAIN%" %* & exit /b %ERRORLEVEL% )
echo [memtree] no python found: set MEMTREE_PY 1>&2
exit /b 127
