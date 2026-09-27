---
title: Firmware — the ARCS shim ("Henry's PROM")
status: draft (MAME-validated)
source: r9999/IRIX_CPU_REQUIREMENTS.md (P0-A/B/C); ARCS section of r9999/IP22_CHIP_REGISTERS.md; arcs_spec.pdf (ARC 1.2)
---

# Firmware — the ARCS shim

> Henry loads `/unix` **directly** — it replaces the SGI PROM **and** sash (the ARC OSLoader) — so it must
> reproduce the in-memory state the kernel expects to find on entry. **Key insight from MAME:** the *running*
> kernel barely calls ARCS — exactly **one** `GetEnvironmentVariable` over a whole boot to multiuser; everything
> else (memory enumeration, the config-tree build/walk, the wall-clock seed) is **sash work, pre-kernel**, which
> Henry replaces. So Henry's shim is **mostly correct in-memory DATA, not live firmware functions**: plant the SPB,
> a romvec, an env block, and the exception-vector area; enter `start` with the SGI handoff registers; let the
> kernel read RAM geometry straight from the MC. Everything below is big-endian (SGI = BE, ARCS Ver 1 Rev 10).
> Legend: ✅ confirmed in MAME, ⚠️ correction vs an earlier assumption.

---

## The kernel entry handoff

Henry jumps to `/unix` `start` (entry **`0x88005960`**, kseg0) with:

```
a0 = 0x00000008          ; argc = 8
a1 = argv  (kseg0 ptr)   ; MAME: 0x88fff300 — array of 8 char* + NULL (boot path + OSLoad* strings)
a2 = envp  (kseg0 ptr)   ; MAME: 0x88fff908 — array of "KEY=value" char* + NULL (PROM env vars)
a3 = 0
sp = 0   gp = 0   ra = 0   fp = 0          ; clean GPRs; the kernel sets up its own gp/sp
SR = 0x30004801                            ; CU1|BEV|... (MAME-observed entry Status)
```

✅ **CORRECTION (2026-06-15, MAME-measured — this overturns the earlier `a1=a2=0` claim).** It **IS**
`start(argc, argv, envp)`. An earlier P0 note recorded `a1=a2=0`; **MAME disproves it** — at `0x88005960`,
`a0=8` (**argc**), `a1=0x88fff300` (**argv**), `a2=0x88fff908` (**envp**), both real kseg0 pointers near the top
of 16 MB RAM. The standard `ARCS PROM → sash → /unix` chain has **sash** (the ARC `OSLoader`) marshal
`argc/argv/envp` per ARC §4.4 "Loaded Program Conventions" + `Invoke(…,Argc,Argv,Envp)`, then jump to `start`.
**The kernel consumes them:** `start` saves `a0→_argc`, `a1→_argv`, **`a2→_envirn`** (`0x8832d7c0`), and
`mlsetup→getargs` reads `_envirn` — `getargs` branches on `sltu(envp, 0x80000000)`, so a **NULL/low `a2`
mis-routes the boot** (this is exactly why a sash-replacement that passes `a2=0` walls). **Henry replaces sash,
so Henry MUST synthesize the `argv`/`envp` arrays in RAM** (kseg0 `char*` arrays, NULL-terminated) with at least
a valid `envp` — see [Environment variables](#environment-variables) for the exact strings. `a0=8` is argc (8
boot args), **not** a flag.

The real **`sash`** is a MIPSEB MIPS-II ECOFF executable ("SGI Version 6.5 ARCS") living in the disk **volume
header** (`sash` standalone @ LBN 672 of the volhdr / partition 8); it can be extracted with `dd` from the
chdman'd disk image and disassembled (`objdump -d`, format `ecoff-bigmips`).

`start` does **not** rely on register-passed pointers: it immediately saves `a0/a1/a2` to globals, then calls its
first C routine `0x880255e8(a0,a1,a2,a3=0x880059b0)`. Everything else IRIX needs it pulls from the **SPB + romvec**
(below) and from the **MC registers** (memory map) — not from registers. Verified prologue:

```
88005960 lui   gp,0x8833
88005964 lui   sp,0x8833
88005968 addiu gp,gp,0x2bf0          ; gp = 0x88332bf0  (kernel computes its own gp)
8800596c addiu sp,sp,-0x4060
88005970 lw    sp,0(sp)              ; sp = *(0x8832bfa0) (kernel computes its own sp)
88005978 addiu at,gp,-0x5440
8800597c sw    a0,0(at)              ; save boot arg a0 to a global
...      sw    a1 / sw a2            ; saves a1,a2 similarly
880059a8 jal   0x880255e8           ; first C call with the saved boot args
```

**Henry leaves gp/sp = 0**; the kernel sets them itself in the prologue. Do not try to pre-seed them.

---

## The SPB (System Parameter Block) @ phys `0x1000`

The kernel finds *everything* through the SPB. Plant it verbatim at **phys `0x1000`** (kseg1 `0xa0001000`,
kseg0 `0x80001000`). All fields big-endian. Layout (72 bytes, `SPBLength=0x48`):

```
off    value         field                         notes
+0x00  0x53435241    Signature = "ARCS"            BE bytes 41 52 43 53 ('A''R''C''S')
+0x04  0x00000048    SPBLength = 72
+0x08  0x0001000a    Version = 1, Revision = 10    (u16 Version=1, u16 Revision=10)
+0x0c  0xa87484ec    RestartBlock ptr              PROM-internal; kernel does not deref on boot — any sane ptr
+0x10  0x00000000    DebugBlock = NULL             (none)  ✅ matches dump + spec
+0x14  0x9fc30590    GeneralException vector       PROM addr; advisory (kernel installs its own early)
+0x18  0x9fc306e4    UTLB-miss vector              PROM addr; advisory
+0x1c  0x0000008c    FirmwareVectorLength = 140    => 35 entries (0x8c/4)
+0x20  0xa0001800    FirmwareVector  -> romvec     (the 35-entry table, below)
+0x24  0x00000034    PrivateVectorLength = 52      => 13 SGI-private entries
+0x28  0xa0001c00    PrivateVector   -> SGI ext.   (semantics TBD; table of NULLs is acceptable if unused)
+0x2c  0x00000000    AdapterCount = 0
```

Notes:
- The **GEVector/UTLBmiss** entries are advisory — IRIX installs its own exception handlers very early, but the
  SPB still advertises them. Henry may point them at its own stubs (or keep PROM-style addresses); the kernel
  does not call through them.
- The **exception block (page 0)** must be real RAM, and the SPB sits at `0x1000` — see "exception vectors area"
  in the checklist. Henry must alias phys `0x0`/`0x80` to RAM (the MC doc covers the `0x0–0x7ffff` low alias to
  `0x08000000`).

---

## The romvec (FirmwareVector, 35 entries)

35 function pointers @ `0xa0001800`, in the standard ARCS vector order (`FirmwareVectorLength=0x8c`). The two
reserved NULL slots (idx 8, 19) match the MAME dump exactly, confirming the layout. **The crucial finding (P0-B):
the running kernel calls almost none of these** — so most entries can be simple stubs that return cleanly. The one
the kernel actually invokes is **GetEnvironmentVariable (30)**; the rest are sash-era. Addresses below are the real
Indy PROM's (`indy_4610`) for reference — for Henry only the **semantics** and **whether the kernel calls it**
matter. Mark which Henry must implement vs may stub:

```
idx  name                  PROM addr   caller   Henry
 0   Load                  9fc31a8c    [s]      stub (sash-only loader)
 1   Invoke                9fc31bd8    [s]      stub
 2   Execute               9fc31ee4    [s]      stub
 3   Halt                  9fc005ec    -        stub: spin / power-down
 4   PowerDown             9fc005f4    -        stub: spin
 5   Restart               9fc00614    -        stub: jump reset
 6   Reboot                9fc0061c    -        stub: jump reset
 7   EnterInteractiveMode  9fc00624    -        stub: spin/halt
 8   (reserved)            00000000    -        NULL
 9   GetPeer               9fc2c1f8    [s]      stub: return NULL (config tree)
10   GetChild              9fc2c204    [s]      stub: return NULL (or tiny tree)
11   GetParent             9fc2c228    [s]      stub: return NULL
12   GetConfigurationData  9fc2c234    [s]      stub: return error/empty
13   AddChild              9fc2c284    [s]      stub
14   DeleteComponent       9fc2c548    -        stub
15   GetComponent          9fc34680    -        stub: return NULL
16   SaveConfiguration     9fc2c674    -        stub: ESUCCESS no-op
17   GetSystemId           9fc107a8    -        stub: ptr to a SYSTEMID (VendorId/ProductId)
18   GetMemoryDescriptor   9fc10b90    [s]      stub: return NULL  (kernel uses MC, not this — see below)
19   (reserved)            00000000    -        NULL
20   GetTime               9fc106d0    [s]      stub: return a TIMEINFO  (kernel uses CP0, not this)
21   GetRelativeTime       9fc39fb0    -        stub: return RPSS/CP0 count
22   GetDirectoryEntry     9fc10608    [s]      stub
23   Open                  9fc0fc34    [s]      stub: error
24   Close                 9fc1046c    [s]      stub: ESUCCESS
25   Read                  9fc1004c    [s]      stub: error
26   GetReadStatus         9fc107b4    [s]      stub
27   Write                 9fc1030c    [s]      stub: drain to console (optional)
28   Seek                  9fc1053c    [s]      stub: error
29   Mount                 9fc10878    [s]      stub
30   GetEnvironmentVariable 9fc10944   [K]      ** REQUIRED ** — the only entry the kernel calls
31   SetEnvironmentVariable 9fc10924   [s]      stub: ESUCCESS no-op
32   GetFileInformation    9fc10964    [s]      stub
33   SetFileInformation    9fc10a04    [s]      stub
34   FlushAllCaches        9fc0e278    [s]      stub: do the r9999 cache flush (or no-op if direct-boot safe)
```

`[K]` = called by the kernel (after `start`); `[s]` = sash/PROM only (before `start`), irrelevant to Henry's
sash-less boot; `-` = not observed in this boot.

**Minimum viable romvec:** a real `GetEnvironmentVariable` (idx 30); every other slot a stub returning a benign
value (NULL / ESUCCESS=0 / a static TIMEINFO/SYSTEMID). ⚠️ Do **not** leave wild pointers — the config-tree
walkers (GetChild/GetPeer/GetParent) must return NULL cleanly or a tiny `System→CPU→FPU` / `System→MemoryUnit`
tree; a garbage COMPONENT pointer crashes early probing. ARCS status codes are POSIX-numbered (`ESUCCESS=0`).

The kernel's single call is `GetEnvironmentVariable(a0=NULL)` — likely fetching the env-block base or an init
probe (exact return semantics: open item). Implement it to walk the env block (next section) by name, returning a
pointer to the value string (or NULL if absent).

`PrivateVector` (13 SGI extensions @ `0xa0001c00`) — semantics TBD; not observed called by the kernel. A table of
NULLs is acceptable until something is found to need it.

---

## Environment variables

ARCS keeps a `;`-separated env block; names are case-insensitive, values case-sensitive. On real hardware these
live in the ds1386 NVRAM (HPC3 `0x60000`) and are `setenv`'d in the PROM monitor; **Henry plants them directly in
the env block** that `GetEnvironmentVariable` reads. Standard ARC vars (arcs_spec.pdf p.55–57): `ConsoleIn`,
`ConsoleOut`, `SystemPartition`, `OSLoader`, `OSLoadPartition`, `OSLoadFilename`, `OSLoadOptions`,
`LoadIdentifier`, `AutoLoad`, `TimeZone`, `FWSearchPath`. SGI adds non-standard ones: **`eaddr`** (MAC — its
absence caused early kernel panics in MAME until a one-time PROM `setenv -f eaddr <mac>`), `dbaud`, `rbaud`,
`bootfile`, `path`, `console`.

### The exact `argv`/`envp` MAME's sash hands `/unix` (✅ captured 2026-06-15)

The kernel reads these **two ways**: the `a2=envp` pointer (→ `_envirn` → `getargs`, see the handoff section)
*and* `GetEnvironmentVariable(30)` romvec calls. The live values from MAME (synthesize at least `envp`):

```
argv[8] :  scsi(0)disk(1)rdisk(0)partition(0)/unix   OSLoadOptions=auto   ConsoleIn=serial(0)
           ConsoleOut=serial(0)   SystemPartition=scsi(0)disk(1)rdisk(0)partition(8)   OSLoader=sash
           OSLoadPartition=scsi(0)disk(1)rdisk(0)partition(0)   OSLoadFilename=/unix
envp[]  :  AutoLoad=Yes  TimeZone=PST8PDT  console=d  diskless=0  dbaud=9600  volume=80  sgilogo=y
           autopower=y  eaddr=08:01:02:03:04:05  ConsoleOut=serial(0)  ConsoleIn=serial(0)  cpufreq=100
           SystemPartition=...  OSLoadPartition=...  OSLoadFilename=/unix  OSLoader=sash
           kernname=scsi(0)disk(1)rdisk(0)partition(0)/unix
```

What matters for a direct `/unix` boot:
- **`eaddr`** — *load-bearing*: set it (e.g. `eaddr=08:00:69:xx:xx:xx`) or the kernel panics early in network init.
- **`console`** — selects the serial console (`d` / `g`); Henry's console is IOC2 serial (see `peripherals/ioc2.md`).
- **`ConsoleIn`/`ConsoleOut`** — ARCS path to the console device.
- `OSLoadPartition` / `OSLoader` / `OSLoadFilename` / `OSLoadOptions` / `SystemPartition` / `root` — these drive
  sash's OS-loading and root selection. Since Henry *is* the loader and hands the kernel a fixed `/unix`, the
  kernel reads few of these directly, but plant plausible values (`OSLoadOptions=auto`, a `root=`/`SystemPartition`
  pointing at the boot disk) so any kernel-side query returns something sane.

Reproduce whatever the kernel actually queries; over-provisioning the block is harmless. (Open item: pin the exact
name the single kernel `GetEnvironmentVariable(NULL)` resolves to.)

---

## How the kernel learns the memory map

⚠️ **NOT via `GetMemoryDescriptor`.** P0-B/P0-C: the kernel makes **zero** `GetMemoryDescriptor` calls — sash's 14
calls are pre-kernel and irrelevant to a sash-less boot. Instead, `szmem` (`0x8800790c`, "size memory") reads the
**MC MEMCFG registers directly** (`0x880077c0`):

```
lui  a5,0xbfa0        ; 0xbfa00000 kseg1 uncached -> phys 0x1fa00000 = the MC
lw   a3,196(a5)       ; MEMCFG0 @ 0xbfa000c4  (BE +4 alias of table offset 0xc0)
lw   a3,204(a5)       ; MEMCFG1 @ 0xbfa000cc  (BE +c alias of 0xc8)
srlv v0,a3,a4         ; pick the bank's 16-bit half (two banks packed per 32-bit reg)
andi v0,v0,0xffff
```

**Implication for Henry:** the shim does **NOT** need a working `GetMemoryDescriptor` (idx 18 may stub→NULL). It
**must** present correct **MC MEMCFG0/MEMCFG1** values describing Henry's DRAM. The decode and SIMM-size table live
in **`peripherals/mc.md`** — implement those registers there; here is the handoff dependency:

- MEMCFG packs banks {0,2} (MEMCFG0) and {1,3} (MEMCFG1); per bank `base = BASE<<22` (4 MB units, vs phys[29:22]),
  size from the MSIZE table (`0b01111`=16 MB, `0b11111`=32 MB, …), `VLD` valid bit, `BNK` sub-banks.
- Live golden values (16 MB Indy): `MEMCFG0=0x23200000` (hiBank base=0x20→`0x08000000`, MSIZE=0b00011=16 MB,
  VLD=1; loBank invalid), `MEMCFG1=0x00000000`, `CPU_MEMACC (0xd0)=0x11453433` (opaque DRAM timing — store/return).
- For Henry's DRAM (256 MB at `0x08000000`): set bank base `0x20`, widen MSIZE / add banks so the decoded
  base+size cover `0x08000000–0x17ffffff` (the arcs FSBL programs these MEMCFG regs at POST → `hinv` reports
  256 MB; a single bank can be up to 256 MB, and the values are programmable without a re-synth). Cross-check the
  decoded total against `physmem`/`maxmem`
  (`0x8832d1f0`/`0x8832d1f8`) after `szmem` runs, and against `_physmem_start = 0x08000000`.

So memory-map correctness is an **MC peripheral** problem, not a firmware-data problem — keep the romvec
`GetMemoryDescriptor` a stub and get MEMCFG right.

---

## Minimum the Henry shim must plant in memory

Checklist (everything big-endian):

1. **SPB @ phys `0x1000`** — signature "ARCS", the 72-byte field layout above, `FirmwareVector→0xa0001800`,
   `PrivateVector→0xa0001c00`, `DebugBlock=NULL`, `AdapterCount=0`.
2. **Romvec (35 entries) @ `0xa0001800`** — with a **working `GetEnvironmentVariable` (idx 30)**; all other slots
   stubs that return benign values (NULL / ESUCCESS / static TIMEINFO/SYSTEMID). No wild pointers; tree walkers
   return NULL cleanly.
3. **Env block** — at minimum `eaddr` (or the kernel panics) and `console`/`ConsoleIn`/`ConsoleOut`; plus plausible
   `OSLoad*`/`SystemPartition`/`root`.
4. **Exception-vector area** — page 0 is real RAM; alias phys `0x0`/`0x80` to `0x08000000`/`0x08000080` (MC low
   alias). SPB sits just above at `0x1000`. The kernel installs its own GE/UTLB handlers early.
5. **Enter `start` (`0x88005960`) with `a0=8 (argc), a1=argv, a2=envp`** (see the ✅ 2026-06-15 correction above — the earlier `a1=a2=0` was wrong), a clean GPR file, gp/sp = 0 (kernel sets them).

**Not needed:** a live `GetMemoryDescriptor` (kernel reads MC MEMCFG — see above), live `GetTime` (kernel uses the
CP0 Count/Compare timer for the scheduler tick), the config tree, or any file-I/O romvec entry (sash did all disk
I/O; Henry already loaded `/unix`).

---

## Open items

- Decode the single kernel `GetEnvironmentVariable(a0=NULL)` call — exact name resolved / how the return is used
  (getenv-of-NULL to fetch the env-block base, vs an init probe). Determines how minimal idx-30 can be.
- Exact meaning of `a0=8` to `start` (minor — `start` saves it and boot succeeds regardless).
- Whether `FlushAllCaches` (idx 34) needs a real r9999 cache flush at the handoff or can be a no-op for direct boot.
- Confirm no kernel-phase deref of `RestartBlock`/`PrivateVector` (so NULL/placeholder stays safe).

---

## Detailed working notes

Source of truth: **`r9999/IRIX_CPU_REQUIREMENTS.md`** (P0-A/B/C, MAME-validated 2026-06-12) and the **ARCS section
of `r9999/IP22_CHIP_REGISTERS.md`** (mined from `arcs_spec.pdf` ARC 1.2 + cross-checked vs MAME, 2026-06-14).

- **P0-A — the handoff at `start` (0x88005960):** entry register state (`a0=8 (argc), a1=argv, a2=envp`, SR=0x30004801, clean
  GPRs), the verified `start` prologue, the SPB @ `0x1000` byte layout, the 35-entry FirmwareVector dump, and the
  13-entry PrivateVector dump.
- **P0-B — who calls the romvec, and when:** breakpoint-tag every entry as sash/PROM `[s]` vs kernel `[K]`. Result:
  the running kernel makes **exactly one** romvec call — `GetEnvironmentVariable(NULL)`; zero GetTime / Read/Write /
  GetMemoryDescriptor / config-tree from the kernel. All enumeration (GetMemoryDescriptor ×14, GetChild ×57 /
  GetPeer ×50 / GetParent ×47 / AddChild ×23, FlushAllCaches ×1) is **sash, pre-kernel**. Steady-state timekeeping
  is **CP0** (Count climbs, handler re-arms `Compare = Count + ~0x25000`), not ARCS GetTime. ⇒ Henry's job is
  correct in-memory state, not live firmware functions.
- **P0-C — how the kernel sizes RAM (RESOLVED):** `szmem` reads MC `MEMCFG0/1` directly (`0xbfa000c4/0xcc`), not
  ARCS. Register layout / SIMM-size table / golden live values — see `peripherals/mc.md`. ⚠️ Earlier "size=base"
  reading corrected: `0x23200000` = base `0x20<<22=0x08000000`, MSIZE `0b00011` = 16 MB bank.

⚠️ Other corrections folded in from `IP22_CHIP_REGISTERS.md`: the `a0=8/a1=argv/a2=envp` entry is the SGI sash→`/unix`
handoff (NOT ARC `Main(argc,argv,envp)` — that's the ARC→sash convention Henry replaces); the romvec is 35 entries
(`FirmwareVectorLength=0x8c`), not the 37 of the full ARC spec (TestUnicodeCharacter/GetDisplayStatus absent here).
