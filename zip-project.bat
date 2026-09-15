@echo off
setlocal

REM Create a source archive without VCS metadata, dependencies, or build output.
REM The archive is deliberately extension-filtered so local binaries and large
REM generated trees do not get copied accidentally.
set "ROOT=%~dp0"
pushd "%ROOT%" >nul

set "ZIP=project.zip"
set "SEVENZIP="

if exist "%ProgramFiles%\7-Zip\7z.exe" set "SEVENZIP=%ProgramFiles%\7-Zip\7z.exe"
if not defined SEVENZIP if exist "%ProgramFiles(x86)%\7-Zip\7z.exe" set "SEVENZIP=%ProgramFiles(x86)%\7-Zip\7z.exe"
if not defined SEVENZIP for /f "delims=" %%I in ('where 7z.exe 2^>nul') do if not defined SEVENZIP set "SEVENZIP=%%I"

if not defined SEVENZIP (
  echo 7-Zip was not found. Install it or add 7z.exe to PATH.
  popd
  exit /b 1
)

if exist "%ZIP%" (
  del /f /q "%ZIP%" >nul 2>&1
  if exist "%ZIP%" (
    echo Could not remove the existing "%ZIP%".
    popd
    exit /b 1
  )
)

REM Include Delphi, Rust, Go, Node.js, TypeScript, React, common source,
REM documentation, data, scripts, and deployment configuration files.
REM Exclude VCS metadata, local agent links, dependencies, build output,
REM generated binaries, caches, temporary files, the archive itself, and this script.
"%SEVENZIP%" a -tzip "%ZIP%" -r ^
  -i!*.pas -i!*.dpr -i!*.dpk -i!*.dproj -i!*.groupproj -i!*.dfm -i!*.fmx ^
  -i!*.res -i!*.rc -i!*.inc -i!*.asm -i!*.h -i!*.hpp -i!*.c -i!*.cc -i!*.cpp ^
  -i!*.cs -i!*.java -i!*.kt -i!*.swift -i!*.sql -i!*.proto ^
  -i!*.rs -i!*.toml -i!*.lock -i!*.go -i!*.mod -i!*.sum -i!*.work ^
  -i!*.js -i!*.jsx -i!*.ts -i!*.tsx -i!*.mjs -i!*.cjs -i!*.mts -i!*.cts ^
  -i!*.json -i!*.jsonc -i!*.css -i!*.scss -i!*.sass -i!*.less ^
  -i!*.html -i!*.htm -i!*.svg -i!*.vue -i!*.svelte ^
  -i!*.py -i!*.xml -i!*.csv -i!*.yaml -i!*.yml -i!*.ini -i!*.env.example ^
  -i!*.bat -i!*.cmd -i!*.sh -i!*.bash -i!*.zsh -i!*.fish ^
  -i!*.ps1 -i!*.psd1 -i!*.psm1 -i!*.dockerfile -i!*.tf -i!*.tfvars ^
  -i!*.md -i!TASKS.md -i!TASKS.ARCHIVE.md -i!*.txt -i!*.pdf -i!*.png -i!*.jpg -i!*.jpeg -i!*.gif -i!*.webp -i!*.ico ^
  -i!README -i!LICENSE -i!COPYING -i!NOTICE -i!CHANGELOG ^
  -i!Makefile -i!Dockerfile -i!Jenkinsfile -i!Procfile -i!Vagrantfile ^
  -i!.editorconfig -i!.gitignore -i!.gitattributes -i!.dockerignore ^
  -x!.git\* -x!.svn\* -x!.hg\* -x!.dak\* ^
  -x!.agents\skills\* -x!.claude\skills\* ^
  -x!target\* -x!node_modules\* -x!bower_components\* ^
  -x!*\.git\* -x!*\.svn\* -x!*\.hg\* -x!*\.dak\* ^
  -x!*.agents\skills\* -x!*.claude\skills\* ^
  -x!*\target\* -x!*\node_modules\* -x!*\bower_components\* ^
  -x!bin\* -x!obj\* -x!build\* -x!dist\* -x!out\* -x!coverage\* ^
  -x!*\bin\* -x!*\obj\* -x!*\build\* -x!*\dist\* -x!*\out\* -x!*\coverage\* ^
  -x!.next\* -x!.nuxt\* -x!.vite\* -x!.parcel-cache\* -x!.turbo\* ^
  -x!*\.next\* -x!*\.nuxt\* -x!*\.vite\* -x!*\.parcel-cache\* -x!*\.turbo\* ^
  -x!.cache\* -x!.pytest_cache\* -x!__pycache__\* -x!.mypy_cache\* ^
  -x!*\.cache\* -x!*\.pytest_cache\* -x!*\__pycache__\* -x!*\.mypy_cache\* ^
  -x!.ruff_cache\* -x!.tox\* -x!.nox\* -x!.venv\* -x!venv\* -x!env\* ^
  -x!*\.ruff_cache\* -x!*\.tox\* -x!*\.nox\* -x!*\.venv\* -x!*\venv\* -x!*\env\* ^
  -x!__history\* -x!__recovery\* -x!temp\* -x!tmp\* ^
  -x!*\__history\* -x!*\__recovery\* -x!*\temp\* -x!*\tmp\* ^
  -x!project.zip -x!zip-project.bat -x!*.dcu -x!*.identcache -x!*.local -x!*.dsk ^
  -x!*.exe -x!*.dll -x!*.so -x!*.dylib -x!*.a -x!*.lib -x!*.o -x!*.obj ^
  -x!*.pdb -x!*.ilk -x!*.class -x!*.jar -x!*.test -x!*.prof -x!*.out ^
  -x!*.log -x!*.tmp -x!*.temp -x!*.cache -x!*.map -x!*.tsbuildinfo ^
  -x!*.bak -x!*.old -x!*.orig -x!*.rej -x!*.swp -x!*.swo -x!*~ ^
  -x!npm-debug.log* -x!yarn-debug.log* -x!yarn-error.log* -x!pnpm-debug.log* ^
  -x!.DS_Store -x!Thumbs.db -x!desktop.ini

set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo 7-Zip failed with exit code %RESULT%.
  popd
  exit /b %RESULT%
)

echo Created "%ROOT%%ZIP%".
popd
exit /b 0
