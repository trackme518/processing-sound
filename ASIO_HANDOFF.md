# AI Agent Handoff — Fix JAsioHost ASIO driver enumeration (Windows)

Status: **ready to implement on a Windows machine**
Created: 2026-10-25
Working repo: `/Users/vojo/Documents/GitHub/processing-sound` (branch `jasio-support`)
This file is intentionally **not committed**. Delete it before opening the upstream PR.

---

## 1. Objective

The Processing Sound library now has a native ASIO output mode (`MultiChannel.useJASIO()`)
built on JAsioHost. It works, but JAsioHost's native library only discovers **some** of the
ASIO drivers installed on the machine, because its driver enumeration comes from the
2012-era Steinberg ASIO SDK and is buggy.

Concrete symptom (real Windows test, Realtek onboard audio + Dante Virtual Soundcard x64
+ Blackmagic ASIO installed):

- Audacity lists: `Dante Virtual Soundcard x64`, `Realtek ASIO`, `Blackmagic ASIO`
- Processing Sound `Sound.list()` with JASIO lists: `Realtek ASIO` only

**Goal:** make `MultiChannel.useJASIO()` see and successfully open *all* usable ASIO
drivers, then ship a rebuilt `jasiohost64.dll` with the fix.

---

## 2. Current state of the work (do not redo this)

Branch `jasio-support` on fork `trackme518/processing-sound`, pushed and released:

| Commit | Content |
|---|---|
| `7ad0481` | JASIO integration (`MultiChannel.useJASIO()`), vendored `jasiohost-master/`, build wiring, `examples/IO/AsioOutput` |
| `82ac31b` | GitHub Actions modernization (all actions on current majors) |
| `2845077` | Hardening: null-guard `AsioChannel.setBufferIndex`, buffer validation before `driver.start()`, callback exception guard |

Releases: `2.5.0-jasio`, `2.5.0-jasio2` (each with `sound.zip`). CI is green.
Remotes: `origin` = upstream `processing/processing-sound` (never push there),
`fork` = `https://github.com/trackme518/processing-sound.git`.

What was added/changed in the library (for orientation):

- `src/processing/sound/JAsioAudioDeviceManager.java` — JSyn `AudioDeviceManager` on top of
  JAsioHost; nested `Session` (driver lifecycle + `AsioDriverListener`), `JAsioOutputStream`,
  `JAsioInputStream`, interleaved `RingBuffer`. This is the Java integration; **it needs no
  changes for this task** except possibly better error messages.
- `src/processing/sound/Engine.java` — driver constants `DRIVER_DEFAULT/PORTAUDIO/JASIO`,
  `useJAsio()`, `isUsingJAsio()`, `createJAsioAudioDeviceManager()`.
- `src/processing/sound/MultiChannel.java` — `useJASIO()` public API.
- `build.xml` — `jasio-deps` target compiles `jasiohost-master/src/**` into
  `library/JAsioHost.jar` and copies the dlls to `library/windows-amd64/`.
- `jasiohost-master/` — vendored JAsioHost **Java + native sources** (LGPL) and the
  prebuilt dlls (`jasiohost32.dll`, `jasiohost64.dll`, both from 2012).
- `jasiohost-master/src/com/synthbot/jasiohost/AsioChannel.java` — locally patched
  (`setBufferIndex` null-guard, commit `2845077`). Keep this patch when rebuilding the jar.

---

## 3. Root cause (already investigated — trust this)

Native driver discovery happens exactly once, at DLL load:

- `jasiohost-master/src/com/synthbot/jasiohost/JAsioHost.cpp`
  - `JNI_OnLoad` (~line 55): `asioDrivers = new AsioDrivers();` → this constructor calls
    `createDriverList()` from the Steinberg ASIO SDK (`host/asiodrivers.cpp`, **not** vendored
    in this repo).
  - `Java_..._getDriverNames` (~line 286) just returns that cached list (Java caps it at 32).
  - `Java_..._loadDriver` (~line 238) calls `asioDrivers->loadDriver(name)`, which only
    knows drivers from that same list.
  - `JNI_OnUnload` deletes the object; there is no API to rescan.

`createDriverList()` (SDK 2.x, the version JAsioHost was built against) does:

1. `RegOpenKey(HKEY_LOCAL_MACHINE, "SOFTWARE\\Classes\\CLSID")` — **only** the HKLM 64-bit
   view. Per-user drivers (`HKCU\Software\Classes\CLSID`) are invisible.
2. For each CLSID key it enumerates only the **first subkey** and treats it as the driver
   description; if that first subkey is `InprocServer32` (or `Implemented Categories`, which
   sorts before `InprocServer32`), the CLSID is skipped even though it is a valid driver.
3. It reuses the `DWORD` length variables between `RegEnumKeyEx` iterations without resetting
   them (known SDK bug), so once a short name has been seen, later names are truncated/fail
   → drivers are skipped depending on GUID enumeration order.

Consequence: because `loadDriver()` resolves names through this same list, drivers missing
from it **cannot** be used even if injected from Java. There is no Java-side workaround.
(A maintained JAsioHost fork does not exist; `mhroth/jasiohost` last changed in 2018 and all
visible forks are untouched clones.)

Recommended concrete check on the target machine (before/after fix):

```bat
reg query "HKLM\SOFTWARE\Classes\CLSID" /s /f "Dante" /k
reg query "HKCU\Software\Classes\CLSID" /s /f "Dante" /k
reg query "HKLM\SOFTWARE\Classes\WOW6432Node\CLSID" /s /f "Dante" /k
reg query "HKLM\SOFTWARE\Classes\CLSID" /s /f "Blackmagic" /k
```

Record where the drivers live (HKLM vs HKCU vs WOW6432Node) and what their CLSID subkeys are
called (`InprocServer32` default value = the driver DLL path, plus one subkey named like the
driver). Save the output in the PR/handoff notes — it justifies the fix.

---

## 4. Constraints and gotchas

- **Platform:** Windows x64. Build must produce a drop-in `jasiohost64.dll` (same JNI
  exports; no Java API changes).
- **Toolchain:** original build used Cygwin + `x86_64-w64-mingw32-g++` (see
  `jasiohost-master/src/com/synthbot/jasiohost/buildJah64_win.sh`; note the script has a
  broken trailing `mv ... */` line — fix or ignore). MSYS2/mingw-w64 is fine.
- **ASIO SDK:** not in the repo and **cannot be downloaded unattended** (Steinberg EULA).
  Download "ASIO SDK 2.3.3" manually, extract, and use `common/` and `host/`.
  - README notes (from JAsioHost): remove/rename `common/asiodrvr.cpp` and
    `common/dllentry.cpp`; in `common/combase.h`, line ~219 `#if WINVER < 0x0501` → `#if 0`.
  - Do **not** commit SDK sources to the processing-sound repo (license). Commit only the
    rebuilt dll; publish the patch + build instructions in a JAsioHost fork / gist instead.
- **Bit depth:** `AsioDriver` loads `jasiohost` + `sun.arch.data.model` → only
  `jasiohost64.dll` matters for Processing 4 (64-bit). Optional: keep 32-bit build working.
- **Bitness of drivers:** a 64-bit host must not load 32-bit driver DLLs. If the scan includes
  `WOW6432Node`, filter drivers whose `InprocServer32` DLL is PE32 (or simply skip
  WOW6432Node for the 64-bit build). Audacity may list 32-bit-registered drivers that a
  64-bit host cannot open — don't chase those.
- **COM registration:** JAsioHost's `registerThread` JNI does `CoInitialize(NULL)`; keep that
  behaviour untouched.
- **Licensing:** JAsioHost is LGPL. A patched SDK file is a derivative of Steinberg's SDK, so
  safest: keep the change as a diff against `host/asiodrivers.cpp`, ship only the rebuilt dll,
  and document the patch (e.g. in `trackme518/jasiohost`, which already exists as a fork).
- **Do not regress:** Realtek ASIO worked with `2.5.0-jasio2`; the Realtek NPE flood was fixed
  in `2845077` (`setBufferIndex` guard + pre-start buffer validation). Keep those.

---

## 5. Implementation plan

### Step 0 — baseline
1. Clone/branch `trackme518/processing-sound` at `jasio-support` on Windows.
2. Build and confirm current behaviour: `ant compile` (needs `library/JAsioHost.jar` via
   `ant deps`, or a prebuilt jar) and a tiny Java probe (no Processing needed):

```java
// AsioListProbe.java — run with jasiohost64.dll on java.library.path
import com.synthbot.jasiohost.AsioDriver;
public class AsioListProbe {
  public static void main(String[] a) {
    for (String n : AsioDriver.getDriverNames()) System.out.println("driver: " + n);
  }
}
```
Expected baseline: only `Realtek ASIO`.

### Step 1 — reproduce and diagnose the registry layout
Run the `reg query` commands from §3. Note for each ASIO CLSID: root key, CLSID, subkey
names and their order, `InprocServer32` default value, DLL bitness.

### Step 2 — fix `createDriverList()`
Patch the SDK file `host/asiodrivers.cpp` (keep the same class/API so `JAsioHost.cpp` is
unchanged). Required behaviour:

- Iterate these roots (HKLM first, then HKCU; **skip** `WOW6432Node` in the 64-bit build, or
  filter PE32 DLLs):
  - `HKLM\SOFTWARE\Classes\CLSID`
  - `HKCU\Software\Classes\CLSID`
- For every CLSID subkey:
  - **Reset all `DWORD` length variables inside the loop** before each `RegEnumKeyEx`
    (this is the SDK bug).
  - Require a child key `InprocServer32` (in-process COM server).
  - Enumerate **all** child keys; pick the driver description = a child key whose name is not
    one of: `InprocServer32`, `Implemented Categories`, `TypeLib`, `ProgID`,
    `VersionIndependentProgID`, `LocalServer32`, `InprocHandler32`.
  - Deduplicate by driver name and by CLSID; raise `kMaxDriversRet` to at least 64.
  - Ignore any errors per-CLSID (never abort the scan).
- Optional but valuable: verify the `InprocServer32` DLL's PE machine type matches the host
  bitness before adding the driver (avoids advertising unusable drivers).
- Optional hardening: skip empty names / names that look like GUIDs.

Keep the existing `driverInfo` storage layout so `loadDriver(name)` keeps working.

Reference implementation sketch (adapt to the SDK's structs/naming):

```cpp
static bool isComSubKey(const char* n) {
  return !_stricmp(n, "InprocServer32") || !_stricmp(n, "Implemented Categories")
      || !_stricmp(n, "TypeLib") || !_stricmp(n, "ProgID")
      || !_stricmp(n, "VersionIndependentProgID") || !_stricmp(n, "LocalServer32")
      || !_stricmp(n, "InprocHandler32");
}

static void scanClsidRoot(HKEY root, const char* path, DriverInfo* info, long& count) {
  HKEY key;
  if (RegOpenKeyExA(root, path, 0, KEY_READ, &key) != ERROR_SUCCESS) return;
  for (DWORD i = 0;; ++i) {
    char clsid[64]; DWORD clsidLen = sizeof(clsid);        // reset every iteration (SDK bug)
    if (RegEnumKeyExA(key, i, clsid, &clsidLen, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
    HKEY sub;
    if (RegOpenKeyExA(key, clsid, 0, KEY_READ, &sub) != ERROR_SUCCESS) continue;
    bool hasInproc = false; char name[256] = {0};
    for (DWORD j = 0;; ++j) {
      char subName[256]; DWORD subLen = sizeof(subName);    // reset every iteration
      if (RegEnumKeyExA(sub, j, subName, &subLen, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
      if (!_stricmp(subName, "InprocServer32")) hasInproc = true;
      else if (!isComSubKey(subName) && name[0] == 0) strcpy_s(name, subName);
    }
    RegCloseKey(sub);
    if (hasInproc && name[0] != 0 && count < kMaxDriversRet && !findDriver(name))
      /* append {name, clsid} to info */ ++count;
  }
  RegCloseKey(key);
}

// createDriverList(): scanClsidRoot(HKEY_LOCAL_MACHINE, "SOFTWARE\\Classes\\CLSID", ...);
//                     scanClsidRoot(HKEY_CURRENT_USER,  "Software\\Classes\\CLSID",  ...);
```

Also consider a debug log (via `fprintf(stderr, ...)` or a small JNI getter) so the probe can
show *why* a CLSID was accepted/rejected — invaluable for the next round of field reports.

### Step 3 — build
```bat
:: MSYS2 mingw64 shell, inside jasiohost-master/src/com/synthbot/jasiohost
:: (ASIOSDK2 = extracted Steinberg ASIO SDK 2.3.3 root)
x86_64-w64-mingw32-g++ -D__int64="long long" -o jasiohost64.dll -static -shared -O3 -W \
  -Wl,--add-stdcall-alias \
  -I. -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/win32" \
  -I./ASIOSDK2/common -I./ASIOSDK2/host -I./ASIOSDK2/host/pc \
  ./JAsioHost.cpp ./ASIOSDK2/common/*.cpp ./ASIOSDK2/host/*.cpp ./ASIOSDK2/host/pc/*.cpp \
  -lstdc++ -lole32 -luuid
```
Exclude `common/asiodrvr.cpp` and `common/dllentry.cpp` if the SDK copy still contains them.
Verify exports with `dumpbin /exports jasiohost64.dll` (or `objdump -p`): the JNI symbols for
`AsioDriver` must be unchanged, and the DLL must be 64-bit.
Note: `JAsioHost.cpp` includes `jni.h`, so the JDK include directories are required.

### Step 4 — test (acceptance criteria)
1. `AsioListProbe` prints **all three**: Realtek, Dante Virtual Soundcard, Blackmagic.
2. Replace `library/windows-amd64/jasiohost64.dll`, rebuild the library on Windows
   (`ant jasio-deps` is not needed; the dll is copied) and run
   `examples/IO/AsioOutput`:
   - `Sound.list()` shows all drivers with correct channel counts.
   - `Sound.outputDevice("<Dante driver name>")` plays through Dante (route to a Dante
     receiver / virtual soundcard monitor).
   - `Sound.outputDevice("<Blackmagic driver name>")` plays (and works with its embedded SDI
     audio if available).
   - Realtek still works (regression check).
   - `Sound.status()` reports a sane latency; note whether a sample-rate warning appears.
3. `MultiChannel.availableChannels()` / multichannel routing still work (pick a driver with
   >2 outputs if available).
4. Input path: `Sound.inputDevice("<driver>")` + `AudioIn` (only if hardware input exists).
5. Non-ASIO paths unaffected: run without `useJASIO()` on JavaSound/PortAudio.

### Step 5 — ship
1. Commit only the rebuilt `library/windows-amd64/jasiohost64.dll` (and 32-bit dll if built),
   with a commit message describing the enumeration fix; update `jasiohost-master/README.md`
   or add `jasiohost-master/PATCHES.md` documenting the patch (since SDK sources can't be
   committed).
2. Tag a new dev release (non-`v` tag, e.g. `2.5.0-jasio3`) → CI builds `sound.zip`.
3. Ask the user to retest on the Windows machine.
4. Optionally publish the patch + build instructions in `trackme518/jasiohost` and open an
   issue/PR upstream (`mhroth/jasiohost`) — the enumeration bug is worth fixing there.
5. Then prepare the upstream `processing/processing-sound` PR from `jasio-support`
   (see §6).

---

## 6. PR notes (for later)

- Feature PR should mention: PortAudio's ASIO host is unreliable on Windows; JAsioHost is
  bundled as **sources** built by the new `jasio-deps` ant target (jar is not committed,
  matching how jsyn/jportaudio are handled), dlls force-added under
  `library/windows-amd64/` (same convention as portaudio dlls), LGPL license text shipped.
- Keep the `AsioChannel` null-guard patch and the enumeration patch documented; upstream
  reviewers will ask why the vendored sources differ from `mhroth/jasiohost`.
- Keep `examples/IO/AsioOutput`.
- Mention CI modernization commit separately if the maintainers prefer a clean feature diff.
- Known limitation to state honestly: only one ASIO driver can be loaded at a time (ASIO API
  restriction); drivers are enumerated once per process by the native library.

---

## 7. Key file locations

```
src/processing/sound/JAsioAudioDeviceManager.java        Java integration (no changes needed)
src/processing/sound/Engine.java                        driver selection, useJAsio()
src/processing/sound/MultiChannel.java                  public useJASIO() API
jasiohost-master/src/com/synthbot/jasiohost/JAsioHost.cpp        JNI: JNI_OnLoad, loadDriver, getDriverNames
jasiohost-master/src/com/synthbot/jasiohost/AsioDriver.java      Java side of the wrapper
jasiohost-master/src/com/synthbot/jasiohost/AsioChannel.java     patched setBufferIndex
jasiohost-master/src/com/synthbot/jasiohost/buildJah64_win.sh    original build script
library/windows-amd64/jasiohost64.dll                    replaced by this task
build.xml                                                jasio-deps target
examples/IO/AsioOutput/AsioOutput.pde                    manual test sketch
```

## 8. Open questions

- Where exactly do Dante and Blackmagic register (HKLM/HKCU/WOW6432Node)? → §3 commands.
- Are Dante/Blackmagic registered as 64-bit COM servers? (Needed for a 64-bit host.)
- Does the user's ASIO SDK version/build match the 2012 dll's ABI? (JNI exports only, so
  any SDK 2.x works; use 2.3.3.)
- Should the fork release signature/commit history matter for Windows SmartScreen? (No —
  the dll is loaded via JNI, not installed.)
